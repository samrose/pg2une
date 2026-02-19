{
  description = "pg2une - PostgreSQL auto-tuner on mxc microVMs";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        erlang = pkgs.beam.interpreters.erlang_27;
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir_1_18;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            erlang
            elixir
            pkgs.rebar3
            pkgs.python312
            pkgs.postgresql_17
            pkgs.process-compose
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.inotify-tools
            pkgs.cloud-hypervisor
            pkgs.qemu_kvm
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.fswatch
            pkgs.qemu
          ];

          shellHook = ''
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"
            export ERL_AFLAGS="-kernel shell_history enabled"
            export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$HEX_HOME/bin:$PATH"
            mkdir -p $MIX_HOME $HEX_HOME

            # Python venv for ML dependencies (via anytune)
            DEPS_VERSION="numpy scikit-optimize prophet otava scipy pandas"
            DEPS_MARKER=".venv/.deps_version"
            if [ ! -d .venv ] || [ ! -f "$DEPS_MARKER" ] || [ "$(cat "$DEPS_MARKER")" != "$DEPS_VERSION" ]; then
              python3 -m venv .venv
              .venv/bin/pip install --quiet $DEPS_VERSION
              echo "$DEPS_VERSION" > "$DEPS_MARKER"
            fi
            export PATH="$PWD/.venv/bin:$PATH"
          '';
        };
      }
    ) // {
      # MicroVM configurations for pg2une infrastructure
      # These are NixOS systems (always linux guests), built from any host
      nixosConfigurations = let
        inherit (nixpkgs) lib;

        mkPg2uneVM = { hostSystem, guestSystem, name, extraModules ? [] }:
          lib.nixosSystem {
            system = guestSystem;
            modules = [
              microvm.nixosModules.microvm
              ({ lib, ... }: {
                # Use host packages for the runner when building from darwin
                microvm.vmHostPackages = lib.mkIf (lib.hasSuffix "-darwin" hostSystem)
                  nixpkgs.legacyPackages.${hostSystem};
              })
            ] ++ extraModules;
            specialArgs = { pkgs = nixpkgs.legacyPackages.${guestSystem}; };
          };
      in {
        # PostgreSQL primary — aarch64 (Apple Silicon / aarch64-linux)
        "pg2une-postgres-aarch64" = mkPg2uneVM {
          hostSystem = "aarch64-darwin";
          guestSystem = "aarch64-linux";
          name = "pg2une-postgres";
          extraModules = [ ./priv/nix/postgres.nix ];
        };

        # PostgreSQL primary — x86_64
        "pg2une-postgres-x86_64" = mkPg2uneVM {
          hostSystem = "x86_64-darwin";
          guestSystem = "x86_64-linux";
          name = "pg2une-postgres";
          extraModules = [ ./priv/nix/postgres.nix ];
        };

        # PostgreSQL replica (canary) — aarch64
        "pg2une-postgres-replica-aarch64" = mkPg2uneVM {
          hostSystem = "aarch64-darwin";
          guestSystem = "aarch64-linux";
          name = "pg2une-postgres-replica";
          extraModules = [ ./priv/nix/postgres-replica.nix ];
        };

        # PostgreSQL replica (canary) — x86_64
        "pg2une-postgres-replica-x86_64" = mkPg2uneVM {
          hostSystem = "x86_64-darwin";
          guestSystem = "x86_64-linux";
          name = "pg2une-postgres-replica";
          extraModules = [ ./priv/nix/postgres-replica.nix ];
        };

        # PgBouncer — aarch64
        "pg2une-pgbouncer-aarch64" = mkPg2uneVM {
          hostSystem = "aarch64-darwin";
          guestSystem = "aarch64-linux";
          name = "pg2une-pgbouncer";
          extraModules = [ ./priv/nix/pgbouncer.nix ];
        };

        # PgBouncer — x86_64
        "pg2une-pgbouncer-x86_64" = mkPg2uneVM {
          hostSystem = "x86_64-darwin";
          guestSystem = "x86_64-linux";
          name = "pg2une-pgbouncer";
          extraModules = [ ./priv/nix/pgbouncer.nix ];
        };
      };
    };
}
