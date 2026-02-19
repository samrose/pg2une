defmodule Pg2une.PgConnector do
  @moduledoc """
  Centralizes ALTER SYSTEM interaction with the target PostgreSQL instance.

  Translates pg2une parameter names (e.g. `shared_buffers_mb`) to PostgreSQL
  GUC names (`shared_buffers`) and applies/rollbacks config changes via
  ALTER SYSTEM SET / RESET + pg_reload_conf().
  """

  require Logger

  @param_mapping %{
    "shared_buffers_mb" => "shared_buffers",
    "effective_cache_size_mb" => "effective_cache_size",
    "work_mem_mb" => "work_mem",
    "maintenance_work_mem_mb" => "maintenance_work_mem",
    "random_page_cost" => "random_page_cost",
    "max_connections" => "max_connections"
  }

  @doc """
  Applies configuration by running ALTER SYSTEM SET for each parameter,
  then SELECT pg_reload_conf(). Returns {:ok, applied_params} or {:error, reason}.
  """
  def apply_config(config_map) when is_map(config_map) do
    with {:ok, conn} <- connect() do
      try do
        applied =
          config_map
          |> Enum.filter(fn {key, _} -> Map.has_key?(@param_mapping, key) end)
          |> Enum.map(fn {key, value} ->
            pg_name = Map.fetch!(@param_mapping, key)
            pg_value = format_value(key, value)

            case Postgrex.query(conn, "ALTER SYSTEM SET #{pg_name} = '#{pg_value}'", []) do
              {:ok, _} ->
                Logger.info("PgConnector: SET #{pg_name} = '#{pg_value}'")
                {key, pg_value}

              {:error, reason} ->
                Logger.error("PgConnector: failed to SET #{pg_name}: #{inspect(reason)}")
                throw({:alter_failed, pg_name, reason})
            end
          end)

        case Postgrex.query(conn, "SELECT pg_reload_conf()", []) do
          {:ok, _} ->
            Logger.info("PgConnector: pg_reload_conf() called, #{length(applied)} params applied")
            {:ok, Map.new(applied)}

          {:error, reason} ->
            {:error, {:reload_failed, reason}}
        end
      catch
        {:alter_failed, param, reason} ->
          {:error, {:alter_failed, param, reason}}
      after
        GenServer.stop(conn)
      end
    end
  end

  @doc """
  Rolls back configuration by running ALTER SYSTEM RESET for each parameter,
  then pg_reload_conf().
  """
  def rollback_config(config_map) when is_map(config_map) do
    with {:ok, conn} <- connect() do
      try do
        config_map
        |> Enum.filter(fn {key, _} -> Map.has_key?(@param_mapping, key) end)
        |> Enum.each(fn {key, _value} ->
          pg_name = Map.fetch!(@param_mapping, key)

          case Postgrex.query(conn, "ALTER SYSTEM RESET #{pg_name}", []) do
            {:ok, _} ->
              Logger.info("PgConnector: RESET #{pg_name}")

            {:error, reason} ->
              Logger.warning("PgConnector: failed to RESET #{pg_name}: #{inspect(reason)}")
          end
        end)

        Postgrex.query(conn, "SELECT pg_reload_conf()", [])
        :ok
      after
        GenServer.stop(conn)
      end
    end
  end

  @doc """
  Reads current values for a list of pg2une parameter names from the target PG.
  Returns a map of %{"param_name" => current_value}.
  """
  def read_current_config(param_list) when is_list(param_list) do
    with {:ok, conn} <- connect() do
      try do
        result =
          param_list
          |> Enum.filter(fn key -> Map.has_key?(@param_mapping, key) end)
          |> Enum.reduce(%{}, fn key, acc ->
            pg_name = Map.fetch!(@param_mapping, key)

            case Postgrex.query(conn, "SHOW #{pg_name}", []) do
              {:ok, %{rows: [[value]]}} ->
                Map.put(acc, key, value)

              {:error, _reason} ->
                acc
            end
          end)

        {:ok, result}
      after
        GenServer.stop(conn)
      end
    end
  end

  @doc """
  Returns the subset of config_map keys that require a PostgreSQL restart
  (context = 'postmaster' in pg_settings).
  """
  def params_requiring_restart(config_map) when is_map(config_map) do
    with {:ok, conn} <- connect() do
      try do
        pg_names =
          config_map
          |> Enum.filter(fn {key, _} -> Map.has_key?(@param_mapping, key) end)
          |> Enum.map(fn {key, _} -> Map.fetch!(@param_mapping, key) end)

        if pg_names == [] do
          {:ok, []}
        else
          placeholders = Enum.map_join(1..length(pg_names), ", ", &"$#{&1}")

          case Postgrex.query(
                 conn,
                 "SELECT name FROM pg_settings WHERE context = 'postmaster' AND name IN (#{placeholders})",
                 pg_names
               ) do
            {:ok, %{rows: rows}} ->
              restart_pg_names = Enum.map(rows, fn [name] -> name end)

              restart_keys =
                @param_mapping
                |> Enum.filter(fn {_key, pg_name} -> pg_name in restart_pg_names end)
                |> Enum.map(fn {key, _pg_name} -> key end)
                |> Enum.filter(fn key -> Map.has_key?(config_map, key) end)

              {:ok, restart_keys}

            {:error, reason} ->
              {:error, reason}
          end
        end
      after
        GenServer.stop(conn)
      end
    end
  end

  @doc "Returns the parameter name mapping from pg2une keys to PG GUC names."
  def param_mapping, do: @param_mapping

  defp connect do
    url = Pg2une.Config.target_url()

    if url do
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
    else
      {:error, :no_target_url}
    end
  end

  defp format_value(key, value) when is_number(value) do
    if String.ends_with?(key, "_mb") do
      "#{round(value)}MB"
    else
      to_string(value)
    end
  end

  defp format_value(_key, value), do: to_string(value)
end
