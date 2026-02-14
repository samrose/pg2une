# NixOS microVM configuration for PgBouncer
# Handles traffic routing between primary and canary PostgreSQL instances.
{ pkgs, lib, ... }:
{
  microvm = {
    vcpu = 1;
    mem = 256;
    hypervisor = "qemu";
  };

  networking.hostName = "pg2une-pgbouncer";
  networking.firewall.allowedTCPPorts = [ 6432 ];

  services.pgbouncer = {
    enable = true;

    settings = {
      pgbouncer = {
        listen_addr = "0.0.0.0";
        listen_port = 6432;
        auth_type = "trust";
        pool_mode = "transaction";
        max_client_conn = 1000;
        default_pool_size = 50;
        log_connections = 0;
        log_disconnections = 0;
      };

      # Default: route everything to primary
      # DeploymentManager updates this at runtime
      databases = {
        "*" = "host=pg2une-postgres port=5432 dbname=postgres";
      };
    };
  };
}
