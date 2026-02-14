defmodule Pg2une.PgBouncer do
  @moduledoc """
  Manages PgBouncer configuration for traffic routing between
  primary and canary PostgreSQL instances.

  Generates PgBouncer config and pushes updates to the PgBouncer microVM.
  """

  require Logger

  def update_routing(_pgbouncer_workload_id, %{canary_pct: pct}) do
    Logger.info("PgBouncer: routing #{pct}% to canary, #{100 - pct}% to primary")

    # In full implementation:
    # 1. Get PgBouncer VM IP from mxc workload info
    # 2. Generate pgbouncer.ini with weighted backends
    # 3. Push config via SSH or shared volume
    # 4. Send SIGHUP to reload

    :ok
  end

  def generate_config(opts) do
    primary_host = Keyword.fetch!(opts, :primary_host)
    primary_port = Keyword.get(opts, :primary_port, 5432)
    canary_host = Keyword.get(opts, :canary_host)
    canary_port = Keyword.get(opts, :canary_port, 5432)
    canary_pct = Keyword.get(opts, :canary_pct, 0)

    databases_section = if canary_host && canary_pct > 0 do
      # PgBouncer doesn't natively support weighted routing.
      # Implement via multiple pool entries and application-level routing,
      # or use DNS-based routing with weight support.
      """
      [databases]
      primary = host=#{primary_host} port=#{primary_port} dbname=postgres
      canary = host=#{canary_host} port=#{canary_port} dbname=postgres
      * = host=#{primary_host} port=#{primary_port} dbname=postgres
      """
    else
      """
      [databases]
      * = host=#{primary_host} port=#{primary_port} dbname=postgres
      """
    end

    """
    #{databases_section}
    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = 6432
    auth_type = trust
    pool_mode = transaction
    max_client_conn = 1000
    default_pool_size = 50
    log_connections = 0
    log_disconnections = 0
    """
  end
end
