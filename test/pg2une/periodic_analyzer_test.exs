defmodule Pg2une.PeriodicAnalyzerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pg2une.PeriodicAnalyzer
  alias Pg2une.MetricsBucketer

  setup :verify_on_exit!

  # ── MetricsBucketer.bucket_to_15min/1 ──────────────────────────────

  describe "MetricsBucketer.bucket_to_15min/1" do
    test "returns empty list for empty input" do
      assert MetricsBucketer.bucket_to_15min([]) == []
    end

    test "keeps a single snapshot in its own bucket" do
      t = ~U[2024-01-01 10:00:00Z]
      snap = %{snapshot_time: t, tps: 100.0, latency_p99: 10.0, buffer_hit_ratio: 0.95, conn_active: 5}

      [bucket] = MetricsBucketer.bucket_to_15min([snap])

      assert_in_delta bucket.tps, 100.0, 0.001
      assert bucket.conn_active == 5
    end

    test "averages snapshots within the same 15-min window" do
      t1 = ~U[2024-01-01 10:01:00Z]
      t2 = ~U[2024-01-01 10:08:00Z]

      snaps = [
        %{snapshot_time: t1, tps: 100.0, latency_p99: 10.0, buffer_hit_ratio: 0.90, conn_active: 4},
        %{snapshot_time: t2, tps: 200.0, latency_p99: 20.0, buffer_hit_ratio: 0.80, conn_active: 6}
      ]

      [bucket] = MetricsBucketer.bucket_to_15min(snaps)

      assert_in_delta bucket.tps, 150.0, 0.001
      assert_in_delta bucket.latency_p99, 15.0, 0.001
      assert_in_delta bucket.buffer_hit_ratio, 0.85, 0.001
      assert bucket.conn_active == 5
    end

    test "puts snapshots from different 15-min windows into separate buckets" do
      t1 = ~U[2024-01-01 10:01:00Z]
      t2 = ~U[2024-01-01 10:16:00Z]

      snaps = [
        %{snapshot_time: t1, tps: 100.0, latency_p99: 10.0, buffer_hit_ratio: 0.95, conn_active: 5},
        %{snapshot_time: t2, tps: 200.0, latency_p99: 20.0, buffer_hit_ratio: 0.90, conn_active: 10}
      ]

      assert length(MetricsBucketer.bucket_to_15min(snaps)) == 2
    end

    test "output is sorted ascending by snapshot_time" do
      t1 = ~U[2024-01-01 10:16:00Z]
      t2 = ~U[2024-01-01 10:01:00Z]

      snaps = [
        %{snapshot_time: t1, tps: 200.0, latency_p99: 20.0, buffer_hit_ratio: 0.90, conn_active: 10},
        %{snapshot_time: t2, tps: 100.0, latency_p99: 10.0, buffer_hit_ratio: 0.95, conn_active: 5}
      ]

      [first, second] = MetricsBucketer.bucket_to_15min(snaps)
      assert DateTime.compare(first.snapshot_time, second.snapshot_time) == :lt
    end

    test "treats nil metric fields as zero when averaging" do
      t = ~U[2024-01-01 10:00:00Z]
      snap = %{snapshot_time: t, tps: nil, latency_p99: nil, buffer_hit_ratio: nil, conn_active: nil}

      [bucket] = MetricsBucketer.bucket_to_15min([snap])

      assert bucket.tps == 0.0
      assert bucket.conn_active == 0
    end
  end

  # ── run_edivisive/1 ──────────────────────────────────────────────────

  describe "run_edivisive/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Pg2une.Repo)
      :ok
    end

    test "skips and returns unchanged state when fewer than 20 snapshots available" do
      # Empty DB — no mock expectations set, any call would fail the test
      state = initial_state()
      assert PeriodicAnalyzer.run_edivisive(state) == state
    end

    test "asserts change point fact when significant changes detected" do
      insert_system_snapshots(25)

      # Background stubs for recalculate_confidence and retract_change_point
      stub(Pg2une.MockAnytuneClient, :query, fn _name, _pattern -> [] end)
      stub(Pg2une.MockFactStoreClient, :replace_facts, fn _store, _pred, _arity, _facts -> :ok end)
      stub(Pg2une.MockFactStoreClient, :query, fn _store, _pattern -> [] end)

      # tps has a significant change point; latency_p99 and buffer_hit_ratio do not
      expect(Pg2une.MockAnytuneClient, :edivisive, fn :pg2une, "tps", _values ->
        {:ok, %{"change_points" => [%{"magnitude" => 0.35}]}}
      end)
      expect(Pg2une.MockAnytuneClient, :edivisive, fn :pg2une, "latency_p99", _values ->
        {:ok, %{"change_points" => []}}
      end)
      expect(Pg2une.MockAnytuneClient, :edivisive, fn :pg2une, "buffer_hit_ratio", _values ->
        {:ok, %{"change_points" => []}}
      end)
      expect(Pg2une.MockFactStoreClient, :assert_fact, fn :pg2une_store,
                                                          {:otava_change_point, ["tps", 0.35]} ->
        :ok
      end)

      state = initial_state()
      new_state = PeriodicAnalyzer.run_edivisive(state)

      assert new_state.last_change_points == %{"tps" => 0.35}
    end

    test "retracts stale facts when no significant changes detected" do
      insert_system_snapshots(25)

      stub(Pg2une.MockAnytuneClient, :query, fn _name, _pattern -> [] end)
      stub(Pg2une.MockFactStoreClient, :replace_facts, fn _store, _pred, _arity, _facts -> :ok end)
      stub(Pg2une.MockFactStoreClient, :query, fn _store, _pattern -> [] end)

      expect(Pg2une.MockAnytuneClient, :edivisive, 3, fn :pg2une, _metric, _values ->
        {:ok, %{"change_points" => []}}
      end)

      state = initial_state()
      new_state = PeriodicAnalyzer.run_edivisive(state)

      assert new_state.last_change_points == %{}
    end

    test "tolerates edivisive errors and continues with other metrics" do
      insert_system_snapshots(25)

      stub(Pg2une.MockAnytuneClient, :query, fn _name, _pattern -> [] end)
      stub(Pg2une.MockFactStoreClient, :replace_facts, fn _store, _pred, _arity, _facts -> :ok end)
      stub(Pg2une.MockFactStoreClient, :query, fn _store, _pattern -> [] end)

      expect(Pg2une.MockAnytuneClient, :edivisive, fn :pg2une, "tps", _values ->
        {:error, :timeout}
      end)
      expect(Pg2une.MockAnytuneClient, :edivisive, fn :pg2une, "latency_p99", _values ->
        {:ok, %{"change_points" => []}}
      end)
      expect(Pg2une.MockAnytuneClient, :edivisive, fn :pg2une, "buffer_hit_ratio", _values ->
        {:ok, %{"change_points" => []}}
      end)

      state = initial_state()
      # Should not raise
      assert %{last_change_points: %{}} = PeriodicAnalyzer.run_edivisive(state)
    end
  end

  # ── run_usl/1 ────────────────────────────────────────────────────────

  describe "run_usl/1" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Pg2une.Repo)
      :ok
    end

    test "skips and returns unchanged state when fewer than 5 snapshots available" do
      state = initial_state()
      assert PeriodicAnalyzer.run_usl(state) == state
    end

    test "updates usl_params and last_usl_deviation on success" do
      insert_system_snapshots(10)

      stub(Pg2une.MockAnytuneClient, :query, fn _name, _pattern -> [] end)
      stub(Pg2une.MockFactStoreClient, :replace_facts, fn _store, _pred, _arity, _facts -> :ok end)

      expect(Pg2une.MockAnytuneClient, :usl, fn :pg2une, :fit, _params ->
        {:ok, %{"alpha" => 0.05, "beta" => 0.002, "max_throughput" => 1000.0}}
      end)
      expect(Pg2une.MockAnytuneClient, :usl, fn :pg2une, :deviation, params ->
        assert params["alpha"] == 0.05
        assert params["beta"] == 0.002
        {:ok, %{"deviation" => -0.12}}
      end)
      expect(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store, :usl_deviation, 1,
                                                            [{:usl_deviation, [-0.12]}] ->
        :ok
      end)

      state = initial_state()
      new_state = PeriodicAnalyzer.run_usl(state)

      assert new_state.usl_params == %{alpha: 0.05, beta: 0.002, max_throughput: 1000.0}
      assert_in_delta new_state.last_usl_deviation, -0.12, 0.001
    end

    test "returns unchanged state when usl fit fails" do
      insert_system_snapshots(10)

      expect(Pg2une.MockAnytuneClient, :usl, fn :pg2une, :fit, _params ->
        {:error, :python_error}
      end)

      state = initial_state()
      assert PeriodicAnalyzer.run_usl(state) == state
    end
  end

  # ── Confidence calculation (kept from original) ──────────────────────

  describe "confidence calculation" do
    test "with no signals returns low score" do
      signals = %{cusum_degradation_count: 0, usl_deviation: 0.0, otava_confirms: false, seasonal_unexpected: false}
      score = Anytune.Detection.Confidence.calculate(signals)
      assert score < 0.30
    end

    test "with cusum degradations meets threshold" do
      signals = %{cusum_degradation_count: 2, usl_deviation: 0.0, otava_confirms: false, seasonal_unexpected: false}
      score = Anytune.Detection.Confidence.calculate(signals)
      # 2 * 0.15 = 0.30
      assert score >= 0.30
    end

    test "with multiple signals returns high score" do
      signals = %{cusum_degradation_count: 1, usl_deviation: -0.20, otava_confirms: true, seasonal_unexpected: true}
      score = Anytune.Detection.Confidence.calculate(signals)
      # 0.15 + 0.15 + 0.15 + 0.10 = 0.55
      assert score >= 0.50
    end

    test "caps at 1.0" do
      signals = %{cusum_degradation_count: 10, usl_deviation: -0.50, otava_confirms: true, seasonal_unexpected: true}
      score = Anytune.Detection.Confidence.calculate(signals)
      assert score <= 1.0
    end

    test "usl_deviation above threshold does not contribute" do
      signals = %{cusum_degradation_count: 0, usl_deviation: 0.10, otava_confirms: false, seasonal_unexpected: false}
      score = Anytune.Detection.Confidence.calculate(signals)
      assert score == 0.0
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp initial_state do
    %{usl_params: nil, last_change_points: %{}, last_usl_deviation: nil}
  end

  defp insert_system_snapshots(count) do
    base = DateTime.utc_now() |> DateTime.add(-(count * 60), :second)

    for i <- 0..(count - 1) do
      ts = DateTime.add(base, i * 60, :second)

      %Pg2une.Schemas.SystemSnapshot{}
      |> Pg2une.Schemas.SystemSnapshot.changeset(%{
        "snapshot_time" => ts,
        "tps" => 800.0 + i * 5.0,
        "latency_p99" => 10.0 + i * 0.1,
        "buffer_hit_ratio" => 0.95,
        "conn_active" => 10 + rem(i, 5)
      })
      |> Pg2une.Repo.insert!()
    end
  end
end
