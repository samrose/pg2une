defmodule Pgtune.Tunable do
  @moduledoc """
  Implements Anytune.Tunable for PostgreSQL.

  Defines PostgreSQL-specific metrics, parameter space (workload-aware),
  and scoring (delegates to Pgtune.Scorer).
  """

  @behaviour Anytune.Tunable

  @impl true
  def metric_definitions do
    [
      %Anytune.MetricDef{
        name: "tps",
        degradation_direction: :decrease,
        cusum_threshold: 4.0,
        cusum_drift: 0.5
      },
      %Anytune.MetricDef{
        name: "latency_p99",
        degradation_direction: :increase,
        cusum_threshold: 4.0,
        cusum_drift: 0.5
      },
      %Anytune.MetricDef{
        name: "buffer_hit_ratio",
        degradation_direction: :decrease,
        cusum_threshold: 3.0,
        cusum_drift: 0.3
      }
    ]
  end

  @impl true
  def parameter_space do
    workload = Pgtune.WorkloadDetector.current()
    knob_dimensions(workload) ++ index_dimensions() ++ hint_dimensions()
  end

  @impl true
  def score(config) do
    Pgtune.Scorer.score(config)
  end

  defp knob_dimensions(workload) do
    total_ram = Pgtune.Config.get(:total_ram_mb, 4096)

    case workload do
      :oltp ->
        [
          %Anytune.Dimension{name: "shared_buffers_mb", type: :integer,
            low: div(total_ram * 20, 100), high: div(total_ram * 30, 100)},
          %Anytune.Dimension{name: "effective_cache_size_mb", type: :integer,
            low: div(total_ram * 60, 100), high: div(total_ram * 75, 100)},
          %Anytune.Dimension{name: "work_mem_mb", type: :integer,
            low: 4, high: 64, prior: :log_uniform},
          %Anytune.Dimension{name: "maintenance_work_mem_mb", type: :integer,
            low: 64, high: 1024},
          %Anytune.Dimension{name: "random_page_cost", type: :float,
            low: 1.1, high: 2.0},
          %Anytune.Dimension{name: "max_connections", type: :integer,
            low: 100, high: 500}
        ]

      :olap ->
        [
          %Anytune.Dimension{name: "shared_buffers_mb", type: :integer,
            low: div(total_ram * 25, 100), high: div(total_ram * 40, 100)},
          %Anytune.Dimension{name: "effective_cache_size_mb", type: :integer,
            low: div(total_ram * 65, 100), high: div(total_ram * 80, 100)},
          %Anytune.Dimension{name: "work_mem_mb", type: :integer,
            low: 128, high: 512, prior: :log_uniform},
          %Anytune.Dimension{name: "maintenance_work_mem_mb", type: :integer,
            low: 256, high: 2048},
          %Anytune.Dimension{name: "random_page_cost", type: :float,
            low: 1.1, high: 4.0},
          %Anytune.Dimension{name: "max_connections", type: :integer,
            low: 50, high: 200}
        ]

      _mixed ->
        [
          %Anytune.Dimension{name: "shared_buffers_mb", type: :integer,
            low: div(total_ram * 22, 100), high: div(total_ram * 35, 100)},
          %Anytune.Dimension{name: "effective_cache_size_mb", type: :integer,
            low: div(total_ram * 60, 100), high: div(total_ram * 75, 100)},
          %Anytune.Dimension{name: "work_mem_mb", type: :integer,
            low: 32, high: 128, prior: :log_uniform},
          %Anytune.Dimension{name: "maintenance_work_mem_mb", type: :integer,
            low: 128, high: 1024},
          %Anytune.Dimension{name: "random_page_cost", type: :float,
            low: 1.1, high: 3.0},
          %Anytune.Dimension{name: "max_connections", type: :integer,
            low: 75, high: 300}
        ]
    end
  end

  defp index_dimensions do
    case Process.whereis(Pgtune.IndexAnalyzer) do
      nil -> []
      _pid -> Pgtune.IndexAnalyzer.dimensions()
    end
  end

  defp hint_dimensions do
    case Process.whereis(Pgtune.HintAnalyzer) do
      nil -> []
      _pid -> Pgtune.HintAnalyzer.dimensions()
    end
  end
end
