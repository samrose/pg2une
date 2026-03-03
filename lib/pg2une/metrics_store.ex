defmodule Pg2une.MetricsStore do
  @moduledoc """
  Persists metrics to pg2une's own PostgreSQL via Ecto.

  Provides query functions for historical metrics used by
  periodic analysis (Prophet, E-Divisive) and query regression detection.
  """

  import Ecto.Query
  alias Pg2une.Repo
  alias Pg2une.Schemas.{SystemSnapshot, SystemSnapshotHourly, WorkloadSnapshot, OptimizerObservation, OptimizationRun}

  def record_system_snapshot(metrics) when is_map(metrics) do
    attrs = Map.put(metrics, "snapshot_time", DateTime.utc_now())

    %SystemSnapshot{}
    |> SystemSnapshot.changeset(attrs)
    |> Repo.insert()
  end

  def record_workload_snapshots(snapshots) when is_list(snapshots) do
    now = DateTime.utc_now()

    entries =
      Enum.map(snapshots, fn snapshot ->
        Map.put(snapshot, :snapshot_time, now)
      end)

    Repo.insert_all(WorkloadSnapshot, entries)
  end

  def record_observation(attrs) do
    %OptimizerObservation{}
    |> OptimizerObservation.changeset(attrs)
    |> Repo.insert()
  end

  def create_optimization_run(attrs) do
    %OptimizationRun{}
    |> OptimizationRun.changeset(attrs)
    |> Repo.insert()
  end

  def update_optimization_run(%OptimizationRun{} = run, attrs) do
    run
    |> OptimizationRun.changeset(attrs)
    |> Repo.update()
  end

  def recent_system_metrics(minutes \\ 60) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    from(s in SystemSnapshot,
      where: s.snapshot_time >= ^cutoff,
      order_by: [asc: s.snapshot_time]
    )
    |> Repo.all()
  end

  def recent_workload_metrics(queryid, minutes \\ 60) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    from(w in WorkloadSnapshot,
      where: w.queryid == ^queryid and w.snapshot_time >= ^cutoff,
      order_by: [asc: w.snapshot_time]
    )
    |> Repo.all()
  end

  def query_baselines(minutes \\ 360) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    from(w in WorkloadSnapshot,
      where: w.snapshot_time >= ^cutoff,
      group_by: w.queryid,
      select: %{
        queryid: w.queryid,
        avg_exec_time: avg(w.mean_exec_time),
        avg_calls: avg(w.calls_delta),
        count: count(w.id)
      },
      having: count(w.id) >= 5
    )
    |> Repo.all()
  end

  def optimization_history(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(r in OptimizationRun,
      order_by: [desc: r.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Archives minute-level snapshots older than 30 days into hourly aggregates,
  then deletes the originals. Keeps system_snapshots lean while preserving
  long-term trends in system_snapshots_hourly.
  """
  def archive_old_snapshots do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)

    hourly =
      from(s in SystemSnapshot,
        where: s.snapshot_time < ^cutoff,
        group_by: fragment("date_trunc('hour', ?)", s.snapshot_time),
        select: %{
          hour: fragment("date_trunc('hour', ?)", s.snapshot_time),
          tps_avg: avg(s.tps),
          tps_max: max(s.tps),
          conn_active_avg: type(avg(s.conn_active), :float),
          buffer_hit_ratio_avg: avg(s.buffer_hit_ratio),
          latency_p99_avg: avg(s.latency_p99),
          latency_p99_max: max(s.latency_p99),
          sample_count: count(s.id)
        }
      )
      |> Repo.all()

    if hourly == [] do
      :ok
    else
      entries =
        Enum.map(hourly, fn row ->
          hour =
            case row.hour do
              %DateTime{} = dt -> dt
              %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC")
            end

          %{
            hour: hour,
            tps_avg: row.tps_avg,
            tps_max: row.tps_max,
            conn_active_avg: row.conn_active_avg,
            buffer_hit_ratio_avg: row.buffer_hit_ratio_avg,
            latency_p99_avg: row.latency_p99_avg,
            latency_p99_max: row.latency_p99_max,
            sample_count: row.sample_count
          }
        end)

      Repo.insert_all(SystemSnapshotHourly, entries,
        on_conflict: :nothing,
        conflict_target: [:hour]
      )

      {deleted, _} =
        from(s in SystemSnapshot, where: s.snapshot_time < ^cutoff)
        |> Repo.delete_all()

      require Logger
      Logger.info("MetricsStore: archived #{length(entries)} hourly buckets, deleted #{deleted} minute-level snapshots")
      :ok
    end
  end

  def prior_observations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workload_type = Keyword.get(opts, :workload_type)

    query = from(o in OptimizerObservation, order_by: [desc: o.inserted_at], limit: ^limit)

    query =
      if workload_type do
        from(o in query, where: o.workload_type == ^to_string(workload_type))
      else
        query
      end

    Repo.all(query)
  end
end
