defmodule Pg2une.PgBouncerTest do
  use ExUnit.Case, async: true

  alias Pg2une.PgBouncer

  test "generates config with primary only" do
    config = PgBouncer.generate_config(
      primary_host: "10.0.0.1",
      primary_port: 5432
    )

    assert config =~ "host=10.0.0.1"
    assert config =~ "port=5432"
    assert config =~ "listen_port = 6432"
    assert config =~ "pool_mode = transaction"
    refute config =~ "canary"
  end

  test "generates config with canary routing" do
    config = PgBouncer.generate_config(
      primary_host: "10.0.0.1",
      primary_port: 5432,
      canary_host: "10.0.0.2",
      canary_port: 5432,
      canary_pct: 25
    )

    assert config =~ "host=10.0.0.1"
    assert config =~ "host=10.0.0.2"
    assert config =~ "primary"
    assert config =~ "canary"
  end

  test "config without canary when canary_pct is 0" do
    config = PgBouncer.generate_config(
      primary_host: "10.0.0.1",
      canary_host: "10.0.0.2",
      canary_pct: 0
    )

    refute config =~ "canary"
  end

  test "update_routing returns :ok" do
    assert :ok = PgBouncer.update_routing("workload-123", %{canary_pct: 25})
  end
end
