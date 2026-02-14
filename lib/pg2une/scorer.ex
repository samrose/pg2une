defmodule Pg2une.Scorer do
  @moduledoc """
  Scores PostgreSQL configurations using surrogate heuristics.

  Port of Python pg2une's scorer.py. Validates RAM constraints,
  penalizes known-bad combinations, rewards workload-appropriate configs.

  Returns a composite score 0.0-1.0 (higher is better).
  """

  def score(config) when is_map(config) do
    total_ram = Pg2une.Config.get(:total_ram_mb, 4096)
    workload = Pg2une.WorkloadDetector.current()

    penalties = [
      ram_penalty(config, total_ram),
      workload_penalty(config, workload),
      balance_penalty(config, total_ram)
    ]

    total_penalty = Enum.sum(penalties)
    base_score = workload_fit_score(config, workload)

    max(0.0, min(1.0, base_score - total_penalty))
  end

  # Penalize configs that exceed available RAM
  defp ram_penalty(config, total_ram) do
    shared_buffers = Map.get(config, "shared_buffers_mb", 0)
    work_mem = Map.get(config, "work_mem_mb", 0)
    max_connections = Map.get(config, "max_connections", 100)
    maintenance_work_mem = Map.get(config, "maintenance_work_mem_mb", 0)

    # Estimate total memory usage
    estimated_usage = shared_buffers + (work_mem * max_connections * 0.3) + maintenance_work_mem

    if estimated_usage > total_ram * 0.85 do
      overshoot = (estimated_usage - total_ram * 0.85) / total_ram
      min(0.5, overshoot)
    else
      0.0
    end
  end

  # Penalize configs that don't fit the workload
  defp workload_penalty(config, workload) do
    work_mem = Map.get(config, "work_mem_mb", 32)

    case workload do
      :oltp ->
        # OLTP shouldn't use too much work_mem
        if work_mem > 128, do: 0.15, else: 0.0

      :olap ->
        # OLAP needs more work_mem
        if work_mem < 64, do: 0.15, else: 0.0

      _mixed ->
        0.0
    end
  end

  # Penalize unbalanced shared_buffers vs effective_cache_size
  defp balance_penalty(config, total_ram) do
    shared_buffers = Map.get(config, "shared_buffers_mb", 0)
    effective_cache = Map.get(config, "effective_cache_size_mb", 0)

    cond do
      effective_cache > 0 and shared_buffers > effective_cache ->
        0.2

      effective_cache > 0 and effective_cache > total_ram * 0.9 ->
        0.1

      true ->
        0.0
    end
  end

  # Base score from how well config fits the workload
  defp workload_fit_score(config, workload) do
    total_ram = Pg2une.Config.get(:total_ram_mb, 4096)
    shared_buffers = Map.get(config, "shared_buffers_mb", 0)
    shared_pct = shared_buffers / total_ram

    random_page_cost = Map.get(config, "random_page_cost", 4.0)

    score = 0.5

    # Reward reasonable shared_buffers percentage
    score = score + cond do
      shared_pct >= 0.20 and shared_pct <= 0.35 -> 0.2
      shared_pct >= 0.15 and shared_pct <= 0.40 -> 0.1
      true -> 0.0
    end

    # Reward low random_page_cost (SSD assumption)
    score = if random_page_cost <= 1.5, do: score + 0.1, else: score

    # Workload-specific bonuses
    score = case workload do
      :oltp ->
        work_mem = Map.get(config, "work_mem_mb", 32)
        max_conn = Map.get(config, "max_connections", 100)
        bonus = if work_mem <= 64 and max_conn >= 100, do: 0.15, else: 0.0
        score + bonus

      :olap ->
        work_mem = Map.get(config, "work_mem_mb", 32)
        bonus = if work_mem >= 128, do: 0.15, else: 0.0
        score + bonus

      _mixed ->
        score + 0.05
    end

    min(1.0, score)
  end
end
