defmodule Pg2une.Application do
  use Application

  @impl true
  def start(_type, _args) do
    rules_path = Path.join(:code.priv_dir(:pg2une), "rules/pg2une.dl")

    children = [
      Pg2une.Repo,
      {Pg2une.Config, default_config()},
      Pg2une.WorkloadDetector,
      {Anytune,
        name: :pg2une,
        tunable: Pg2une.Tunable,
        rules: [rules_path],
        python_pool: [size: 2]},
      Pg2une.MetricsPoller,
      Pg2une.IndexAnalyzer,
      Pg2une.HintAnalyzer,
      Pg2une.DeploymentManager,
      {Plug.Cowboy,
        scheme: :http,
        plug: Pg2une.Router,
        options: [port: port()]}
    ]

    opts = [strategy: :one_for_one, name: Pg2une.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp default_config do
    [
      target_url: Application.get_env(:pg2une, :target_url),
      mxc_coordinator: Application.get_env(:pg2une, :mxc_coordinator, "http://localhost:4000"),
      poll_interval: Application.get_env(:pg2une, :poll_interval, 60_000),
      total_ram_mb: Application.get_env(:pg2une, :total_ram_mb, 4096)
    ]
  end

  defp port do
    Application.get_env(:pg2une, :port, 8080)
  end
end
