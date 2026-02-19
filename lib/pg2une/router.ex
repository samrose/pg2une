defmodule Pg2une.Router do
  @moduledoc """
  Plug router providing REST API for pg2une.
  """

  use Plug.Router

  plug Plug.Logger
  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  # Health check
  get "/" do
    send_json(conn, 200, %{status: "ok", app: "pg2une"})
  end

  # Current state + workload type
  get "/api/status" do
    status = Pg2une.DeploymentManager.status()
    workload = Pg2une.WorkloadDetector.current()

    send_json(conn, 200, %{
      status: format_status(status),
      workload_type: workload
    })
  end

  # Latest metrics snapshot
  get "/api/metrics" do
    metrics = Pg2une.MetricsPoller.latest_metrics()
    send_json(conn, 200, %{metrics: metrics})
  end

  # Metrics history
  get "/api/metrics/history" do
    minutes = get_query_param(conn, "minutes", "60") |> String.to_integer()
    snapshots = Pg2une.MetricsStore.recent_system_metrics(minutes)

    data = Enum.map(snapshots, fn s ->
      %{
        snapshot_time: s.snapshot_time,
        tps: s.tps,
        latency_p99: s.latency_p99,
        buffer_hit_ratio: s.buffer_hit_ratio,
        conn_active: s.conn_active
      }
    end)

    send_json(conn, 200, %{snapshots: data})
  end

  # Current PostgreSQL config on target
  get "/api/config" do
    params = Map.keys(Pg2une.PgConnector.param_mapping())

    config = case Pg2une.PgConnector.read_current_config(params) do
      {:ok, values} -> values
      {:error, _} -> %{}
    end

    send_json(conn, 200, %{config: config})
  end

  # Current analysis/detection state from Datalox fact store
  get "/api/analysis" do
    analysis = %{
      cusum_degradations: format_facts(Anytune.query(:pg2une, {:cusum_degradation, [:_, :_]})),
      otava_change_points: format_facts(Anytune.query(:pg2une, {:otava_change_point, [:_, :_]})),
      prophet_forecasts: format_facts(Anytune.query(:pg2une, {:prophet_forecast, [:_, :_, :_, :_]})),
      usl_deviation: format_facts(Anytune.query(:pg2une, {:usl_deviation, [:_]})),
      high_confidence: Anytune.query(:pg2une, {:high_confidence, []}) != [],
      should_act: format_facts(Anytune.query(:pg2une, {:should_act, [:_]})),
      metric_values: format_facts(Anytune.query(:pg2une, {:metric_value, [:_, :_]}))
    }

    send_json(conn, 200, %{analysis: analysis})
  end

  # Trigger optimization
  post "/api/optimize" do
    action = case conn.body_params do
      %{"action" => a} -> String.to_existing_atom(a)
      _ -> :holistic
    end

    case Pg2une.DeploymentManager.start_optimization(action) do
      {:ok, result} -> send_json(conn, 200, %{result: result})
      {:error, reason} -> send_json(conn, 409, %{error: inspect(reason)})
    end
  end

  # Optimization history
  get "/api/optimizations" do
    limit = get_query_param(conn, "limit", "20") |> String.to_integer()
    history = Pg2une.MetricsStore.optimization_history(limit: limit)

    data = Enum.map(history, fn r ->
      %{
        id: r.id,
        action: r.action,
        status: r.status,
        config: r.config,
        baseline_metrics: r.baseline_metrics,
        result_metrics: r.result_metrics,
        improvement_pct: r.improvement_pct,
        created_at: r.inserted_at
      }
    end)

    send_json(conn, 200, %{optimizations: data})
  end

  # Specific optimization run
  get "/api/optimization/:id" do
    case Pg2une.Repo.get(Pg2une.Schemas.OptimizationRun, id) do
      nil -> send_json(conn, 404, %{error: "not found"})
      run -> send_json(conn, 200, %{optimization: run})
    end
  end

  # Infrastructure status
  get "/api/infrastructure" do
    status = Pg2une.DeploymentManager.status()
    send_json(conn, 200, %{infrastructure: format_status(status)})
  end

  # Ensure infrastructure running
  post "/api/infrastructure" do
    case Pg2une.DeploymentManager.ensure_infrastructure() do
      :ok -> send_json(conn, 200, %{status: "ok"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Push metrics (for in-VM agent mode)
  post "/api/ingest" do
    metrics = conn.body_params

    case Anytune.ingest(:pg2une, metrics) do
      :ok -> send_json(conn, 200, %{status: "ok"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp format_status(:idle), do: "idle"
  defp format_status({state, action}), do: "#{state}:#{action}"
  defp format_status(other), do: inspect(other)

  defp get_query_param(conn, key, default) do
    conn.query_params[key] || default
  end

  defp format_facts(facts) when is_list(facts) do
    Enum.map(facts, fn {predicate, args} ->
      %{predicate: predicate, args: args}
    end)
  end

  defp format_facts(_), do: []
end
