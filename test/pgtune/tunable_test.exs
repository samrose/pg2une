defmodule Pgtune.TunableTest do
  use ExUnit.Case

  alias Pgtune.Tunable

  setup do
    unless Process.whereis(Pgtune.Config) do
      {:ok, _} = Pgtune.Config.start_link(total_ram_mb: 4096)
    end

    unless Process.whereis(Pgtune.WorkloadDetector) do
      {:ok, _} = Pgtune.WorkloadDetector.start_link()
    end

    :ok
  end

  test "metric_definitions returns valid MetricDef structs" do
    defs = Tunable.metric_definitions()

    assert length(defs) == 3

    names = Enum.map(defs, & &1.name)
    assert "tps" in names
    assert "latency_p99" in names
    assert "buffer_hit_ratio" in names

    for def <- defs do
      assert %Anytune.MetricDef{} = def
      assert def.cusum_threshold > 0
      assert def.cusum_drift > 0
      assert def.degradation_direction in [:increase, :decrease]
    end
  end

  test "parameter_space returns dimensions with valid ranges" do
    space = Tunable.parameter_space()

    # At minimum should have knob dimensions
    assert length(space) >= 6

    names = Enum.map(space, & &1.name)
    assert "shared_buffers_mb" in names
    assert "effective_cache_size_mb" in names
    assert "work_mem_mb" in names
    assert "maintenance_work_mem_mb" in names
    assert "random_page_cost" in names
    assert "max_connections" in names

    for dim <- space do
      assert %Anytune.Dimension{} = dim

      if dim.type in [:integer, :float] do
        assert dim.low != nil
        assert dim.high != nil
        assert dim.low < dim.high, "#{dim.name}: low (#{dim.low}) >= high (#{dim.high})"
      end
    end
  end

  test "parameter ranges are workload-aware" do
    # Default is :mixed
    mixed_space = Tunable.parameter_space()
    mixed_work_mem = Enum.find(mixed_space, &(&1.name == "work_mem_mb"))

    # Switch to OLAP
    Pgtune.WorkloadDetector.update(%{
      "tps" => 10.0, "conn_active" => 5,
      "latency_p99" => 500.0, "temp_bytes" => 500_000_000
    })
    Process.sleep(10)

    olap_space = Tunable.parameter_space()
    olap_work_mem = Enum.find(olap_space, &(&1.name == "work_mem_mb"))

    # OLAP should have higher work_mem range
    assert olap_work_mem.high > mixed_work_mem.high

    # Reset to mixed
    Pgtune.WorkloadDetector.update(%{
      "tps" => 50.0, "conn_active" => 20,
      "latency_p99" => 50.0, "temp_bytes" => 50_000_000
    })
  end

  test "score delegates to Scorer and returns a float" do
    config = %{
      "shared_buffers_mb" => 1024,
      "effective_cache_size_mb" => 3072,
      "work_mem_mb" => 32,
      "random_page_cost" => 1.1,
      "max_connections" => 200
    }

    score = Tunable.score(config)
    assert is_float(score) or is_integer(score)
    assert score >= 0.0
    assert score <= 1.0
  end
end
