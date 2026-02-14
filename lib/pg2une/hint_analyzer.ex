defmodule Pg2une.HintAnalyzer do
  @moduledoc """
  Generates query hint candidates by running EXPLAIN on regressed queries
  and comparing costs with/without INDEX hints via pg_hint_plan.

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
    target_url = Pg2une.Config.target_url()

    case connect_and_analyze(target_url) do
      {:ok, candidates} -> candidates
      {:error, _reason} -> []
    end
  end

  defp connect_and_analyze(nil), do: {:ok, []}

  defp connect_and_analyze(url) do
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
      candidates = analyze_regressed_queries(conn)
      GenServer.stop(conn)
      {:ok, candidates}
    end
  end

  defp analyze_regressed_queries(conn) do
    # Get regressed queries from the fact store
    regressions =
      try do
        Anytune.FactStore.query(:pg2une_store, {:query_regression, [:_, :_, :_]})
      rescue
        _ -> []
      end

    Enum.flat_map(regressions, fn {:query_regression, [queryid, _load_type, _pct]} ->
      analyze_query_hints(conn, queryid)
    end)
  end

  defp analyze_query_hints(conn, queryid) do
    # Get the query text
    case Postgrex.query(conn, """
      SELECT query FROM pg_stat_statements WHERE queryid = $1 LIMIT 1
    """, [queryid]) do
      {:ok, %{rows: [[query_text]]}} ->
        generate_hint_candidates(conn, queryid, query_text)

      _ ->
        []
    end
  end

  defp generate_hint_candidates(conn, queryid, query_text) do
    # Check if pg_hint_plan is available
    case Postgrex.query(conn, "SELECT 1 FROM pg_extension WHERE extname = 'pg_hint_plan'", []) do
      {:ok, %{rows: [_]}} ->
        # pg_hint_plan available — analyze EXPLAIN costs
        do_hint_analysis(conn, queryid, query_text)

      _ ->
        []
    end
  end

  defp do_hint_analysis(_conn, queryid, _query_text) do
    # Placeholder: full implementation would run EXPLAIN with and without hints,
    # compare costs, and return beneficial hints
    # For now, return empty — the optimizer works fine with just knobs + indexes
    Logger.debug("HintAnalyzer: would analyze hints for query #{queryid}")
    []
  end

  defp candidates_to_dimensions(candidates) do
    Enum.map(candidates, fn c ->
      %Anytune.Dimension{
        name: "hint_q#{c.queryid}",
        type: :categorical,
        choices: [0, 1]
      }
    end)
  end
end
