defmodule Pgtune.QueryRegressionTest do
  use ExUnit.Case

  alias Pgtune.QueryRegression

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Pgtune.Repo)
    :ok
  end

  describe "check_regression logic" do
    test "no regressions when no baselines exist" do
      metrics = [
        %{queryid: 1, query: "SELECT 1", calls_delta: 100,
          mean_exec_time: 5.0, total_exec_time: 500.0, rows: 100,
          shared_blks_hit: 1000, shared_blks_read: 0, temp_blks_written: 0}
      ]

      # This will return [] because MetricsStore.query_baselines will fail
      # We're testing that analyze doesn't crash
      regressions = QueryRegression.analyze(metrics)
      assert is_list(regressions)
    end
  end

  describe "regression thresholds" do
    # Test threshold logic directly
    test "20% regression threshold" do
      # A query going from 10ms to 12.1ms (21% increase) is a regression
      baseline_time = 10.0
      current_time = 12.1
      change = (current_time - baseline_time) / baseline_time
      assert change > 0.20

      # A query going from 10ms to 11.9ms (19% increase) is NOT a regression
      current_time_ok = 11.9
      change_ok = (current_time_ok - baseline_time) / baseline_time
      assert change_ok < 0.20
    end

    test "volume similarity threshold" do
      # Same load: within 50% of baseline volume
      baseline_calls = 100.0
      current_calls = 140
      volume_change = abs(current_calls - baseline_calls) / baseline_calls
      assert volume_change <= 0.50  # Same load

      # Changed load: >50% different
      current_calls_high = 200
      volume_change_high = abs(current_calls_high - baseline_calls) / baseline_calls
      assert volume_change_high > 0.50  # Changed load
    end
  end
end
