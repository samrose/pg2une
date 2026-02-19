defmodule Pg2une.PeriodicAnalyzer do
  @moduledoc """
  Runs heavy ML analysis periodically on accumulated metrics history.

  Schedules:
  - E-Divisive change point detection: every 5 minutes (needs 20+ data points)
  - USL scalability modeling: every 5 minutes (needs 5+ data points)
  - Prophet forecasting: every 30 minutes (needs 24+ data points)
  - Confidence recalculation: after each E-Divisive or USL run

  Asserts results as Datalox facts so that Datalog rules
  (action_ready, should_act) can fire.
  """

  use GenServer
  require Logger

  @edivisive_interval 5 * 60_000
  @usl_interval 5 * 60_000
  @prophet_interval 30 * 60_000

  @edivisive_min_points 20
  @usl_min_points 5
  @prophet_min_points 24

  @metrics_to_analyze ["tps", "latency_p99", "buffer_hit_ratio"]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule(:edivisive, @edivisive_interval)
    schedule(:usl, @usl_interval)
    schedule(:prophet, @prophet_interval)

    {:ok, %{
      usl_params: nil,
      last_change_points: %{},
      last_usl_deviation: nil
    }}
  end

  @impl true
  def handle_info(:edivisive, state) do
    state = run_edivisive(state)
    schedule(:edivisive, @edivisive_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:usl, state) do
    state = run_usl(state)
    schedule(:usl, @usl_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:prophet, state) do
    run_prophet()
    schedule(:prophet, @prophet_interval)
    {:noreply, state}
  end

  # ── E-Divisive Change Point Detection ────────────────────────────────

  defp run_edivisive(state) do
    snapshots = Pg2une.MetricsStore.recent_system_metrics(30)

    if length(snapshots) < @edivisive_min_points do
      Logger.debug("PeriodicAnalyzer: E-Divisive skipped, only #{length(snapshots)} points (need #{@edivisive_min_points})")
      state
    else
      change_points =
        Enum.reduce(@metrics_to_analyze, %{}, fn metric, acc ->
          values = extract_metric_values(snapshots, metric)

          case Anytune.edivisive(:pg2une, metric, values) do
            {:ok, result} ->
              points = result["change_points"] || []

              significant =
                Enum.filter(points, fn cp ->
                  (cp["magnitude"] || 0) > 0.10
                end)

              if significant != [] do
                max_magnitude = significant |> Enum.map(& &1["magnitude"]) |> Enum.max()
                Logger.info("PeriodicAnalyzer: E-Divisive detected change point in #{metric}, magnitude=#{max_magnitude}")
                assert_change_point(metric, max_magnitude)
                Map.put(acc, metric, max_magnitude)
              else
                retract_change_point(metric)
                acc
              end

            {:error, reason} ->
              Logger.warning("PeriodicAnalyzer: E-Divisive failed for #{metric}: #{inspect(reason)}")
              acc
          end
        end)

      state = %{state | last_change_points: change_points}
      recalculate_confidence(state)
      state
    end
  end

  # ── USL Scalability Modeling ─────────────────────────────────────────

  defp run_usl(state) do
    snapshots = Pg2une.MetricsStore.recent_system_metrics(30)

    if length(snapshots) < @usl_min_points do
      Logger.debug("PeriodicAnalyzer: USL skipped, only #{length(snapshots)} points (need #{@usl_min_points})")
      state
    else
      concurrency = Enum.map(snapshots, fn s -> (s.conn_active || 1) / 1.0 end)
      throughput = Enum.map(snapshots, fn s -> (s.tps || 0) / 1.0 end)

      case Anytune.usl(:pg2une, :fit, %{"concurrency" => concurrency, "throughput" => throughput}) do
        {:ok, fit_result} ->
          alpha = fit_result["alpha"] || 0
          beta = fit_result["beta"] || 0
          max_throughput = fit_result["max_throughput"] || 1

          # Get latest metrics to check deviation
          latest = List.last(snapshots)
          current_conn = (latest.conn_active || 1) / 1.0
          current_tps = (latest.tps || 0) / 1.0

          case Anytune.usl(:pg2une, :deviation, %{
            "alpha" => alpha,
            "beta" => beta,
            "max_throughput" => max_throughput,
            "predict_concurrency" => current_conn,
            "actual_throughput" => current_tps
          }) do
            {:ok, dev_result} ->
              deviation = dev_result["deviation"] || 0.0
              Logger.info("PeriodicAnalyzer: USL deviation=#{Float.round(deviation, 4)}")
              assert_usl_deviation(deviation)

              state = %{state |
                usl_params: %{alpha: alpha, beta: beta, max_throughput: max_throughput},
                last_usl_deviation: deviation
              }

              recalculate_confidence(state)
              state

            {:error, reason} ->
              Logger.warning("PeriodicAnalyzer: USL deviation check failed: #{inspect(reason)}")
              state
          end

        {:error, reason} ->
          Logger.warning("PeriodicAnalyzer: USL fit failed: #{inspect(reason)}")
          state
      end
    end
  end

  # ── Prophet Forecasting ──────────────────────────────────────────────

  defp run_prophet do
    snapshots = Pg2une.MetricsStore.recent_system_metrics(360)

    if length(snapshots) < @prophet_min_points do
      Logger.debug("PeriodicAnalyzer: Prophet skipped, only #{length(snapshots)} points (need #{@prophet_min_points})")
      :ok
    else
      Enum.each(@metrics_to_analyze, fn metric ->
        timestamps =
          Enum.map(snapshots, fn s ->
            DateTime.to_iso8601(s.snapshot_time)
          end)

        values = extract_metric_values(snapshots, metric)

        case Anytune.forecast(:pg2une, metric,
          timestamps: timestamps,
          values: values,
          periods: 24,
          freq: "H"
        ) do
          {:ok, result} ->
            forecasts = result["forecast"] || []

            if forecasts != [] do
              # Use the next-period forecast
              next = List.first(forecasts)
              yhat = next["yhat"] || 0
              lower = next["yhat_lower"] || 0
              upper = next["yhat_upper"] || 0

              Logger.info("PeriodicAnalyzer: Prophet forecast for #{metric}: yhat=#{yhat}")
              assert_prophet_forecast(metric, yhat, lower, upper)
            end

          {:error, reason} ->
            Logger.warning("PeriodicAnalyzer: Prophet failed for #{metric}: #{inspect(reason)}")
        end
      end)
    end
  end

  # ── Confidence Recalculation ─────────────────────────────────────────

  defp recalculate_confidence(state) do
    # Count CUSUM degradations from fact store
    cusum_facts = Anytune.query(:pg2une, {:cusum_degradation, [:_, :_]})
    cusum_count = length(cusum_facts)

    # Check if E-Divisive confirmed change points
    otava_confirms = map_size(state.last_change_points) > 0

    # USL deviation
    usl_dev = state.last_usl_deviation || 0.0

    # Check for seasonal unexpectedness
    seasonal_facts = Anytune.query(:pg2une, {:seasonal_expected, [:_, :_]})
    metric_values = Anytune.query(:pg2une, {:metric_value, [:_, :_]})

    seasonal_unexpected = check_seasonal_unexpected(metric_values, seasonal_facts)

    signals = %{
      cusum_degradation_count: cusum_count,
      usl_deviation: usl_dev,
      otava_confirms: otava_confirms,
      seasonal_unexpected: seasonal_unexpected
    }

    confidence = Anytune.Detection.Confidence.calculate(signals)

    Logger.info("PeriodicAnalyzer: confidence=#{Float.round(confidence, 3)} (cusum=#{cusum_count}, otava=#{otava_confirms}, usl_dev=#{Float.round(usl_dev, 4)}, seasonal=#{seasonal_unexpected})")

    if confidence >= 0.30 do
      Anytune.FactStore.replace_facts(:pg2une_store, :high_confidence, 0, [{:high_confidence, []}])
    else
      Anytune.FactStore.replace_facts(:pg2une_store, :high_confidence, 0, [])
    end
  end

  # ── Fact Store Helpers ───────────────────────────────────────────────

  defp assert_change_point(metric, magnitude) do
    Anytune.FactStore.assert_fact(:pg2une_store, {:otava_change_point, [metric, magnitude]})
  end

  defp retract_change_point(metric) do
    existing = Anytune.FactStore.query(:pg2une_store, {:otava_change_point, [metric, :_]})

    Enum.each(existing, fn fact ->
      Anytune.FactStore.retract_fact(:pg2une_store, fact)
    end)
  end

  defp assert_usl_deviation(deviation) do
    Anytune.FactStore.replace_facts(:pg2une_store, :usl_deviation, 1, [{:usl_deviation, [deviation]}])
  end

  defp assert_prophet_forecast(metric, yhat, lower, upper) do
    Anytune.FactStore.assert_fact(:pg2une_store, {:prophet_forecast, [metric, yhat, lower, upper]})
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp extract_metric_values(snapshots, "tps"), do: Enum.map(snapshots, &((&1.tps || 0) / 1.0))
  defp extract_metric_values(snapshots, "latency_p99"), do: Enum.map(snapshots, &((&1.latency_p99 || 0) / 1.0))
  defp extract_metric_values(snapshots, "buffer_hit_ratio"), do: Enum.map(snapshots, &((&1.buffer_hit_ratio || 0) / 1.0))
  defp extract_metric_values(snapshots, _), do: Enum.map(snapshots, fn _ -> 0.0 end)

  defp check_seasonal_unexpected(metric_values, seasonal_facts) do
    # Check if any current metric value is outside the seasonal expected range
    seasonal_map =
      Map.new(seasonal_facts, fn {:seasonal_expected, [metric, expected]} ->
        {metric, expected}
      end)

    Enum.any?(metric_values, fn {:metric_value, [metric, value]} ->
      case Map.get(seasonal_map, metric) do
        nil -> false
        expected ->
          deviation = abs(value - expected) / max(abs(expected), 0.001)
          deviation > 0.30
      end
    end)
  end

  defp schedule(task, interval) do
    Process.send_after(self(), task, interval)
  end
end
