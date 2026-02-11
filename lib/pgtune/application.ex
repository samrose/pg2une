defmodule Pgtune.Application do
  use Application

  @impl true
  def start(_type, _args) do
    rules_path = Path.join(:code.priv_dir(:pgtune), "rules/pgtune.dl")

    children = [
      Pgtune.Repo,
      {Pgtune.Config, default_config()},
      Pgtune.WorkloadDetector,
      {Anytune,
        name: :pgtune,
        tunable: Pgtune.Tunable,
        rules: [rules_path],
        python_pool: [size: 2]},
      Pgtune.MetricsPoller,
      Pgtune.IndexAnalyzer,
      Pgtune.HintAnalyzer,
      Pgtune.DeploymentManager,
      {Plug.Cowboy,
        scheme: :http,
        plug: Pgtune.Router,
        options: [port: port()]}
    ]

    opts = [strategy: :one_for_one, name: Pgtune.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp default_config do
    [
      target_url: Application.get_env(:pgtune, :target_url),
      mxc_coordinator: Application.get_env(:pgtune, :mxc_coordinator, "http://localhost:4000"),
      poll_interval: Application.get_env(:pgtune, :poll_interval, 60_000),
      total_ram_mb: Application.get_env(:pgtune, :total_ram_mb, 4096)
    ]
  end

  defp port do
    Application.get_env(:pgtune, :port, 8080)
  end
end
