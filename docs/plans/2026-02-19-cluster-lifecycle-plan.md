# Cluster Lifecycle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make pg2une own the full lifecycle of a PostgreSQL cluster in mxc microVMs, with rolling node replacement for safe configuration optimization.

**Architecture:** New `Pg2une.ClusterManager` GenServer owns cluster topology (primary + sync replica + pgbouncer as mxc microVMs). When the Bayesian optimizer produces a config, ClusterManager launches an async standby with that config, validates it under real read traffic via PgBouncer routing, then promotes via role swap (`pg_promote()` + reconfigure old primary as sync replica). ClusterManager asserts health facts into Datalox to suppress optimization during transitions.

**Tech Stack:** Elixir/OTP GenServer, mxc (microVM orchestration), Postgrex (PG connections), PgBouncer (connection routing), NixOS (VM configs), Datalox/Anytune (fact store)

**Prerequisites:** The mxc dependency (`deps/mxc/`) currently lacks `exec_in_workload` (run commands inside VMs) and IP discovery (get a workload's network address). Tasks 1-2 add these capabilities.

**Build/test commands:** Always use `nix develop -c` prefix (e.g. `nix develop -c mix compile`, `nix develop -c mix test`).

---

### Task 1: Add exec_in_workload to mxc

mxc's `Mxc.Agent.Executor` can start/stop workloads but cannot run ad-hoc commands inside a running VM. ClusterManager needs this to: push PgBouncer config, configure replication on replicas, run `pg_promote()`, check `pg_isready`.

**Files:**
- Modify: `deps/mxc/lib/mxc/coordinator.ex`
- Modify: `deps/mxc/lib/mxc/agent/executor.ex`

**Step 1: Add `exec_in_workload` to Coordinator**

In `deps/mxc/lib/mxc/coordinator.ex`, add after the `stop_workload/1` function:

```elixir
@doc """
Execute a command inside a running workload's VM via SSH.
Returns {:ok, output} or {:error, reason}.
"""
def exec_in_workload(workload_id, command, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 30_000)

  with {:ok, workload} <- get_workload(workload_id),
       true <- workload.status == "running" || {:error, :workload_not_running} do
    # For microVMs, SSH into the guest using its hostname
    hostname = workload.command |> String.split("-") |> Enum.take(2) |> Enum.join("-")
    ssh_command = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@#{hostname} '#{command}'"

    case System.cmd("bash", ["-c", ssh_command], stderr_to_stdout: true, timeout: timeout) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit_code, code, String.trim(output)}}
    end
  end
end
```

**Step 2: Verify compilation**

Run: `nix develop -c mix compile`
Expected: Clean compile with no errors

**Step 3: Commit**

```bash
git add deps/mxc/lib/mxc/coordinator.ex
```

**Note:** This is a temporary local patch. In production, this should be contributed upstream to mxc. The SSH approach works because NixOS microVMs get hostnames set via `networking.hostName` in their configs, and the host can resolve them. If SSH isn't available, an alternative is `microvm-exec` or `vsock`.

---

### Task 2: Add workload IP discovery to mxc

The Workload schema has no IP field. ClusterManager needs IPs to connect PgConnector to specific nodes and configure replication `primary_conninfo`.

**Files:**
- Modify: `deps/mxc/lib/mxc/coordinator/schemas/workload.ex`
- Modify: `deps/mxc/lib/mxc/coordinator.ex`

**Step 1: Add `ip` field to Workload schema**

In `deps/mxc/lib/mxc/coordinator/schemas/workload.ex`, add to the schema:

```elixir
field :ip, :string
```

And add `:ip` to the cast fields list.

**Step 2: Add `discover_workload_ip` to Coordinator**

In `deps/mxc/lib/mxc/coordinator.ex`, add:

```elixir
@doc """
Discover and store the IP address of a running workload.
Queries the VM's network interface via exec_in_workload.
"""
def discover_workload_ip(workload_id) do
  with {:ok, output} <- exec_in_workload(workload_id, "hostname -I | awk '{print $1}'"),
       {:ok, workload} <- get_workload(workload_id) do
    ip = String.trim(output)
    update_workload(workload, %{ip: ip})
  end
end
```

**Step 3: Create migration for ip column**

Run: `nix develop -c mix ecto.gen.migration add_workload_ip --repo Mxc.Repo`

In the generated migration:

```elixir
def change do
  alter table(:workloads) do
    add :ip, :string
  end
end
```

**Step 4: Run migration**

Run: `nix develop -c mix ecto.migrate --repo Mxc.Repo`

**Step 5: Commit**

```bash
git add deps/mxc/lib/mxc/coordinator/schemas/workload.ex deps/mxc/lib/mxc/coordinator.ex priv/repo/migrations/*add_workload_ip*
```

---

### Task 3: ClusterManager Node struct

**Files:**
- Create: `lib/pg2une/cluster_manager/node.ex`
- Create: `test/pg2une/cluster_manager/node_test.exs`

**Step 1: Write the test**

```elixir
defmodule Pg2une.ClusterManager.NodeTest do
  use ExUnit.Case, async: true

  alias Pg2une.ClusterManager.Node

  test "new/3 creates a node with defaults" do
    node = Node.new("wk-123", :primary, "192.168.1.2")
    assert node.id == "wk-123"
    assert node.role == :primary
    assert node.ip == "192.168.1.2"
    assert node.port == 5432
    assert node.config_version == 0
    assert node.status == :starting
  end

  test "new/3 accepts options" do
    node = Node.new("wk-456", :canary, "10.0.0.5", port: 5433, config_version: 3)
    assert node.port == 5433
    assert node.config_version == 3
  end

  test "healthy?/1 returns true only for healthy nodes" do
    healthy = %Node{Node.new("x", :primary, "1.2.3.4") | status: :healthy}
    starting = Node.new("y", :primary, "1.2.3.4")
    assert Node.healthy?(healthy)
    refute Node.healthy?(starting)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c mix test test/pg2une/cluster_manager/node_test.exs`
Expected: FAIL — module not found

**Step 3: Write the implementation**

```elixir
defmodule Pg2une.ClusterManager.Node do
  @moduledoc """
  Represents a node in the pg2une-managed PostgreSQL cluster.
  """

  defstruct [:id, :role, :ip, :port, :config_version, :status, :launched_at]

  @type role :: :primary | :sync_replica | :canary | :pgbouncer
  @type status :: :starting | :healthy | :syncing | :promoting | :draining | :down

  @type t :: %__MODULE__{
    id: String.t(),
    role: role(),
    ip: String.t(),
    port: non_neg_integer(),
    config_version: non_neg_integer(),
    status: status(),
    launched_at: DateTime.t()
  }

  def new(id, role, ip, opts \\ []) do
    %__MODULE__{
      id: id,
      role: role,
      ip: ip,
      port: Keyword.get(opts, :port, 5432),
      config_version: Keyword.get(opts, :config_version, 0),
      status: :starting,
      launched_at: DateTime.utc_now()
    }
  end

  def healthy?(%__MODULE__{status: :healthy}), do: true
  def healthy?(_), do: false
end
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c mix test test/pg2une/cluster_manager/node_test.exs`
Expected: 3 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/pg2une/cluster_manager/node.ex test/pg2une/cluster_manager/node_test.exs
```

---

### Task 4: ClusterManager GenServer — state and deploy_cluster

**Files:**
- Create: `lib/pg2une/cluster_manager.ex`
- Create: `test/pg2une/cluster_manager_test.exs`

**Step 1: Write the test**

```elixir
defmodule Pg2une.ClusterManagerTest do
  use ExUnit.Case

  alias Pg2une.ClusterManager

  test "starts in uninitialized state" do
    {:ok, pid} = ClusterManager.start_link(name: nil)
    assert ClusterManager.status(pid) == :uninitialized
    GenServer.stop(pid)
  end

  test "topology/1 returns empty topology when uninitialized" do
    {:ok, pid} = ClusterManager.start_link(name: nil)
    topo = ClusterManager.topology(pid)
    assert topo.status == :uninitialized
    assert topo.nodes == %{}
    assert topo.primary_id == nil
    GenServer.stop(pid)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c mix test test/pg2une/cluster_manager_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
defmodule Pg2une.ClusterManager do
  @moduledoc """
  Manages the lifecycle of a PostgreSQL cluster running in mxc microVMs.

  Owns cluster topology: primary + sync replica + pgbouncer.
  Handles canary node launch, validation, promotion, and rollback.
  Asserts health facts into Datalox for optimization suppression.

  State machine:
    :uninitialized → deploy_cluster() → :deploying → :ready
    :ready → launch_canary() → :optimizing → promote_canary() → :promoting → :ready
                                             → rollback_canary() → :ready
    :ready → teardown_cluster() → :uninitialized
  """

  use GenServer
  require Logger

  alias Pg2une.ClusterManager.Node

  @health_check_interval 30_000

  defstruct [
    nodes: %{},
    primary_id: nil,
    sync_replica_id: nil,
    pgbouncer_id: nil,
    canary_id: nil,
    config_version: 0,
    status: :uninitialized
  ]

  # ── Client API ──────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  def topology(server \\ __MODULE__) do
    GenServer.call(server, :topology)
  end

  def cluster_ready?(server \\ __MODULE__) do
    GenServer.call(server, :cluster_ready?)
  end

  def deploy_cluster(server \\ __MODULE__) do
    GenServer.call(server, :deploy_cluster, 120_000)
  end

  def teardown_cluster(server \\ __MODULE__) do
    GenServer.call(server, :teardown_cluster, 60_000)
  end

  def launch_canary(config, server \\ __MODULE__) do
    GenServer.call(server, {:launch_canary, config}, 120_000)
  end

  def canary_synced?(server \\ __MODULE__) do
    GenServer.call(server, :canary_synced?)
  end

  def promote_canary(server \\ __MODULE__) do
    GenServer.call(server, :promote_canary, 120_000)
  end

  def rollback_canary(server \\ __MODULE__) do
    GenServer.call(server, :rollback_canary, 60_000)
  end

  # ── Server ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:topology, _from, state) do
    {:reply, %{
      status: state.status,
      nodes: state.nodes,
      primary_id: state.primary_id,
      sync_replica_id: state.sync_replica_id,
      pgbouncer_id: state.pgbouncer_id,
      canary_id: state.canary_id,
      config_version: state.config_version
    }, state}
  end

  @impl true
  def handle_call(:cluster_ready?, _from, state) do
    ready = state.status == :ready &&
            state.primary_id != nil &&
            state.sync_replica_id != nil &&
            state.pgbouncer_id != nil &&
            all_healthy?(state)
    {:reply, ready, state}
  end

  @impl true
  def handle_call(:deploy_cluster, _from, %{status: :uninitialized} = state) do
    Logger.info("ClusterManager: deploying cluster")
    state = %{state | status: :deploying}
    assert_cluster_health(state)

    case do_deploy_cluster(state) do
      {:ok, new_state} ->
        new_state = %{new_state | status: :ready}
        assert_cluster_health(new_state)
        schedule_health_check()
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        new_state = %{new_state | status: :uninitialized}
        assert_cluster_health(new_state)
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:deploy_cluster, _from, state) do
    {:reply, {:error, {:invalid_state, state.status}}, state}
  end

  @impl true
  def handle_call(:teardown_cluster, _from, state) do
    Logger.info("ClusterManager: tearing down cluster")
    do_teardown(state)
    new_state = %__MODULE__{}
    assert_cluster_health(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:launch_canary, config}, _from, %{status: :ready} = state) do
    Logger.info("ClusterManager: launching canary node")
    state = %{state | status: :optimizing}
    assert_cluster_health(state)

    case do_launch_canary(config, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        new_state = %{new_state | status: :ready, canary_id: nil}
        assert_cluster_health(new_state)
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:launch_canary, _config}, _from, state) do
    {:reply, {:error, {:invalid_state, state.status}}, state}
  end

  @impl true
  def handle_call(:canary_synced?, _from, state) do
    synced = case state.canary_id do
      nil -> false
      canary_id ->
        canary = Map.get(state.nodes, canary_id)
        canary && canary.status == :healthy
    end
    {:reply, synced, state}
  end

  @impl true
  def handle_call(:promote_canary, _from, %{status: :optimizing, canary_id: canary_id} = state)
      when canary_id != nil do
    Logger.info("ClusterManager: promoting canary #{canary_id}")
    state = %{state | status: :promoting}
    assert_cluster_health(state)

    case do_promote_canary(state) do
      {:ok, new_state} ->
        new_state = %{new_state | status: :ready, config_version: new_state.config_version + 1}
        assert_cluster_health(new_state)
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:promote_canary, _from, state) do
    {:reply, {:error, {:invalid_state, state.status}}, state}
  end

  @impl true
  def handle_call(:rollback_canary, _from, %{status: :optimizing} = state) do
    Logger.info("ClusterManager: rolling back canary")
    new_state = do_rollback_canary(state)
    new_state = %{new_state | status: :ready}
    assert_cluster_health(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:rollback_canary, _from, state) do
    {:reply, {:error, {:invalid_state, state.status}}, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    state = do_health_check(state)
    schedule_health_check()
    {:noreply, state}
  end

  # ── Cluster Deploy ─────────────────────────────────────────

  defp do_deploy_cluster(state) do
    arch = Mxc.Platform.guest_arch()

    with {:ok, primary_wl} <- deploy_vm("pg2une-postgres-#{arch}", 4, 2048),
         {:ok, primary_ip} <- discover_ip(primary_wl.id),
         {:ok, replica_wl} <- deploy_vm("pg2une-postgres-replica-#{arch}", 4, 2048),
         {:ok, replica_ip} <- discover_ip(replica_wl.id),
         :ok <- configure_replication(replica_wl.id, primary_ip),
         {:ok, pgbouncer_wl} <- deploy_vm("pg2une-pgbouncer-#{arch}", 1, 256),
         {:ok, pgbouncer_ip} <- discover_ip(pgbouncer_wl.id),
         :ok <- configure_pgbouncer(pgbouncer_wl.id, primary_ip, replica_ip) do

      primary_node = Node.new(primary_wl.id, :primary, primary_ip)
      replica_node = Node.new(replica_wl.id, :sync_replica, replica_ip)
      pgbouncer_node = Node.new(pgbouncer_wl.id, :pgbouncer, pgbouncer_ip, port: 6432)

      nodes = %{
        primary_wl.id => %{primary_node | status: :healthy},
        replica_wl.id => %{replica_node | status: :healthy},
        pgbouncer_wl.id => %{pgbouncer_node | status: :healthy}
      }

      {:ok, %{state |
        nodes: nodes,
        primary_id: primary_wl.id,
        sync_replica_id: replica_wl.id,
        pgbouncer_id: pgbouncer_wl.id
      }}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp deploy_vm(config_name, cpu, memory_mb) do
    spec = %{
      type: "microvm",
      command: config_name,
      cpu: cpu,
      memory_mb: memory_mb,
      constraints: %{"microvm" => "true"}
    }

    case Mxc.Coordinator.deploy_workload(spec) do
      {:ok, workload} ->
        wait_for_ready(workload.id, 60_000)
        {:ok, workload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_ready(workload_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      Process.sleep(2_000)
      case Mxc.Coordinator.get_workload(workload_id) do
        {:ok, %{status: "running"}} -> :ready
        _ ->
          if System.monotonic_time(:millisecond) > deadline, do: :timeout, else: :waiting
      end
    end)
    |> Enum.find(& &1 != :waiting)
    |> case do
      :ready -> :ok
      :timeout -> {:error, :vm_boot_timeout}
    end
  end

  defp discover_ip(workload_id) do
    case Mxc.Coordinator.discover_workload_ip(workload_id) do
      {:ok, workload} -> {:ok, workload.ip}
      {:error, reason} -> {:error, {:ip_discovery_failed, reason}}
    end
  end

  defp configure_replication(replica_workload_id, primary_ip) do
    commands = [
      "sudo -u postgres psql -c \"ALTER SYSTEM SET primary_conninfo = 'host=#{primary_ip} port=5432 user=pg2une'\"",
      "sudo -u postgres touch /var/lib/postgresql/17/data/standby.signal",
      "sudo systemctl restart postgresql"
    ]

    Enum.reduce_while(commands, :ok, fn cmd, :ok ->
      case Mxc.Coordinator.exec_in_workload(replica_workload_id, cmd) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:replication_setup_failed, reason}}}
      end
    end)
  end

  defp configure_pgbouncer(pgbouncer_workload_id, primary_ip, _replica_ip) do
    config = Pg2une.PgBouncer.generate_config(primary_host: primary_ip)

    with {:ok, _} <- Mxc.Coordinator.exec_in_workload(
           pgbouncer_workload_id,
           "cat > /etc/pgbouncer/pgbouncer.ini << 'CONF'\n#{config}\nCONF"
         ),
         {:ok, _} <- Mxc.Coordinator.exec_in_workload(
           pgbouncer_workload_id,
           "kill -HUP $(cat /run/pgbouncer/pgbouncer.pid) 2>/dev/null || systemctl reload pgbouncer"
         ) do
      :ok
    end
  end

  # ── Canary Launch ──────────────────────────────────────────

  defp do_launch_canary(config, state) do
    arch = Mxc.Platform.guest_arch()
    primary_node = Map.fetch!(state.nodes, state.primary_id)

    with {:ok, canary_wl} <- deploy_vm("pg2une-postgres-replica-#{arch}", 4, 2048),
         {:ok, canary_ip} <- discover_ip(canary_wl.id),
         :ok <- configure_replication(canary_wl.id, primary_node.ip),
         :ok <- wait_for_replication_sync(canary_wl.id),
         :ok <- apply_config_to_node(canary_wl.id, config) do

      canary_node = %{Node.new(canary_wl.id, :canary, canary_ip) | status: :healthy}
      nodes = Map.put(state.nodes, canary_wl.id, canary_node)

      {:ok, %{state | nodes: nodes, canary_id: canary_wl.id}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp wait_for_replication_sync(replica_workload_id) do
    # Wait up to 60s for replay_lag < 1MB
    Stream.repeatedly(fn ->
      Process.sleep(3_000)
      case check_replay_lag(replica_workload_id) do
        {:ok, lag} when lag < 1_048_576 -> :synced
        {:ok, _lag} -> :waiting
        {:error, _} -> :waiting
      end
    end)
    |> Stream.take(20)
    |> Enum.find(& &1 == :synced)
    |> case do
      :synced -> :ok
      nil -> {:error, :replication_sync_timeout}
    end
  end

  defp check_replay_lag(workload_id) do
    cmd = "sudo -u postgres psql -t -A -c \"SELECT COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()), 0)\""
    case Mxc.Coordinator.exec_in_workload(workload_id, cmd) do
      {:ok, output} ->
        case Float.parse(String.trim(output)) do
          {lag, _} -> {:ok, trunc(lag)}
          :error -> {:error, :parse_error}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_config_to_node(workload_id, config) do
    param_mapping = Pg2une.PgConnector.param_mapping()

    statements = config
    |> Enum.filter(fn {key, _} -> Map.has_key?(param_mapping, key) end)
    |> Enum.map(fn {key, value} ->
      pg_name = Map.fetch!(param_mapping, key)
      pg_value = format_pg_value(key, value)
      "ALTER SYSTEM SET #{pg_name} = '#{pg_value}'"
    end)

    commands = statements ++ ["SELECT pg_reload_conf()"]
    sql = Enum.join(commands, "; ") <> ";"

    case Mxc.Coordinator.exec_in_workload(workload_id, "sudo -u postgres psql -c \"#{sql}\"") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:config_apply_failed, reason}}
    end
  end

  # ── Promote ────────────────────────────────────────────────

  defp do_promote_canary(state) do
    canary_id = state.canary_id
    primary_id = state.primary_id
    old_replica_id = state.sync_replica_id
    pgbouncer_id = state.pgbouncer_id

    canary_node = Map.fetch!(state.nodes, canary_id)
    primary_node = Map.fetch!(state.nodes, primary_id)

    with :ok <- pause_pgbouncer(pgbouncer_id),
         :ok <- ensure_canary_caught_up(canary_id),
         :ok <- pg_promote(canary_id),
         :ok <- reconfigure_as_replica(primary_id, canary_node.ip),
         :ok <- update_pgbouncer_backends(pgbouncer_id, canary_node.ip, primary_node.ip),
         :ok <- resume_pgbouncer(pgbouncer_id) do

      # Tear down old sync replica (its role was taken by old primary)
      stop_node(old_replica_id)

      # Update topology
      new_primary = %{canary_node | role: :primary, status: :healthy}
      new_replica = %{primary_node | role: :sync_replica, status: :healthy}

      nodes = state.nodes
      |> Map.put(canary_id, new_primary)
      |> Map.put(primary_id, new_replica)
      |> Map.delete(old_replica_id)

      {:ok, %{state |
        nodes: nodes,
        primary_id: canary_id,
        sync_replica_id: primary_id,
        canary_id: nil
      }}
    else
      {:error, reason} ->
        # Emergency: resume PgBouncer if paused
        resume_pgbouncer(pgbouncer_id)
        {:error, reason, state}
    end
  end

  defp pause_pgbouncer(pgbouncer_id) do
    Mxc.Coordinator.exec_in_workload(pgbouncer_id, "psql -h 127.0.0.1 -p 6432 pgbouncer -c 'PAUSE'")
    |> normalize_exec_result()
  end

  defp resume_pgbouncer(pgbouncer_id) do
    Mxc.Coordinator.exec_in_workload(pgbouncer_id, "psql -h 127.0.0.1 -p 6432 pgbouncer -c 'RESUME'")
    |> normalize_exec_result()
  end

  defp ensure_canary_caught_up(canary_id) do
    case check_replay_lag(canary_id) do
      {:ok, lag} when lag == 0 -> :ok
      {:ok, _lag} ->
        Process.sleep(2_000)
        ensure_canary_caught_up(canary_id)
      {:error, reason} -> {:error, {:lag_check_failed, reason}}
    end
  end

  defp pg_promote(canary_id) do
    Mxc.Coordinator.exec_in_workload(canary_id, "sudo -u postgres psql -c 'SELECT pg_promote()'")
    |> normalize_exec_result()
  end

  defp reconfigure_as_replica(node_id, new_primary_ip) do
    configure_replication(node_id, new_primary_ip)
  end

  defp update_pgbouncer_backends(pgbouncer_id, primary_ip, replica_ip) do
    config = Pg2une.PgBouncer.generate_config(primary_host: primary_ip)

    with {:ok, _} <- Mxc.Coordinator.exec_in_workload(
           pgbouncer_id,
           "cat > /etc/pgbouncer/pgbouncer.ini << 'CONF'\n#{config}\nCONF"
         ) do
      :ok
    end
  end

  # ── Rollback ───────────────────────────────────────────────

  defp do_rollback_canary(state) do
    # Tear down canary, revert PgBouncer to primary only
    if state.canary_id do
      stop_node(state.canary_id)
    end

    if state.pgbouncer_id do
      primary_node = Map.get(state.nodes, state.primary_id)
      if primary_node do
        config = Pg2une.PgBouncer.generate_config(primary_host: primary_node.ip)
        Mxc.Coordinator.exec_in_workload(
          state.pgbouncer_id,
          "cat > /etc/pgbouncer/pgbouncer.ini << 'CONF'\n#{config}\nCONF"
        )
        Mxc.Coordinator.exec_in_workload(
          state.pgbouncer_id,
          "kill -HUP $(cat /run/pgbouncer/pgbouncer.pid) 2>/dev/null || systemctl reload pgbouncer"
        )
      end
    end

    nodes = Map.delete(state.nodes, state.canary_id)
    %{state | nodes: nodes, canary_id: nil}
  end

  # ── Health Checks ──────────────────────────────────────────

  defp do_health_check(state) do
    if state.status == :uninitialized, do: state, else: do_check_nodes(state)
  end

  defp do_check_nodes(state) do
    updated_nodes = Map.new(state.nodes, fn {id, node} ->
      new_status = case node.role do
        :pgbouncer ->
          case Mxc.Coordinator.exec_in_workload(id, "psql -h 127.0.0.1 -p 6432 pgbouncer -c 'SHOW VERSION'") do
            {:ok, _} -> :healthy
            _ -> :down
          end

        role when role in [:primary, :sync_replica, :canary] ->
          case Mxc.Coordinator.exec_in_workload(id, "pg_isready -h 127.0.0.1") do
            {:ok, _} -> :healthy
            _ -> :down
          end
      end

      {id, %{node | status: new_status}}
    end)

    %{state | nodes: updated_nodes}
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp all_healthy?(state) do
    Enum.all?(state.nodes, fn {_id, node} -> Node.healthy?(node) end)
  end

  # ── Teardown ───────────────────────────────────────────────

  defp do_teardown(state) do
    Enum.each(state.nodes, fn {id, _node} ->
      stop_node(id)
    end)
  end

  defp stop_node(nil), do: :ok
  defp stop_node(workload_id) do
    try do
      Mxc.Coordinator.stop_workload(workload_id)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # ── Datalox Integration ────────────────────────────────────

  defp assert_cluster_health(state) do
    store = Anytune.FactStore.get_store(:pg2une)
    if store do
      # Clear old cluster health facts
      Anytune.FactStore.retract_fact(store, {:cluster_unhealthy, []})
      Anytune.FactStore.retract_fact(store, {:replication_lag_high, []})

      # Assert if not ready
      unless state.status == :ready do
        Anytune.FactStore.assert_fact(store, {:cluster_unhealthy, []})
      end
    end
  rescue
    _ -> :ok
  end

  # ── Helpers ────────────────────────────────────────────────

  defp normalize_exec_result({:ok, _}), do: :ok
  defp normalize_exec_result({:error, reason}), do: {:error, reason}

  defp format_pg_value(key, value) when is_number(value) do
    if String.ends_with?(key, "_mb"), do: "#{round(value)}MB", else: to_string(value)
  end
  defp format_pg_value(_key, value), do: to_string(value)
end
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c mix test test/pg2une/cluster_manager_test.exs`
Expected: 2 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/pg2une/cluster_manager.ex test/pg2une/cluster_manager_test.exs
```

---

### Task 5: PgBouncer — real routing implementation

Replace the stubbed `update_routing/2` with real config push via `Mxc.Coordinator.exec_in_workload`.

**Files:**
- Modify: `lib/pg2une/pgbouncer.ex` (entire file)
- Create: `test/pg2une/pgbouncer_routing_test.exs`

**Step 1: Write the test**

```elixir
defmodule Pg2une.PgBouncerRoutingTest do
  use ExUnit.Case, async: true

  alias Pg2une.PgBouncer

  test "generate_config with canary includes both backends" do
    config = PgBouncer.generate_config(
      primary_host: "10.0.0.1",
      canary_host: "10.0.0.2",
      canary_pct: 25
    )

    assert config =~ "host=10.0.0.1"
    assert config =~ "host=10.0.0.2"
    assert config =~ "canary"
  end

  test "generate_config without canary routes all to primary" do
    config = PgBouncer.generate_config(primary_host: "10.0.0.1")

    assert config =~ "host=10.0.0.1"
    refute config =~ "canary"
  end

  test "generate_pause_command returns PAUSE SQL" do
    assert PgBouncer.pgbouncer_command(:pause) == "PAUSE"
  end

  test "generate_resume_command returns RESUME SQL" do
    assert PgBouncer.pgbouncer_command(:resume) == "RESUME"
  end
end
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c mix test test/pg2une/pgbouncer_routing_test.exs`
Expected: FAIL on `pgbouncer_command` not defined

**Step 3: Rewrite PgBouncer module**

```elixir
defmodule Pg2une.PgBouncer do
  @moduledoc """
  Manages PgBouncer configuration for traffic routing between
  primary and canary PostgreSQL instances.

  Generates PgBouncer config and pushes updates to the PgBouncer microVM
  via Mxc.Coordinator.exec_in_workload.
  """

  require Logger

  @doc """
  Push updated routing config to PgBouncer VM and reload.
  `opts` must include :pgbouncer_workload_id and :primary_host.
  Optional: :canary_host, :canary_pct.
  """
  def update_routing(pgbouncer_workload_id, opts) when is_map(opts) do
    primary_host = Map.fetch!(opts, :primary_host)
    canary_host = Map.get(opts, :canary_host)
    canary_pct = Map.get(opts, :canary_pct, 0)

    config_opts = [primary_host: primary_host]
    config_opts = if canary_host && canary_pct > 0 do
      config_opts ++ [canary_host: canary_host, canary_pct: canary_pct]
    else
      config_opts
    end

    config = generate_config(config_opts)

    Logger.info("PgBouncer: updating routing — #{canary_pct}% to canary, #{100 - canary_pct}% to primary")

    with {:ok, _} <- Mxc.Coordinator.exec_in_workload(
           pgbouncer_workload_id,
           "cat > /etc/pgbouncer/pgbouncer.ini << 'CONF'\n#{config}\nCONF"
         ),
         {:ok, _} <- Mxc.Coordinator.exec_in_workload(
           pgbouncer_workload_id,
           "kill -HUP $(cat /run/pgbouncer/pgbouncer.pid) 2>/dev/null || systemctl reload pgbouncer"
         ) do
      Logger.info("PgBouncer: config pushed and reloaded")
      :ok
    else
      {:error, reason} ->
        Logger.error("PgBouncer: failed to update routing: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Execute a PgBouncer admin command (PAUSE, RESUME, RELOAD, etc.)
  """
  def admin_command(pgbouncer_workload_id, command) when command in [:pause, :resume, :reload] do
    sql = pgbouncer_command(command)
    Mxc.Coordinator.exec_in_workload(
      pgbouncer_workload_id,
      "psql -h 127.0.0.1 -p 6432 pgbouncer -c '#{sql}'"
    )
  end

  @doc "Returns the PgBouncer admin SQL for a given command atom."
  def pgbouncer_command(:pause), do: "PAUSE"
  def pgbouncer_command(:resume), do: "RESUME"
  def pgbouncer_command(:reload), do: "RELOAD"

  def generate_config(opts) do
    primary_host = Keyword.fetch!(opts, :primary_host)
    primary_port = Keyword.get(opts, :primary_port, 5432)
    canary_host = Keyword.get(opts, :canary_host)
    canary_port = Keyword.get(opts, :canary_port, 5432)
    canary_pct = Keyword.get(opts, :canary_pct, 0)

    databases_section = if canary_host && canary_pct > 0 do
      """
      [databases]
      primary = host=#{primary_host} port=#{primary_port} dbname=postgres
      canary = host=#{canary_host} port=#{canary_port} dbname=postgres
      * = host=#{primary_host} port=#{primary_port} dbname=postgres
      """
    else
      """
      [databases]
      * = host=#{primary_host} port=#{primary_port} dbname=postgres
      """
    end

    """
    #{databases_section}
    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = 6432
    auth_type = trust
    pool_mode = transaction
    max_client_conn = 1000
    default_pool_size = 50
    log_connections = 0
    log_disconnections = 0
    """
  end
end
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c mix test test/pg2une/pgbouncer_routing_test.exs`
Expected: 4 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/pg2une/pgbouncer.ex test/pg2une/pgbouncer_routing_test.exs
```

---

### Task 6: PgConnector — add connect_to/2

PgConnector currently always connects to the default `target_url`. ClusterManager needs to connect to specific nodes (the canary, the primary by IP).

**Files:**
- Modify: `lib/pg2une/pg_connector.ex:167-186`

**Step 1: Write the test**

Add to `test/pg2une/pg_connector_test.exs`:

```elixir
test "connect_to/2 creates connection options for a specific host" do
  # This tests the internal function via apply_config_to
  # We can't easily test the full round-trip without a second PG instance,
  # but we can verify connect_to returns proper opts
  opts = Pg2une.PgConnector.connection_opts("10.0.0.5", 5432)
  assert opts[:hostname] == "10.0.0.5"
  assert opts[:port] == 5432
  assert opts[:database] == "postgres"
end
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c mix test test/pg2une/pg_connector_test.exs --only test:"connect_to"`
Expected: FAIL — function not defined

**Step 3: Add connect_to and connection_opts**

In `lib/pg2une/pg_connector.ex`, add after the `param_mapping/0` function (line 165):

```elixir
@doc """
Returns Postgrex connection options for a specific host:port.
Used by ClusterManager to connect to specific cluster nodes.
"""
def connection_opts(hostname, port, opts \\ []) do
  [
    hostname: hostname,
    port: port,
    username: Keyword.get(opts, :username, "pg2une"),
    password: Keyword.get(opts, :password, ""),
    database: Keyword.get(opts, :database, "postgres")
  ]
end

@doc """
Apply config to a specific node identified by hostname:port.
Same as apply_config/1 but targets a specific PostgreSQL instance.
"""
def apply_config_to(hostname, port, config_map) when is_map(config_map) do
  opts = connection_opts(hostname, port)

  case Postgrex.start_link(opts) do
    {:ok, conn} ->
      try do
        do_apply_config(conn, config_map)
      after
        GenServer.stop(conn)
      end

    {:error, reason} ->
      {:error, {:connection_failed, reason}}
  end
end

@doc """
Read current config from a specific node.
"""
def read_config_from(hostname, port, param_list) when is_list(param_list) do
  opts = connection_opts(hostname, port)

  case Postgrex.start_link(opts) do
    {:ok, conn} ->
      try do
        do_read_config(conn, param_list)
      after
        GenServer.stop(conn)
      end

    {:error, reason} ->
      {:error, {:connection_failed, reason}}
  end
end
```

Then refactor `apply_config/1` to use a shared `do_apply_config/2`:

Extract the body of `apply_config/1` (lines 26-61) into `do_apply_config(conn, config_map)`, and have `apply_config/1` call `connect()` then delegate to it. Similarly for `read_current_config/1`.

**Step 4: Run tests**

Run: `nix develop -c mix test test/pg2une/pg_connector_test.exs`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/pg2une/pg_connector.ex test/pg2une/pg_connector_test.exs
```

---

### Task 7: Update DeploymentManager canary pipeline to use ClusterManager

Replace the stubbed canary pipeline in DeploymentManager with calls to ClusterManager.

**Files:**
- Modify: `lib/pg2une/deployment_manager.ex:206-395`

**Step 1: Rewrite canary pipeline**

Replace `run_canary_pipeline/1` and its dependent functions:

```elixir
defp run_canary_pipeline(state) do
  with {:ok, state} <- capture_baseline(state),
       {:ok, config, state} <- run_optimizer(state),
       {:ok, config} <- filter_restart_params(config),
       :ok <- Pg2une.ClusterManager.launch_canary(config),
       {:ok, result, result_metrics, state} <- route_and_validate_canary(state) do
    case result do
      :improved ->
        case Pg2une.ClusterManager.promote_canary() do
          :ok ->
            improvement_pct = calculate_improvement(state.baseline_metrics, result_metrics)
            record_result(state, config, :promoted, result_metrics, improvement_pct)
            {:ok, %{status: :promoted, config: config, improvement_pct: improvement_pct}, state}

          {:error, reason} ->
            Pg2une.ClusterManager.rollback_canary()
            record_result(state, config, :rolled_back, result_metrics, nil)
            {:error, {:promotion_failed, reason}, state}
        end

      :regressed ->
        Pg2une.ClusterManager.rollback_canary()
        record_result(state, config, :rolled_back, result_metrics, nil)
        {:ok, %{status: :rolled_back}, state}
    end
  else
    {:error, reason, state} ->
      Pg2une.ClusterManager.rollback_canary()
      {:error, reason, state}

    {:error, reason} ->
      Pg2une.ClusterManager.rollback_canary()
      {:error, reason, state}
  end
end

defp route_and_validate_canary(state) do
  state = %{state | state: :routing_traffic}
  topology = Pg2une.ClusterManager.topology()
  pgbouncer_id = topology.pgbouncer_id
  primary_node = Map.fetch!(topology.nodes, topology.primary_id)
  canary_node = Map.fetch!(topology.nodes, topology.canary_id)

  result = Enum.reduce_while(@traffic_steps, {:improved, nil}, fn pct, _acc ->
    Logger.info("DeploymentManager: routing #{pct}% reads to canary")

    Pg2une.PgBouncer.update_routing(pgbouncer_id, %{
      primary_host: primary_node.ip,
      canary_host: canary_node.ip,
      canary_pct: pct
    })

    wait_time = if pct >= 50, do: 60_000, else: @stabilization_wait
    Process.sleep(wait_time)

    current = Pg2une.MetricsStore.recent_system_metrics(1)
    if current == [] do
      {:cont, {:improved, state.baseline_metrics}}
    else
      result_metrics = average_metrics(current)
      case validate_at_step(state.baseline_metrics, result_metrics, pct) do
        :pass -> {:cont, {:improved, result_metrics}}
        :fail -> {:halt, {:regressed, result_metrics}}
      end
    end
  end)

  case result do
    {:improved, metrics} -> {:ok, :improved, metrics, %{state | state: :validating}}
    {:regressed, metrics} -> {:ok, :regressed, metrics, %{state | state: :validating}}
  end
end

defp validate_at_step(baseline, current, pct) do
  latency_change = safe_pct_change(baseline.latency_p99, current.latency_p99)
  tps_change = safe_pct_change(baseline.tps, current.tps)

  {latency_gate, tps_gate} = if pct >= 50 do
    {0.15, -0.05}  # Stricter at higher traffic: p99 < 115%, TPS >= 95%
  else
    {0.20, -1.0}   # Lenient early: p99 < 120%, no TPS gate
  end

  if latency_change > latency_gate or tps_change < tps_gate do
    Logger.warning("DeploymentManager: validation failed at #{pct}% — latency_change=#{Float.round(latency_change, 3)}, tps_change=#{Float.round(tps_change, 3)}")
    :fail
  else
    :pass
  end
end
```

**Step 2: Remove old canary functions**

Delete: `launch_canary/1`, `apply_config_to_canary/2`, `route_and_validate/1`, `validate_canary/1`, `promote/2`, `rollback/1`, `cleanup_canary/1`, `do_ensure_infrastructure/1`, `do_teardown/1`.

Replace `ensure_infrastructure` handler:

```elixir
@impl true
def handle_call(:ensure_infrastructure, _from, state) do
  case Pg2une.ClusterManager.deploy_cluster() do
    :ok -> {:reply, :ok, state}
    {:error, reason} -> {:reply, {:error, reason}, state}
  end
end

@impl true
def handle_call(:teardown, _from, state) do
  Pg2une.ClusterManager.teardown_cluster()
  {:reply, :ok, %__MODULE__{state: :idle, mode: state.mode}}
end
```

**Step 3: Clean up struct — remove fields handled by ClusterManager**

Remove from struct: `:canary_workload_id`, `:pgbouncer_workload_id`, `:primary_workload_id`.

**Step 4: Verify compilation**

Run: `nix develop -c mix compile`
Expected: Clean compile

**Step 5: Commit**

```bash
git add lib/pg2une/deployment_manager.ex
```

---

### Task 8: Add Datalog rules for cluster health suppression

**Files:**
- Modify: `priv/rules/pg2une.dl`

**Step 1: Add rules**

Append to `priv/rules/pg2une.dl`:

```datalog
% Cluster health gates — suppress optimization during unhealthy cluster states
suppress_action() :- cluster_unhealthy().
suppress_action() :- replication_lag_high().
```

**Step 2: Verify compilation**

Run: `nix develop -c mix compile`
Expected: Clean compile

**Step 3: Commit**

```bash
git add priv/rules/pg2une.dl
```

---

### Task 9: Add ClusterManager to supervision tree

**Files:**
- Modify: `lib/pg2une/application.ex`

**Step 1: Add ClusterManager after Config agent, before WorkloadDetector**

In `lib/pg2une/application.ex`, add to the children list after `{Pg2une.Config, default_config()}`:

```elixir
Pg2une.ClusterManager,
```

**Step 2: Verify compilation**

Run: `nix develop -c mix compile`
Expected: Clean compile

**Step 3: Commit**

```bash
git add lib/pg2une/application.ex
```

---

### Task 10: Cluster API endpoints

**Files:**
- Modify: `lib/pg2une/router.ex`

**Step 1: Add cluster endpoints**

Add these routes to `lib/pg2une/router.ex` before the `match _` catch-all:

```elixir
# Cluster topology
get "/api/cluster" do
  topology = Pg2une.ClusterManager.topology()

  nodes = Map.new(topology.nodes, fn {id, node} ->
    {id, %{
      role: node.role,
      ip: node.ip,
      port: node.port,
      status: node.status,
      config_version: node.config_version,
      launched_at: node.launched_at
    }}
  end)

  send_json(conn, 200, %{
    cluster: %{
      status: topology.status,
      config_version: topology.config_version,
      primary_id: topology.primary_id,
      sync_replica_id: topology.sync_replica_id,
      pgbouncer_id: topology.pgbouncer_id,
      canary_id: topology.canary_id,
      nodes: nodes
    }
  })
end

# Deploy cluster
post "/api/cluster/deploy" do
  case Pg2une.ClusterManager.deploy_cluster() do
    :ok -> send_json(conn, 200, %{status: "ok"})
    {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
  end
end

# Teardown cluster
delete "/api/cluster" do
  Pg2une.ClusterManager.teardown_cluster()
  send_json(conn, 200, %{status: "ok"})
end

# Specific node
get "/api/cluster/nodes/:node_id" do
  topology = Pg2une.ClusterManager.topology()

  case Map.get(topology.nodes, node_id) do
    nil -> send_json(conn, 404, %{error: "node not found"})
    node ->
      send_json(conn, 200, %{node: %{
        id: node_id,
        role: node.role,
        ip: node.ip,
        port: node.port,
        status: node.status,
        config_version: node.config_version,
        launched_at: node.launched_at
      }})
  end
end
```

**Step 2: Update infrastructure endpoints to delegate to ClusterManager**

The existing `GET /api/infrastructure` and `POST /api/infrastructure` already delegate to DeploymentManager, which now delegates to ClusterManager. No changes needed.

**Step 3: Verify compilation**

Run: `nix develop -c mix compile`
Expected: Clean compile

**Step 4: Commit**

```bash
git add lib/pg2une/router.ex
```

---

### Task 11: Integration test — full canary pipeline

This test validates the end-to-end flow when mxc is available. Skip if mxc/microVM infrastructure isn't running.

**Files:**
- Create: `test/pg2une/cluster_manager_integration_test.exs`

**Step 1: Write the test**

```elixir
defmodule Pg2une.ClusterManagerIntegrationTest do
  use ExUnit.Case

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    # Skip if microVM support isn't available
    unless Mxc.Platform.can_run_microvms?() do
      IO.puts("Skipping: microVM support not available on this platform")
      :skip
    end
  end

  test "deploy_cluster creates primary + replica + pgbouncer" do
    assert :ok = Pg2une.ClusterManager.deploy_cluster()

    topology = Pg2une.ClusterManager.topology()
    assert topology.status == :ready
    assert map_size(topology.nodes) == 3
    assert topology.primary_id != nil
    assert topology.sync_replica_id != nil
    assert topology.pgbouncer_id != nil

    # Cleanup
    Pg2une.ClusterManager.teardown_cluster()
  end

  test "full canary lifecycle: launch, validate, promote" do
    :ok = Pg2une.ClusterManager.deploy_cluster()

    config = %{"work_mem_mb" => 32, "random_page_cost" => 1.1}
    assert :ok = Pg2une.ClusterManager.launch_canary(config)

    topology = Pg2une.ClusterManager.topology()
    assert topology.canary_id != nil
    assert topology.status == :optimizing

    # Wait for sync
    Process.sleep(10_000)
    assert Pg2une.ClusterManager.canary_synced?()

    # Promote
    assert :ok = Pg2une.ClusterManager.promote_canary()

    topology = Pg2une.ClusterManager.topology()
    assert topology.status == :ready
    assert topology.canary_id == nil
    assert map_size(topology.nodes) == 3  # Still 3 nodes after role swap

    # Cleanup
    Pg2une.ClusterManager.teardown_cluster()
  end

  test "rollback_canary tears down canary and reverts routing" do
    :ok = Pg2une.ClusterManager.deploy_cluster()

    config = %{"work_mem_mb" => 32}
    :ok = Pg2une.ClusterManager.launch_canary(config)

    assert :ok = Pg2une.ClusterManager.rollback_canary()

    topology = Pg2une.ClusterManager.topology()
    assert topology.status == :ready
    assert topology.canary_id == nil
    assert map_size(topology.nodes) == 3  # Original 3 still running

    # Cleanup
    Pg2une.ClusterManager.teardown_cluster()
  end
end
```

**Step 2: Run (skip in CI, run manually when mxc is available)**

Run: `nix develop -c mix test test/pg2une/cluster_manager_integration_test.exs --include integration`

This will skip on macOS (no microVM support without QEMU setup). On Linux with KVM, it should run end-to-end.

**Step 3: Commit**

```bash
git add test/pg2une/cluster_manager_integration_test.exs
```

---

### Task 12: Update documentation

**Files:**
- Modify: `docs/plans/2026-02-19-cluster-lifecycle-design.md` (already done)
- Modify: `docs/api.md` — add cluster endpoints
- Modify: `docs/deployment_modes.md` — update canary mode description

**Step 1: Add cluster API docs to docs/api.md**

Append before the closing of the file:

```markdown
### GET /api/cluster

Current cluster topology, node roles, IPs, health status.

**Response:**
```json
{
  "cluster": {
    "status": "ready",
    "config_version": 3,
    "primary_id": "wk-abc123",
    "sync_replica_id": "wk-def456",
    "pgbouncer_id": "wk-ghi789",
    "canary_id": null,
    "nodes": {
      "wk-abc123": {
        "role": "primary",
        "ip": "192.168.100.2",
        "port": 5432,
        "status": "healthy",
        "config_version": 3
      }
    }
  }
}
```

### POST /api/cluster/deploy

Bootstrap a new cluster (primary + sync replica + pgbouncer).

### DELETE /api/cluster

Teardown entire cluster.

### GET /api/cluster/nodes/:id

Specific node details.
```

**Step 2: Commit**

```bash
git add docs/api.md docs/deployment_modes.md
```

---

## Execution Order

Tasks 1-2 (mxc patches) must come first. Then:
- Task 3 (Node struct) before Task 4 (ClusterManager)
- Task 5 (PgBouncer) and Task 6 (PgConnector) can be done in parallel
- Task 7 (DeploymentManager update) depends on Tasks 4, 5, 6
- Task 8 (Datalog rules) can be done anytime
- Task 9 (supervision tree) depends on Task 4
- Task 10 (API) depends on Task 4
- Task 11 (integration test) depends on all above
- Task 12 (docs) can be done anytime

```
[1: mxc exec] → [2: mxc IP] → [3: Node] → [4: ClusterManager] → [7: DeploymentMgr] → [11: Integration]
                                [5: PgBouncer] ↗                     [9: Supervision]
                                [6: PgConnector] ↗                   [10: API]
                                [8: Datalog rules]                   [12: Docs]
```
