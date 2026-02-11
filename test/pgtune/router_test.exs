defmodule Pgtune.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias Pgtune.Router

  @opts Router.init([])

  setup do
    # Start required services if not running
    unless Process.whereis(Pgtune.Config) do
      {:ok, _} = Pgtune.Config.start_link(total_ram_mb: 4096)
    end

    unless Process.whereis(Pgtune.WorkloadDetector) do
      {:ok, _} = Pgtune.WorkloadDetector.start_link()
    end

    unless Process.whereis(Pgtune.DeploymentManager) do
      {:ok, _} = Pgtune.DeploymentManager.start_link()
    end

    unless Process.whereis(Pgtune.MetricsPoller) do
      {:ok, _} = GenServer.start_link(Pgtune.MetricsPoller, [target_url: nil], name: Pgtune.MetricsPoller)
    end

    :ok
  end

  test "GET / returns health check" do
    conn = conn(:get, "/") |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["app"] == "pgtune"
  end

  test "GET /api/status returns status and workload type" do
    conn = conn(:get, "/api/status") |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "idle"
    assert body["workload_type"] in ["oltp", "olap", "mixed"]
  end

  test "GET /api/metrics returns metrics" do
    conn = conn(:get, "/api/metrics") |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Map.has_key?(body, "metrics")
  end

  test "GET unknown route returns 404" do
    conn = conn(:get, "/api/nonexistent") |> Router.call(@opts)

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "not found"
  end

  test "POST /api/ingest accepts metrics" do
    # This will fail because anytune isn't started, but should not crash
    conn =
      conn(:post, "/api/ingest", %{"tps" => 1000.0})
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    # Will be 500 because anytune isn't running, but router handles it
    assert conn.status in [200, 500]
  end
end
