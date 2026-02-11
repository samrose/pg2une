defmodule Pgtune.DeploymentManager do
  @moduledoc """
  Orchestrates blue-green canary deployment via mxc microVMs.

  FSM states: idle → capturing_baseline → launching_canary → applying_config →
  routing_traffic → validating → promoting | rolling_back → idle

  All infrastructure (primary PG, replica PG, PgBouncer) runs as mxc workloads.
  """

  use GenServer
  require Logger

  @traffic_steps [5, 25, 50, 100]
  @stabilization_wait 30_000

  defstruct [
    :state,
    :current_run,
    :canary_workload_id,
    :pgbouncer_workload_id,
    :primary_workload_id,
    :baseline_metrics,
    :optimized_config,
    :action
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def start_optimization(action) when action in [:knobs, :queries, :holistic] do
    GenServer.call(__MODULE__, {:start_optimization, action}, 300_000)
  end

  def ensure_infrastructure do
    GenServer.call(__MODULE__, :ensure_infrastructure, 120_000)
  end

  def teardown do
    GenServer.call(__MODULE__, :teardown, 60_000)
  end

  # Server

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{state: :idle}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = case state.state do
      :idle -> :idle
      other -> {other, state.action}
    end
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:start_optimization, action}, _from, %{state: :idle} = state) do
    Logger.info("DeploymentManager: starting #{action} optimization")

    state = %{state | state: :capturing_baseline, action: action}

    case run_optimization_pipeline(state) do
      {:ok, result, new_state} ->
        {:reply, {:ok, result}, %{new_state | state: :idle}}

      {:error, reason, new_state} ->
        Logger.error("DeploymentManager: optimization failed: #{inspect(reason)}")
        {:reply, {:error, reason}, %{new_state | state: :idle}}
    end
  end

  @impl true
  def handle_call({:start_optimization, _action}, _from, state) do
    {:reply, {:error, {:busy, state.state}}, state}
  end

  @impl true
  def handle_call(:ensure_infrastructure, _from, state) do
    case do_ensure_infrastructure(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:teardown, _from, state) do
    do_teardown(state)
    {:reply, :ok, %__MODULE__{state: :idle}}
  end

  # Pipeline

  defp run_optimization_pipeline(state) do
    with {:ok, state} <- capture_baseline(state),
         {:ok, config, state} <- run_optimizer(state),
         {:ok, state} <- launch_canary(state),
         {:ok, state} <- apply_config_to_canary(config, state),
         {:ok, result, state} <- route_and_validate(state) do
      case result do
        :improved ->
          {:ok, state} = promote(config, state)
          record_result(state, config, :promoted)
          {:ok, %{status: :promoted, config: config}, state}

        :regressed ->
          {:ok, state} = rollback(state)
          record_result(state, config, :rolled_back)
          {:ok, %{status: :rolled_back}, state}
      end
    else
      {:error, reason, state} ->
        cleanup_canary(state)
        {:error, reason, state}
    end
  end

  defp capture_baseline(state) do
    Logger.info("DeploymentManager: capturing baseline metrics")
    metrics = Pgtune.MetricsStore.recent_system_metrics(2)

    if metrics == [] do
      {:error, :no_baseline_metrics, state}
    else
      avg_metrics = average_metrics(metrics)
      {:ok, %{state | state: :capturing_baseline, baseline_metrics: avg_metrics}}
    end
  end

  defp run_optimizer(state) do
    Logger.info("DeploymentManager: running optimizer (#{state.action})")

    case Anytune.optimize(:pgtune, n_iterations: 30) do
      {:ok, config} ->
        {:ok, config, state}

      {:error, reason} ->
        {:error, {:optimizer_failed, reason}, state}
    end
  end

  defp launch_canary(state) do
    Logger.info("DeploymentManager: launching canary microVM")
    state = %{state | state: :launching_canary}

    workload_spec = %{
      type: "microvm",
      command: "pgtune-postgres-replica",
      cpu: 4,
      memory_mb: 2048,
      constraints: %{"microvm" => "true"}
    }

    case Mxc.Coordinator.deploy_workload(workload_spec) do
      {:ok, workload} ->
        {:ok, %{state | canary_workload_id: workload.id}}

      {:error, reason} ->
        {:error, {:canary_launch_failed, reason}, state}
    end
  end

  defp apply_config_to_canary(config, state) do
    Logger.info("DeploymentManager: applying config to canary")
    state = %{state | state: :applying_config, optimized_config: config}

    # Connect to canary and apply knobs via ALTER SYSTEM
    # In practice, we'd get the canary's IP from mxc workload info
    knob_statements =
      config
      |> Enum.filter(fn {key, _val} -> String.starts_with?(key, "shared_buffers") or
                                        String.starts_with?(key, "work_mem") or
                                        String.starts_with?(key, "effective_cache") or
                                        String.starts_with?(key, "maintenance_work") or
                                        String.starts_with?(key, "random_page") or
                                        String.starts_with?(key, "max_connections") end)
      |> Enum.map(fn {key, value} ->
        pg_key = key |> String.replace("_mb", "") |> String.replace("_", ".")
        "ALTER SYSTEM SET #{pg_key} = '#{format_value(key, value)}';"
      end)

    Logger.info("DeploymentManager: would apply #{length(knob_statements)} ALTER SYSTEM statements")

    {:ok, state}
  end

  defp route_and_validate(state) do
    Logger.info("DeploymentManager: routing traffic and validating")
    state = %{state | state: :routing_traffic}

    result =
      Enum.reduce_while(@traffic_steps, :improved, fn pct, _acc ->
        Logger.info("DeploymentManager: routing #{pct}% to canary")

        Pgtune.PgBouncer.update_routing(state.pgbouncer_workload_id, %{
          canary_pct: pct
        })

        Process.sleep(@stabilization_wait)

        case validate_canary(state) do
          :improved -> {:cont, :improved}
          :regressed -> {:halt, :regressed}
        end
      end)

    {:ok, result, %{state | state: :validating}}
  end

  defp validate_canary(state) do
    current = Pgtune.MetricsStore.recent_system_metrics(1)

    if current == [] do
      :improved
    else
      avg_current = average_metrics(current)
      compare_metrics(state.baseline_metrics, avg_current)
    end
  end

  defp compare_metrics(baseline, current) do
    tps_change = safe_pct_change(baseline.tps, current.tps)
    latency_change = safe_pct_change(baseline.latency_p99, current.latency_p99)

    cond do
      latency_change > 0.10 -> :regressed
      tps_change < -0.10 -> :regressed
      true -> :improved
    end
  end

  defp promote(config, state) do
    Logger.info("DeploymentManager: promoting — applying config to primary")
    state = %{state | state: :promoting}

    # Apply knobs to primary
    Logger.info("DeploymentManager: would apply #{map_size(config)} settings to primary")

    # Route 100% back to primary
    Pgtune.PgBouncer.update_routing(state.pgbouncer_workload_id, %{canary_pct: 0})

    # Stop canary
    cleanup_canary(state)

    {:ok, %{state | state: :idle, canary_workload_id: nil}}
  end

  defp rollback(state) do
    Logger.info("DeploymentManager: rolling back — routing to primary")
    state = %{state | state: :rolling_back}

    Pgtune.PgBouncer.update_routing(state.pgbouncer_workload_id, %{canary_pct: 0})
    cleanup_canary(state)

    {:ok, %{state | state: :idle, canary_workload_id: nil}}
  end

  defp cleanup_canary(%{canary_workload_id: nil}), do: :ok

  defp cleanup_canary(%{canary_workload_id: id}) do
    Logger.info("DeploymentManager: cleaning up canary #{id}")

    case Mxc.Coordinator.stop_workload(id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to stop canary: #{inspect(reason)}")
    end
  end

  defp do_ensure_infrastructure(state) do
    # Launch primary PG and PgBouncer if not running
    Logger.info("DeploymentManager: ensuring infrastructure")

    primary_spec = %{
      type: "microvm",
      command: "pgtune-postgres",
      cpu: 4,
      memory_mb: 2048
    }

    pgbouncer_spec = %{
      type: "microvm",
      command: "pgtune-pgbouncer",
      cpu: 1,
      memory_mb: 256
    }

    with {:ok, primary} <- Mxc.Coordinator.deploy_workload(primary_spec),
         {:ok, pgbouncer} <- Mxc.Coordinator.deploy_workload(pgbouncer_spec) do
      {:ok, %{state |
        primary_workload_id: primary.id,
        pgbouncer_workload_id: pgbouncer.id
      }}
    end
  end

  defp do_teardown(state) do
    for id <- [state.canary_workload_id, state.pgbouncer_workload_id, state.primary_workload_id] do
      if id, do: Mxc.Coordinator.stop_workload(id)
    end
  end

  defp record_result(state, config, status) do
    Pgtune.MetricsStore.create_optimization_run(%{
      action: to_string(state.action),
      status: to_string(status),
      config: config,
      baseline_metrics: state.baseline_metrics
    })
  end

  defp average_metrics(snapshots) do
    count = length(snapshots)
    if count == 0, do: %{}, else: do_average(snapshots, count)
  end

  defp do_average(snapshots, count) do
    sums = Enum.reduce(snapshots, %{tps: 0, latency_p99: 0, buffer_hit_ratio: 0}, fn s, acc ->
      %{
        tps: acc.tps + (s.tps || 0),
        latency_p99: acc.latency_p99 + (s.latency_p99 || 0),
        buffer_hit_ratio: acc.buffer_hit_ratio + (s.buffer_hit_ratio || 0)
      }
    end)

    %{
      tps: sums.tps / count,
      latency_p99: sums.latency_p99 / count,
      buffer_hit_ratio: sums.buffer_hit_ratio / count
    }
  end

  defp safe_pct_change(baseline, current) when is_number(baseline) and baseline != 0 do
    (current - baseline) / baseline
  end

  defp safe_pct_change(_, _), do: 0.0

  defp format_value(key, value) when is_number(value) do
    if String.ends_with?(key, "_mb") do
      "#{round(value)}MB"
    else
      to_string(value)
    end
  end

  defp format_value(_key, value), do: to_string(value)
end
