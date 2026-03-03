defmodule Pg2une.MetricsStoreTest do
  use ExUnit.Case

  import Ecto.Query
  alias Pg2une.MetricsStore
  alias Pg2une.Schemas.{SystemSnapshot, SystemSnapshotHourly}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Pg2une.Repo)
    :ok
  end

  describe "system snapshots" do
    test "records and retrieves system snapshots" do
      metrics = %{
        tps: 1200.0,
        conn_active: 15,
        conn_idle: 30,
        buffer_hit_ratio: 0.994,
        temp_bytes: 0,
        latency_p50: 2.1,
        latency_p95: 8.4,
        latency_p99: 12.5
      }

      {:ok, snapshot} = MetricsStore.record_system_snapshot(metrics)
      assert snapshot.tps == 1200.0
      assert snapshot.buffer_hit_ratio == 0.994
      assert snapshot.snapshot_time != nil
    end

    test "recent_system_metrics returns snapshots within time window" do
      # Insert a snapshot
      MetricsStore.record_system_snapshot(%{
        tps: 1000.0, latency_p99: 10.0, buffer_hit_ratio: 0.99
      })

      results = MetricsStore.recent_system_metrics(5)
      assert length(results) == 1
      assert hd(results).tps == 1000.0
    end

    test "recent_system_metrics returns empty for old data" do
      # Insert with a past timestamp
      Pg2une.Repo.insert!(%SystemSnapshot{
        snapshot_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        tps: 500.0
      })

      results = MetricsStore.recent_system_metrics(1)
      assert results == []
    end
  end

  describe "archive_old_snapshots" do
    test "returns ok when nothing to archive" do
      assert :ok == MetricsStore.archive_old_snapshots()
    end

    test "does not archive data within 30 days" do
      MetricsStore.record_system_snapshot(%{tps: 1000.0, latency_p99: 10.0, conn_active: 5})

      :ok = MetricsStore.archive_old_snapshots()

      assert length(MetricsStore.recent_system_metrics(5)) == 1
      assert Pg2une.Repo.all(SystemSnapshotHourly) == []
    end

    test "archives minute-level data older than 30 days and deletes originals" do
      old_time = DateTime.add(DateTime.utc_now(), -(31 * 24 * 60 * 60), :second)

      for i <- 0..3 do
        Pg2une.Repo.insert!(%SystemSnapshot{
          snapshot_time: DateTime.add(old_time, i * 60, :second),
          tps: 1000.0 + i * 10,
          latency_p99: 10.0,
          buffer_hit_ratio: 0.99,
          conn_active: 10
        })
      end

      :ok = MetricsStore.archive_old_snapshots()

      archived = Pg2une.Repo.all(SystemSnapshotHourly)
      assert length(archived) == 1
      assert hd(archived).sample_count == 4

      cutoff = DateTime.add(DateTime.utc_now(), -(30 * 24 * 60 * 60), :second)
      remaining = from(s in SystemSnapshot, where: s.snapshot_time < ^cutoff) |> Pg2une.Repo.all()
      assert remaining == []
    end

    test "aggregates tps avg and max correctly" do
      old_time = DateTime.add(DateTime.utc_now(), -(31 * 24 * 60 * 60), :second)

      Pg2une.Repo.insert!(%SystemSnapshot{
        snapshot_time: old_time,
        tps: 800.0, latency_p99: 10.0, conn_active: 10
      })
      Pg2une.Repo.insert!(%SystemSnapshot{
        snapshot_time: DateTime.add(old_time, 60, :second),
        tps: 1200.0, latency_p99: 20.0, conn_active: 10
      })

      :ok = MetricsStore.archive_old_snapshots()

      [archived] = Pg2une.Repo.all(SystemSnapshotHourly)
      assert_in_delta archived.tps_avg, 1000.0, 0.01
      assert_in_delta archived.tps_max, 1200.0, 0.01
      assert_in_delta archived.latency_p99_max, 20.0, 0.01
    end

    test "preserves recent data while archiving old data" do
      old_time = DateTime.add(DateTime.utc_now(), -(31 * 24 * 60 * 60), :second)

      Pg2une.Repo.insert!(%SystemSnapshot{
        snapshot_time: old_time, tps: 500.0, conn_active: 5
      })
      MetricsStore.record_system_snapshot(%{tps: 1000.0, conn_active: 10})

      :ok = MetricsStore.archive_old_snapshots()

      assert length(Pg2une.Repo.all(SystemSnapshotHourly)) == 1
      assert length(MetricsStore.recent_system_metrics(5)) == 1
    end
  end

  describe "optimizer observations" do
    test "records observations" do
      {:ok, obs} = MetricsStore.record_observation(%{
        workload_type: "oltp",
        config: %{"shared_buffers_mb" => 1024},
        score: 0.85,
        score_type: "surrogate",
        improvement_pct: 12.5
      })

      assert obs.score == 0.85
      assert obs.config["shared_buffers_mb"] == 1024
    end

    test "prior_observations retrieves recent observations" do
      MetricsStore.record_observation(%{
        workload_type: "oltp",
        config: %{"shared_buffers_mb" => 1024},
        score: 0.85,
        score_type: "surrogate"
      })

      MetricsStore.record_observation(%{
        workload_type: "olap",
        config: %{"shared_buffers_mb" => 2048},
        score: 0.72,
        score_type: "live_test"
      })

      all = MetricsStore.prior_observations()
      assert length(all) == 2

      oltp_only = MetricsStore.prior_observations(workload_type: :oltp)
      assert length(oltp_only) == 1
      assert hd(oltp_only).workload_type == "oltp"
    end
  end

  describe "optimization runs" do
    test "creates and updates optimization runs" do
      {:ok, run} = MetricsStore.create_optimization_run(%{
        action: "holistic",
        status: "running",
        config: %{"shared_buffers_mb" => 1024}
      })

      assert run.status == "running"

      {:ok, updated} = MetricsStore.update_optimization_run(run, %{
        status: "promoted",
        improvement_pct: 15.2
      })

      assert updated.status == "promoted"
      assert updated.improvement_pct == 15.2
    end

    test "optimization_history returns recent runs" do
      MetricsStore.create_optimization_run(%{
        action: "knobs", status: "promoted"
      })

      MetricsStore.create_optimization_run(%{
        action: "holistic", status: "rolled_back"
      })

      history = MetricsStore.optimization_history(limit: 10)
      assert length(history) == 2
    end
  end
end
