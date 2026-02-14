defmodule Pg2une.QueryRegression do
  @moduledoc """
  Detects query performance regressions by comparing current per-query metrics
  against rolling baselines.

  Port of Python pg2une's query_regression.py logic.
  When a query's mean_exec_time increases >20% at similar call volume,
  it's flagged as a regression and asserted as a fact into datalox.
  """

  require Logger

  @regression_threshold 0.20
  @volume_similarity_threshold 0.50

  def analyze(query_metrics) when is_list(query_metrics) do
    baselines = Pg2une.MetricsStore.query_baselines()
    baseline_map = Map.new(baselines, fn b -> {b.queryid, b} end)

    regressions =
      Enum.flat_map(query_metrics, fn metric ->
        case Map.get(baseline_map, metric.queryid) do
          nil ->
            []

          baseline ->
            check_regression(metric, baseline)
        end
      end)

    assert_regressions(regressions)
    regressions
  end

  defp check_regression(metric, baseline) do
    avg_exec = baseline.avg_exec_time
    avg_calls = baseline.avg_calls

    if avg_exec == nil or avg_exec == 0 do
      []
    else
      exec_change = (metric.mean_exec_time - avg_exec) / avg_exec

      volume_change =
        if avg_calls > 0,
          do: abs(metric.calls_delta - avg_calls) / avg_calls,
          else: 1.0

      same_load = volume_change <= @volume_similarity_threshold

      if exec_change > @regression_threshold do
        load_type = if same_load, do: "same_load", else: "changed_load"

        [%{
          queryid: metric.queryid,
          load_type: load_type,
          regression_pct: Float.round(exec_change * 100, 1)
        }]
      else
        []
      end
    end
  end

  defp assert_regressions(regressions) do
    # Retract old query_regression facts and assert new ones
    facts =
      Enum.map(regressions, fn r ->
        {:query_regression, [r.queryid, r.load_type, r.regression_pct]}
      end)

    # Use anytune's fact store to manage these
    try do
      store = :pg2une_store
      Anytune.FactStore.replace_facts(store, :query_regression, 3, facts)
    rescue
      _ -> :ok
    end
  end
end
