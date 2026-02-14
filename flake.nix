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
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.fswatch
          ];

          shellHook = ''
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"
            export ERL_AFLAGS="-kernel shell_history enabled"
            export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$HEX_HOME/bin:$PATH"
            mkdir -p $MIX_HOME $HEX_HOME

            # Python venv for ML dependencies (via anytune)
            if [ ! -d .venv ]; then
              python3 -m venv .venv
              .venv/bin/pip install --quiet numpy scikit-optimize prophet
            fi
            export PATH="$PWD/.venv/bin:$PATH"
          '';
        };
      });
}
