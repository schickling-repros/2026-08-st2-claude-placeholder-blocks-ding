{
  description = "st2 DING is never transported when Claude's composer shows a context-derived placeholder";

  inputs = {
    # The nixpkgs revision st2 itself locks, so the pinned st2 derivation matches upstream exactly.
    nixpkgs.url = "github:NixOS/nixpkgs/e2587caef70cea85dd97d7daab492899902dbf5d";
    st2.url = "github:compoundingtech/st2/3e0129434ac214d46fc4cace94c7086ec486302f";
    st2.inputs.nixpkgs.follows = "nixpkgs";
    # The `pty` revision st2 itself locks at the pinned st2 revision.
    pty.url = "github:compoundingtech/pty/504ac7332895fe1fa3767b530dcd99f091f56cda";
    pty.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      st2,
      pty,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      st2Rev = "3e0129434ac214d46fc4cace94c7086ec486302f";
      ptyRev = "504ac7332895fe1fa3767b530dcd99f091f56cda";
      witnessFor =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.writeShellApplication {
          name = "st2-claude-placeholder-repro";
          runtimeInputs = [
            pty.packages.${system}.default
            pkgs.bash
            pkgs.coreutils
            pkgs.gawk
            pkgs.gnugrep
            pkgs.gnused
            pkgs.jq
          ];
          text = ''
            export REPRO_ST2=${nixpkgs.lib.getExe st2.packages.${system}.default}
            export REPRO_ST2_REV=${st2Rev}
            export REPRO_ST2_SHORT_REV=${builtins.substring 0 7 st2Rev}
            export REPRO_PTY_REV=${ptyRev}
            ${builtins.readFile ./repro.sh}
          '';
        };
    in
    {
      packages = forAllSystems (system: { default = witnessFor system; });
      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = nixpkgs.lib.getExe (witnessFor system);
        };
      });
    };
}
