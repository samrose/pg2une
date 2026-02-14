# NixOS microVM configuration for PostgreSQL streaming replica (canary)
# Launched by DeploymentManager during blue-green deployment.
# Replicates from the primary via streaming replication.
{ pkgs, lib, config, ... }:
{
  microvm = {
    vcpu = 4;
    mem = 2048;
    hypervisor = "qemu";
  };

  networking.hostName = "pg2une-postgres-replica";
  networking.firewall.allowedTCPPorts = [ 5432 ];

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    enableTCPIP = true;

    authentication = lib.mkForce ''
      host all all 0.0.0.0/0 trust
      host replication all 0.0.0.0/0 trust
      local all all trust
    '';

    settings = {
      hot_standby = true;
      hot_standby_feedback = true;

      # primary_conninfo set via recovery.conf / postgresql.auto.conf
      # Will be configured at runtime by DeploymentManager

      shared_preload_libraries = "pg_stat_statements,pg_hint_plan";

      # Default settings — will be overridden by optimized config
      shared_buffers = "512MB";
      effective_cache_size = "1536MB";
      work_mem = "16MB";
    };
  };

  environment.systemPackages = with pkgs; [
    postgresql_17.pkgs.pg_hint_plan
  ];
}
