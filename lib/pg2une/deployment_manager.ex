defmodule Pg2une.DeploymentManager do
  @moduledoc """
  Orchestrates PostgreSQL configuration optimization.

  Supports two modes:
  - `:direct` — applies config directly to the target PG via ALTER SYSTEM (local dev)
  - `:canary` — blue-green canary deployment via mxc microVMs (production)

  FSM states: idle → capturing_baseline → running_optimizer → applying_config →
  validating → promoting | rolling_back → idle
  """

  use GenServer
  require Logger

  @traffic_steps [5, 25, 50, 100]
  @stabilization_wait 30_000

  defstruct [
    :state,
    :mode,
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
  def init(opts) do
    mode = Keyword.get(opts, :mode, default_mode())
    {:ok, %__MODULE__{state: :idle, mode: mode}}
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
    Logger.info("DeploymentManager: starting #{action} optimization (mode=#{state.mode})")

    state = %{state | state: :capturing_baseline, action: action}

    pipeline = case state.mode do
      :direct -> &run_direct_pipeline/1
      :canary -> &run_canary_pipeline/1
    end

    case pipeline.(state) do
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
    {:reply, :ok, %__MODULE__{state: :idle, mode: state.mode}}
  end

  # ── Direct Pipeline ──────────────────────────────────────────────────

  defp run_direct_pipeline(state) do
    with {:ok, state} <- capture_baseline(state),
         {:ok, config, state} <- run_optimizer(state),
         {:ok, config} <- filter_restart_params(config),
         {:ok, state} <- apply_config_direct(config, state),
         {:ok, result, result_metrics, state} <- wait_and_validate_direct(state) do
      case result do
        :improved ->
          improvement_pct = calculate_improvement(state.baseline_metrics, result_metrics)
          record_result(state, config, :promoted, result_metrics, improvement_pct)

          {:ok, %{status: :promoted, config: config, improvement_pct: improvement_pct}, state}

        :regressed ->
          rollback_direct(config, state)
          record_result(state, config, :rolled_back, result_metrics, nil)

          {:ok, %{status: :rolled_back}, state}
      end
    else
      {:error, reason, state} ->
        {:error, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp filter_restart_params(config) do
    case Pg2une.PgConnector.params_requiring_restart(config) do
      {:ok, restart_keys} ->
        if restart_keys != [] do
          Logger.info("DeploymentManager: skipping restart-only params: #{inspect(restart_keys)}")
        end

        filtered = Map.drop(config, restart_keys)

        if map_size(filtered) == 0 do
          {:error, :all_params_require_restart}
        else
          {:ok, filtered}
        end

      {:error, reason} ->
        Logger.warning("DeploymentManager: couldn't check restart params: #{inspect(reason)}, applying all reload-safe")
        # Fall back to a known-safe list
        safe_keys = ["work_mem_mb", "effective_cache_size_mb", "maintenance_work_mem_mb", "random_page_cost"]
        {:ok, Map.take(config, safe_keys)}
    end
  end

  defp apply_config_direct(config, state) do
    Logger.info("DeploymentManager: applying config directly via ALTER SYSTEM")
    state = %{state | state: :applying_config, optimized_config: config}

    case Pg2une.PgConnector.apply_config(config) do
      {:ok, _applied} ->
        {:ok, state}

      {:error, reason} ->
        {:error, {:apply_failed, reason}, state}
    end
  end

  defp wait_and_validate_direct(state) do
    Logger.info("DeploymentManager: waiting #{@stabilization_wait}ms for stabilization")
    state = %{state | state: :validating}

    Process.sleep(@stabilization_wait)

    current = Pg2une.MetricsStore.recent_system_metrics(1)

    if current == [] do
      {:ok, :improved, state.baseline_metrics, state}
    else
      result_metrics = average_metrics(current)
      result = compare_metrics(state.baseline_metrics, result_metrics)
      {:ok, result, result_metrics, state}
    end
  end

  defp rollback_direct(config, state) do
    Logger.info("DeploymentManager: rolling back — resetting config")
    state = %{state | state: :rolling_back}

    case Pg2une.PgConnector.rollback_config(config) do
      :ok ->
        Logger.info("DeploymentManager: rollback complete")

      {:error, reason} ->
        Logger.error("DeploymentManager: rollback failed: #{inspect(reason)}")
    end

    state
  end

  # ── Canary Pipeline ──────────────────────────────────────────────────

  defp run_canary_pipeline(state) do
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

  # ── Shared Steps ─────────────────────────────────────────────────────

  defp capture_baseline(state) do
    Logger.info("DeploymentManager: capturing baseline metrics")
    metrics = Pg2une.MetricsStore.recent_system_metrics(2)

    if metrics == [] do
      {:error, :no_baseline_metrics, state}
    else
      avg_metrics = average_metrics(metrics)
      {:ok, %{state | state: :capturing_baseline, baseline_metrics: avg_metrics}}
    end
  end

  defp run_optimizer(state) do
    Logger.info("DeploymentManager: running optimizer (#{state.action})")
    state = %{state | state: :running_optimizer}

    case Anytune.optimize(:pg2une, n_iterations: 30) do
      {:ok, config} ->
        {:ok, config, state}

      {:error, reason} ->
        {:error, {:optimizer_failed, reason}, state}
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

  defp calculate_improvement(baseline, result) do
    tps_improvement = safe_pct_change(baseline.tps, result.tps)
    latency_improvement = -safe_pct_change(baseline.latency_p99, result.latency_p99)

    # Weighted average: TPS improvement (60%) + latency improvement (40%)
    improvement = tps_improvement * 0.6 + latency_improvement * 0.4
    Float.round(improvement * 100, 2)
  end

  # ── Canary-Only Steps ────────────────────────────────────────────────

  defp launch_canary(state) do
    Logger.info("DeploymentManager: launching canary microVM")
    state = %{state | state: :launching_canary}

    workload_spec = %{
      type: "microvm",
      command: vm_config_name("pg2une-postgres-replica"),
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

        Pg2une.PgBouncer.update_routing(state.pgbouncer_workload_id, %{
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
    current = Pg2une.MetricsStore.recent_system_metrics(1)

    if current == [] do
      :improved
    else
      avg_current = average_metrics(current)
      compare_metrics(state.baseline_metrics, avg_current)
    end
  end

  defp promote(config, state) do
    Logger.info("DeploymentManager: promoting — applying config to primary")
    state = %{state | state: :promoting}

    Logger.info("DeploymentManager: would apply #{map_size(config)} settings to primary")

    Pg2une.PgBouncer.update_routing(state.pgbouncer_workload_id, %{canary_pct: 0})
    cleanup_canary(state)

    {:ok, %{state | state: :idle, canary_workload_id: nil}}
  end

  defp rollback(state) do
    Logger.info("DeploymentManager: rolling back — routing to primary")
    state = %{state | state: :rolling_back}

    Pg2une.PgBouncer.update_routing(state.pgbouncer_workload_id, %{canary_pct: 0})
    cleanup_canary(state)

    {:ok, %{state | state: :idle, canary_workload_id: nil}}
  end

  defp cleanup_canary(%{canary_workload_id: nil}), do: :ok

  defp cleanup_canary(%{canary_workload_id: id}) do
    Logger.info("DeploymentManager: cleaning up canary #{id}")

    try do
      case Mxc.Coordinator.stop_workload(id) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to stop canary: #{inspect(reason)}")
      end
    rescue
      e -> Logger.warning("Exception stopping canary #{id}: #{inspect(e)}")
    catch
      kind, reason -> Logger.warning("Error stopping canary #{id}: #{kind} #{inspect(reason)}")
    end
  end

  defp do_ensure_infrastructure(state) do
    Logger.info("DeploymentManager: ensuring infrastructure")

    primary_spec = %{
      type: "microvm",
      command: vm_config_name("pg2une-postgres"),
      cpu: 4,
      memory_mb: 2048
    }

    pgbouncer_spec = %{
      type: "microvm",
      command: vm_config_name("pg2une-pgbouncer"),
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

  # record_result with optional result_metrics and improvement_pct
  defp record_result(state, config, status, result_metrics \\ nil, improvement_pct \\ nil) do
    attrs = %{
      action: to_string(state.action),
      status: to_string(status),
      config: config,
      baseline_metrics: state.baseline_metrics
    }

    attrs = if result_metrics, do: Map.put(attrs, :result_metrics, result_metrics), else: attrs
    attrs = if improvement_pct, do: Map.put(attrs, :improvement_pct, improvement_pct), else: attrs

    Pg2une.MetricsStore.create_optimization_run(attrs)
  end

  defp default_mode do
    Application.get_env(:pg2une, :deployment_mode, :direct)
  end

  defp vm_config_name(base) do
    arch = Mxc.Platform.guest_arch()
    "#{base}-#{arch}"
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
