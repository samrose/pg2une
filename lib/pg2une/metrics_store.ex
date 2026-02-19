defmodule Pg2une.MetricsStore do
  @moduledoc """
  Persists metrics to pg2une's own PostgreSQL via Ecto.

  Provides query functions for historical metrics used by
  periodic analysis (Prophet, E-Divisive) and query regression detection.
  """

  import Ecto.Query
  alias Pg2une.Repo
  alias Pg2une.Schemas.{SystemSnapshot, WorkloadSnapshot, OptimizerObservation, OptimizationRun}

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
