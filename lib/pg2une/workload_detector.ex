defmodule Pg2une.WorkloadDetector do
  @moduledoc """
  Classifies the current PostgreSQL workload as OLTP, OLAP, or Mixed.

  Uses heuristics from collected metrics: TPS, latency, temp_bytes, connection count.
  Port of Python pg2une's detect_workload_type logic.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def current do
    GenServer.call(__MODULE__, :current)
  end

  def update(metrics) when is_map(metrics) do
    GenServer.cast(__MODULE__, {:update, metrics})
  end

  # Server

  @impl true
  def init(_opts) do
    {:ok, %{workload_type: :mixed}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.workload_type, state}
  end

  @impl true
  def handle_cast({:update, metrics}, state) do
    workload_type = classify(metrics)
    {:noreply, %{state | workload_type: workload_type}}
  end

  defp classify(metrics) do
    tps = Map.get(metrics, "tps", 0)
    latency_p99 = Map.get(metrics, "latency_p99", 0)
    temp_bytes = Map.get(metrics, "temp_bytes", 0)
    conn_active = Map.get(metrics, "conn_active", 0)

    oltp_score = oltp_score(tps, conn_active)
    olap_score = olap_score(latency_p99, temp_bytes)

    cond do
      oltp_score > olap_score + 1 -> :oltp
      olap_score > oltp_score + 1 -> :olap
      true -> :mixed
    end
  end

  defp oltp_score(tps, conn_active) do
    score = 0
    score = if tps > 100, do: score + 2, else: score
    score = if conn_active > 50, do: score + 1, else: score
    score
  end

  defp olap_score(latency_p99, temp_bytes) do
    score = 0
    score = if latency_p99 > 100, do: score + 2, else: score
    score = if temp_bytes > 100_000_000, do: score + 2, else: score
    score
  end
end
