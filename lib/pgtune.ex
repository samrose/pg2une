defmodule Pgtune do
  @moduledoc "PostgreSQL auto-tuner on mxc microVMs."

  def start(opts \\ []) do
    target_url = Keyword.get(opts, :target)
    mxc_coordinator = Keyword.get(opts, :mxc_coordinator, "http://localhost:4000")

    if target_url, do: Pgtune.Config.put(:target_url, target_url)
    Pgtune.Config.put(:mxc_coordinator, mxc_coordinator)

    # TODO: Set up anytune subscription when Anytune.subscribe/3 is implemented
    # Anytune.subscribe(:pgtune, {:should_act, [:_]}, fn {:should_act, [action]} ->
    #   action_atom = if is_binary(action), do: String.to_existing_atom(action), else: action
    #   Pgtune.DeploymentManager.start_optimization(action_atom)
    # end)

    :ok
  end

  def optimize(action \\ :holistic) do
    Pgtune.DeploymentManager.start_optimization(action)
  end

  def status do
    Pgtune.DeploymentManager.status()
  end

  def metrics do
    Pgtune.MetricsPoller.latest_metrics()
  end

  def workload_type do
    Pgtune.WorkloadDetector.current()
  end

  def query(pattern) do
    Anytune.query(:pgtune, pattern)
  end

  def optimization_history(opts \\ []) do
    Pgtune.MetricsStore.optimization_history(opts)
  end

  def ensure_infrastructure do
    Pgtune.DeploymentManager.ensure_infrastructure()
  end

  def teardown do
    Pgtune.DeploymentManager.teardown()
  end

  def ingest(metrics) when is_map(metrics) do
    Anytune.ingest(:pgtune, metrics)
  end
end
