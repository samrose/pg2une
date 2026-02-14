defmodule Pg2une.MetricsPoller do
  @moduledoc """
  GenServer that polls the target PostgreSQL for metrics on a configurable interval.

  Collects system metrics (pg_stat_database, pg_stat_activity) and per-query
  metrics (pg_stat_statements), then feeds them to:
  - Anytune.ingest/2 for detection
  - Pg2une.MetricsStore for persistence
  - Pg2une.WorkloadDetector for classification
  - Pg2une.QueryRegression for per-query analysis
  """

  use GenServer
  require Logger

  @default_interval 60_000

  defstruct [:conn, :interval, :prev_stats, :prev_db_stats, :timer_ref]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def latest_metrics do
    GenServer.call(__MODULE__, :latest_metrics)
  end

  # Server

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    target_url = Keyword.get(opts, :target_url) || Pg2une.Config.target_url()

    state = %__MODULE__{
      interval: interval,
      prev_stats: %{},
      prev_db_stats: nil
    }

    case connect(target_url) do
      {:ok, conn} ->
        timer_ref = Process.send_after(self(), :poll, interval)
        {:ok, %{state | conn: conn, timer_ref: timer_ref}}

      {:error, reason} ->
        Logger.warning("MetricsPoller: failed to connect to target PG: #{inspect(reason)}")
        timer_ref = Process.send_after(self(), :reconnect, 5_000)
        {:ok, %{state | timer_ref: timer_ref}}
    end
  end

  @impl true
  def handle_call(:latest_metrics, _from, state) do
    {:reply, state.prev_db_stats, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    timer_ref = Process.send_after(self(), :poll, state.interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    target_url = Pg2une.Config.target_url()

    case connect(target_url) do
      {:ok, conn} ->
        Logger.info("MetricsPoller: reconnected to target PG")
        timer_ref = Process.send_after(self(), :poll, state.interval)
        {:noreply, %{state | conn: conn, timer_ref: timer_ref}}

      {:error, _reason} ->
        timer_ref = Process.send_after(self(), :reconnect, 5_000)
        {:noreply, %{state | timer_ref: timer_ref}}
    end
  end

  defp connect(nil), do: {:error, :no_target_url}

  defp connect(url) do
    uri = URI.parse(url)
    userinfo = String.split(uri.userinfo || "postgres:", ":")

    opts = [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: Enum.at(userinfo, 0, "postgres"),
      password: Enum.at(userinfo, 1, ""),
      database: String.trim_leading(uri.path || "/postgres", "/")
    ]

    Postgrex.start_link(opts)
  end

  defp do_poll(%{conn: nil} = state), do: state

  defp do_poll(state) do
    with {:ok, system_metrics} <- collect_system_metrics(state.conn),
         {:ok, query_metrics, new_stats} <- collect_query_metrics(state.conn, state.prev_stats) do
      # Feed anytune for detection
      Anytune.ingest(:pg2une, system_metrics)

      # Update workload classification
      Pg2une.WorkloadDetector.update(system_metrics)

      # Persist to store
      persist_metrics(system_metrics, query_metrics)

      # Run query regression detection
      Pg2une.QueryRegression.analyze(query_metrics)

      %{state | prev_stats: new_stats, prev_db_stats: system_metrics}
    else
      {:error, reason} ->
        Logger.warning("MetricsPoller: collection failed: #{inspect(reason)}")
        state
    end
  end

  defp collect_system_metrics(conn) do
    with {:ok, db_result} <- Postgrex.query(conn, """
           SELECT xact_commit, xact_rollback, blks_hit, blks_read,
                  temp_files, temp_bytes
           FROM pg_stat_database
           WHERE datname = current_database()
           """, []),
         {:ok, activity_result} <- Postgrex.query(conn, """
           SELECT
             count(*) FILTER (WHERE state = 'active') as conn_active,
             count(*) FILTER (WHERE state = 'idle') as conn_idle,
             count(*) as conn_total
           FROM pg_stat_activity
           WHERE backend_type = 'client backend'
           """, []),
         {:ok, latency_result} <- Postgrex.query(conn, """
           SELECT
             percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_exec_time) as p50,
             percentile_cont(0.95) WITHIN GROUP (ORDER BY mean_exec_time) as p95,
             percentile_cont(0.99) WITHIN GROUP (ORDER BY mean_exec_time) as p99
           FROM pg_stat_statements
           WHERE calls > 0
           """, []) do
      [db_row] = db_result.rows
      [xact_commit, _xact_rollback, blks_hit, blks_read, _temp_files, temp_bytes] = db_row

      [activity_row] = activity_result.rows
      [conn_active, conn_idle, _conn_total] = activity_row

      [latency_row] = latency_result.rows
      [p50, p95, p99] = latency_row

      buffer_hit_ratio =
        if (blks_hit + blks_read) > 0,
          do: blks_hit / (blks_hit + blks_read),
          else: 1.0

      metrics = %{
        "tps" => (xact_commit || 0) / 1.0,
        "conn_active" => conn_active || 0,
        "conn_idle" => conn_idle || 0,
        "buffer_hit_ratio" => buffer_hit_ratio,
        "temp_bytes" => temp_bytes || 0,
        "latency_p50" => (p50 || 0) / 1.0,
        "latency_p95" => (p95 || 0) / 1.0,
        "latency_p99" => (p99 || 0) / 1.0
      }

      {:ok, metrics}
    end
  end

  defp collect_query_metrics(conn, prev_stats) do
    case Postgrex.query(conn, """
      SELECT queryid, left(query, 500) as query,
             calls, mean_exec_time, total_exec_time, rows,
             shared_blks_hit, shared_blks_read, temp_blks_written
      FROM pg_stat_statements
      WHERE calls > 0
      ORDER BY total_exec_time DESC
      LIMIT 200
    """, []) do
      {:ok, result} ->
        current_stats =
          Map.new(result.rows, fn [queryid | _rest] = row ->
            {queryid, row}
          end)

        query_metrics =
          Enum.flat_map(result.rows, fn [queryid, query, calls, mean_exec, total_exec,
                                          rows, blks_hit, blks_read, temp_written] ->
            prev = Map.get(prev_stats, queryid)
            prev_calls = if prev, do: Enum.at(prev, 2, 0), else: 0
            calls_delta = (calls || 0) - (prev_calls || 0)

            if calls_delta > 0 do
              [%{
                queryid: queryid,
                query: query,
                calls_delta: calls_delta,
                mean_exec_time: mean_exec || 0.0,
                total_exec_time: total_exec || 0.0,
                rows: rows || 0,
                shared_blks_hit: blks_hit || 0,
                shared_blks_read: blks_read || 0,
                temp_blks_written: temp_written || 0
              }]
            else
              []
            end
          end)

        {:ok, query_metrics, current_stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_metrics(system_metrics, query_metrics) do
    Pg2une.MetricsStore.record_system_snapshot(system_metrics)

    if query_metrics != [] do
      Pg2une.MetricsStore.record_workload_snapshots(query_metrics)
    end
  end
end
