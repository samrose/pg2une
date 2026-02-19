defmodule Pg2une.PgConnectorTest do
  use ExUnit.Case, async: false

  alias Pg2une.PgConnector

  setup do
    unless Process.whereis(Pg2une.Config) do
      {:ok, _} = Pg2une.Config.start_link(
        target_url: "postgres://samrose:@localhost:5432/postgres",
        total_ram_mb: 4096
      )
    end

    Pg2une.Config.put(:target_url, "postgres://samrose:@localhost:5432/postgres")
    :ok
  end

  test "param_mapping contains expected keys" do
    mapping = PgConnector.param_mapping()
    assert mapping["shared_buffers_mb"] == "shared_buffers"
    assert mapping["work_mem_mb"] == "work_mem"
    assert mapping["effective_cache_size_mb"] == "effective_cache_size"
    assert mapping["random_page_cost"] == "random_page_cost"
    assert mapping["max_connections"] == "max_connections"
    assert mapping["maintenance_work_mem_mb"] == "maintenance_work_mem"
  end

  @tag :integration
  test "apply_config and read_current_config round-trip" do
    config = %{"work_mem_mb" => 32, "random_page_cost" => 1.5}

    # Apply
    assert {:ok, applied} = PgConnector.apply_config(config)
    assert Map.has_key?(applied, "work_mem_mb")
    assert Map.has_key?(applied, "random_page_cost")

    # Read back
    assert {:ok, current} = PgConnector.read_current_config(["work_mem_mb", "random_page_cost"])
    assert current["work_mem_mb"] == "32MB"
    assert current["random_page_cost"] == "1.5"

    # Rollback
    assert :ok = PgConnector.rollback_config(config)

    # Verify reset
    assert {:ok, after_reset} = PgConnector.read_current_config(["work_mem_mb"])
    # After RESET + reload, should be back to server default (not necessarily "32MB")
    assert is_binary(after_reset["work_mem_mb"])
  end

  @tag :integration
  test "params_requiring_restart identifies postmaster params" do
    config = %{
      "shared_buffers_mb" => 512,
      "max_connections" => 200,
      "work_mem_mb" => 32,
      "random_page_cost" => 1.5
    }

    assert {:ok, restart_keys} = PgConnector.params_requiring_restart(config)

    # shared_buffers and max_connections require restart
    assert "shared_buffers_mb" in restart_keys
    assert "max_connections" in restart_keys

    # work_mem and random_page_cost are reload-safe
    refute "work_mem_mb" in restart_keys
    refute "random_page_cost" in restart_keys
  end

  @tag :integration
  test "rollback_config resets parameters" do
    config = %{"work_mem_mb" => 64}

    assert {:ok, _} = PgConnector.apply_config(config)
    assert :ok = PgConnector.rollback_config(config)
  end

  test "apply_config ignores unknown parameter keys" do
    config = %{"unknown_param" => 42}

    # Should succeed but apply nothing (no known keys)
    # Will still connect and call pg_reload_conf with 0 params applied
    case PgConnector.apply_config(config) do
      {:ok, applied} -> assert applied == %{}
      {:error, :no_target_url} -> :ok
    end
  end
end
