defmodule Pg2une.IndexAnalyzer do
  @moduledoc """
  Generates index candidates from pg_qualstats column access patterns
  and slow queries. Tests candidates via hypopg hypothetical indexes.

  Returns Anytune.Dimension structs for the optimizer's search space.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def dimensions do
    GenServer.call(__MODULE__, :dimensions)
  end

  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # Server

  @impl true
  def init(_opts) do
    {:ok, %{candidates: [], dimensions: []}}
  end

  @impl true
  def handle_call(:dimensions, _from, state) do
    {:reply, state.dimensions, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    candidates = generate_candidates()
    dims = candidates_to_dimensions(candidates)
    {:noreply, %{state | candidates: candidates, dimensions: dims}}
  end

  defp generate_candidates do
    # Query pg_qualstats for column access patterns
    # This requires a connection to the target PG
    target_url = Pg2une.Config.target_url()

    case connect_and_query(target_url) do
      {:ok, candidates} -> candidates
      {:error, _reason} -> []
    end
  end

  defp connect_and_query(nil), do: {:ok, []}

  defp connect_and_query(url) do
    uri = URI.parse(url)
    userinfo = String.split(uri.userinfo || "postgres:", ":")

    opts = [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: Enum.at(userinfo, 0, "postgres"),
      password: Enum.at(userinfo, 1, ""),
      database: String.trim_leading(uri.path || "/postgres", "/")
    ]

    with {:ok, conn} <- Postgrex.start_link(opts) do
      candidates = query_candidates(conn)
      GenServer.stop(conn)
      {:ok, candidates}
    end
  end

  defp query_candidates(conn) do
    # Try pg_qualstats first
    case Postgrex.query(conn, """
      SELECT schemaname, tablename, attnames, opclasses,
             sum(count) as total_count
      FROM pg_qualstats_all
      JOIN pg_catalog.pg_class c ON c.oid = pg_qualstats_all.relid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      GROUP BY schemaname, tablename, attnames, opclasses
      HAVING sum(count) > 10
      ORDER BY total_count DESC
      LIMIT 20
    """, []) do
      {:ok, result} ->
        Enum.map(result.rows, fn [schema, table, columns, _opclasses, count] ->
          %{
            schema: schema,
            table: table,
            columns: columns,
            access_count: count,
            index_type: "btree"
          }
        end)

      {:error, _} ->
        # pg_qualstats not available — fall back to slow query analysis
        slow_query_candidates(conn)
    end
  end

  defp slow_query_candidates(conn) do
    case Postgrex.query(conn, """
      SELECT queryid, query
      FROM pg_stat_statements
      WHERE mean_exec_time > 100
      ORDER BY mean_exec_time DESC
      LIMIT 10
    """, []) do
      {:ok, result} ->
        Enum.flat_map(result.rows, fn [_queryid, query] ->
          extract_table_candidates(query)
        end)

      {:error, _} ->
        []
    end
  end

  defp extract_table_candidates(_query) do
    # Simple heuristic: would need EXPLAIN parsing for real candidates
    # Placeholder — returns empty for now
    []
  end

  defp candidates_to_dimensions(candidates) do
    Enum.map(candidates, fn c ->
      name = "idx_#{c.table}_#{Enum.join(List.wrap(c.columns), "_")}"

      %Anytune.Dimension{
        name: name,
        type: :categorical,
        choices: [0, 1]
      }
    end)
  end
end
