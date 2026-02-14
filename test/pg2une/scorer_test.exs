defmodule Pg2une.ScorerTest do
  use ExUnit.Case

  alias Pg2une.Scorer

  # Scorer depends on Pg2une.Config and Pg2une.WorkloadDetector being running.
  # We start them per-test with unique names, but Scorer calls the module-registered ones.
  # So we need to start them with the default names.

  setup do
    # Start Config if not running
    unless Process.whereis(Pg2une.Config) do
      {:ok, _} = Pg2une.Config.start_link(total_ram_mb: 4096)
    end

    unless Process.whereis(Pg2une.WorkloadDetector) do
      {:ok, _} = Pg2une.WorkloadDetector.start_link()
    end

    :ok
  end

  test "reasonable OLTP config scores well" do
    # Set workload to mixed (default)
    config = %{
      "shared_buffers_mb" => 1024,
      "effective_cache_size_mb" => 3072,
      "work_mem_mb" => 32,
      "maintenance_work_mem_mb" => 256,
      "random_page_cost" => 1.1,
      "max_connections" => 200
    }

    score = Scorer.score(config)
    assert score > 0.5
    assert score <= 1.0
  end

  test "config exceeding RAM scores poorly" do
    config = %{
      "shared_buffers_mb" => 3000,
      "effective_cache_size_mb" => 3072,
      "work_mem_mb" => 256,
      "maintenance_work_mem_mb" => 1024,
      "random_page_cost" => 1.1,
      "max_connections" => 500
    }

    score = Scorer.score(config)
    assert score < 0.5
  end

  test "shared_buffers > effective_cache_size is penalized" do
    config = %{
      "shared_buffers_mb" => 2048,
      "effective_cache_size_mb" => 1024,
      "work_mem_mb" => 32,
      "maintenance_work_mem_mb" => 256,
      "random_page_cost" => 1.1,
      "max_connections" => 100
    }

    score = Scorer.score(config)
    # Should be penalized for imbalance
    balanced = Scorer.score(%{config | "effective_cache_size_mb" => 3072})
    assert score < balanced
  end

  test "score is always between 0.0 and 1.0" do
    configs = [
      %{"shared_buffers_mb" => 0, "work_mem_mb" => 0, "max_connections" => 0},
      %{"shared_buffers_mb" => 10000, "work_mem_mb" => 10000, "max_connections" => 10000},
      %{"shared_buffers_mb" => 1024, "effective_cache_size_mb" => 3072,
        "work_mem_mb" => 64, "random_page_cost" => 1.1, "max_connections" => 100}
    ]

    for config <- configs do
      score = Scorer.score(config)
      assert score >= 0.0, "Score #{score} < 0.0 for config #{inspect(config)}"
      assert score <= 1.0, "Score #{score} > 1.0 for config #{inspect(config)}"
    end
  end

  test "low random_page_cost is rewarded" do
    base = %{
      "shared_buffers_mb" => 1024,
      "effective_cache_size_mb" => 3072,
      "work_mem_mb" => 32,
      "max_connections" => 100
    }

    ssd = Scorer.score(Map.put(base, "random_page_cost", 1.1))
    hdd = Scorer.score(Map.put(base, "random_page_cost", 4.0))

    assert ssd > hdd
  end
end
