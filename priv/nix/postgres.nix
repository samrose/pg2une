# NixOS microVM configuration for PostgreSQL primary
# Used by mxc to build and launch the database VM.
{ pkgs, lib, ... }:
{
  microvm = {
    vcpu = 4;
    mem = 2048;
    hypervisor = "qemu";
  };

  networking.hostName = "pgtune-postgres";
  networking.firewall.allowedTCPPorts = [ 5432 ];

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    enableTCPIP = true;

    ensureDatabases = [ "postgres" ];
    ensureUsers = [
      {
        name = "pgtune";
        ensureDBOwnership = true;
        ensureClauses.superuser = true;
      }
    ];

    authentication = lib.mkForce ''
      # Allow connections from the host and other VMs
      host all all 0.0.0.0/0 trust
      local all all trust
    '';

    settings = {
      # Replication support for canary deployment
      wal_level = "replica";
      max_wal_senders = 5;
      max_replication_slots = 5;
      hot_standby = true;

      # Extensions
      shared_preload_libraries = "pg_stat_statements,pg_hint_plan";

      # Default tuning (will be overridden by optimizer)
      shared_buffers = "512MB";
      effective_cache_size = "1536MB";
      work_mem = "16MB";
      maintenance_work_mem = "256MB";
      random_page_cost = 1.1;
    };
  };

  # Install additional extensions
  environment.systemPackages = with pkgs; [
    postgresql_17.pkgs.pg_hint_plan
  ];
}
