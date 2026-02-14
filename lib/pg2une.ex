defmodule Pg2une do
  @moduledoc "PostgreSQL auto-tuner on mxc microVMs."

  def start(opts \\ []) do
    target_url = Keyword.get(opts, :target)
    mxc_coordinator = Keyword.get(opts, :mxc_coordinator, "http://localhost:4000")

    if target_url, do: Pg2une.Config.put(:target_url, target_url)
    Pg2une.Config.put(:mxc_coordinator, mxc_coordinator)

    # TODO: Set up anytune subscription when Anytune.subscribe/3 is implemented
    # Anytune.subscribe(:pg2une, {:should_act, [:_]}, fn {:should_act, [action]} ->
    #   action_atom = if is_binary(action), do: String.to_existing_atom(action), else: action
    #   Pg2une.DeploymentManager.start_optimization(action_atom)
    # end)

    :ok
  end

  def optimize(action \\ :holistic) do
    Pg2une.DeploymentManager.start_optimization(action)
  end

  def status do
    Pg2une.DeploymentManager.status()
  end

  def metrics do
    Pg2une.MetricsPoller.latest_metrics()
  end

  def workload_type do
    Pg2une.WorkloadDetector.current()
  end

  def query(pattern) do
    Anytune.query(:pg2une, pattern)
  end

  def optimization_history(opts \\ []) do
    Pg2une.MetricsStore.optimization_history(opts)
  end

  def ensure_infrastructure do
    Pg2une.DeploymentManager.ensure_infrastructure()
  end

  def teardown do
    Pg2une.DeploymentManager.teardown()
  end

  def ingest(metrics) when is_map(metrics) do
    Anytune.ingest(:pg2une, metrics)
  end
end
