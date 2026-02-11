defmodule Pgtune.WorkloadDetectorTest do
  use ExUnit.Case, async: true

  alias Pgtune.WorkloadDetector

  setup do
    name = :"wd_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(WorkloadDetector, [], name: name)
    %{pid: pid, name: name}
  end

  test "defaults to mixed workload", %{name: name} do
    assert GenServer.call(name, :current) == :mixed
  end

  test "classifies high TPS + many connections as OLTP", %{name: name} do
    GenServer.cast(name, {:update, %{
      "tps" => 500.0,
      "conn_active" => 80,
      "latency_p99" => 5.0,
      "temp_bytes" => 0
    }})

    # Give cast time to process
    Process.sleep(10)
    assert GenServer.call(name, :current) == :oltp
  end

  test "classifies high latency + temp_bytes as OLAP", %{name: name} do
    GenServer.cast(name, {:update, %{
      "tps" => 10.0,
      "conn_active" => 5,
      "latency_p99" => 500.0,
      "temp_bytes" => 500_000_000
    }})

    Process.sleep(10)
    assert GenServer.call(name, :current) == :olap
  end

  test "classifies ambiguous metrics as mixed", %{name: name} do
    GenServer.cast(name, {:update, %{
      "tps" => 50.0,
      "conn_active" => 20,
      "latency_p99" => 50.0,
      "temp_bytes" => 50_000_000
    }})

    Process.sleep(10)
    assert GenServer.call(name, :current) == :mixed
  end

  test "updates classification on new metrics", %{name: name} do
    # Start OLTP
    GenServer.cast(name, {:update, %{"tps" => 500.0, "conn_active" => 80,
      "latency_p99" => 5.0, "temp_bytes" => 0}})
    Process.sleep(10)
    assert GenServer.call(name, :current) == :oltp

    # Shift to OLAP
    GenServer.cast(name, {:update, %{"tps" => 10.0, "conn_active" => 5,
      "latency_p99" => 500.0, "temp_bytes" => 500_000_000}})
    Process.sleep(10)
    assert GenServer.call(name, :current) == :olap
  end
end
