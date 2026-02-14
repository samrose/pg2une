defmodule Pg2une.SchemasTest do
  use ExUnit.Case, async: true

  alias Pg2une.Schemas.{SystemSnapshot, WorkloadSnapshot, OptimizerObservation, OptimizationRun}

  describe "SystemSnapshot" do
    test "valid changeset" do
      changeset = SystemSnapshot.changeset(%SystemSnapshot{}, %{
        snapshot_time: DateTime.utc_now(),
        tps: 1200.0,
        buffer_hit_ratio: 0.99
      })

      assert changeset.valid?
    end

    test "requires snapshot_time" do
      changeset = SystemSnapshot.changeset(%SystemSnapshot{}, %{tps: 100.0})
      refute changeset.valid?
    end
  end

  describe "WorkloadSnapshot" do
    test "valid changeset" do
      changeset = WorkloadSnapshot.changeset(%WorkloadSnapshot{}, %{
        snapshot_time: DateTime.utc_now(),
        queryid: 12345,
        query: "SELECT 1",
        calls_delta: 100,
        mean_exec_time: 2.5
      })

      assert changeset.valid?
    end
  end

  describe "OptimizerObservation" do
    test "valid changeset" do
      changeset = OptimizerObservation.changeset(%OptimizerObservation{}, %{
        config: %{"shared_buffers_mb" => 1024},
        score: 0.85,
        score_type: "surrogate"
      })

      assert changeset.valid?
    end

    test "validates score_type" do
      changeset = OptimizerObservation.changeset(%OptimizerObservation{}, %{
        config: %{},
        score: 0.5,
        score_type: "invalid"
      })

      refute changeset.valid?
    end

    test "requires config, score, and score_type" do
      changeset = OptimizerObservation.changeset(%OptimizerObservation{}, %{})
      refute changeset.valid?
    end
  end

  describe "OptimizationRun" do
    test "valid changeset" do
      changeset = OptimizationRun.changeset(%OptimizationRun{}, %{
        action: "holistic",
        status: "running"
      })

      assert changeset.valid?
    end

    test "validates action values" do
      changeset = OptimizationRun.changeset(%OptimizationRun{}, %{
        action: "invalid",
        status: "running"
      })

      refute changeset.valid?
    end

    test "validates status values" do
      changeset = OptimizationRun.changeset(%OptimizationRun{}, %{
        action: "knobs",
        status: "invalid"
      })

      refute changeset.valid?
    end
  end
end
