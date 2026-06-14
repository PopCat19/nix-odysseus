# flake.nix
#
# Purpose: Standalone flake for the Odysseus AI workspace derivation, NixOS
# module, and nix-darwin module.  Rebased from upstream PR #1523.  Provides a
# native Nix derivation (no pip/venv/Docker at runtime) with bundled ChromaDB,
# optional SearXNG, and optional llama.cpp.
{
  description = "Odysseus AI workspace — standalone Nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    odysseus-src = {
      url = "github:pewdiepie-archdaemon/odysseus/dev";
      flake = false;
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      odysseus-src,
      nix-darwin,
    }:
    let
      inherit (import ./nix/lib.nix)
        mkOdysseusPackage
        mkContainer
        mkRuntimeLibs
        ;
      odysseusModules = import ./nix/modules/services/odysseus.nix {
        src = odysseus-src;
      };
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        odysseus = mkOdysseusPackage pkgs odysseus-src (ps: [ ]);
      in
      {
        devShells = {
          default = import ./nix/shell.nix {
            inherit pkgs;
            src = odysseus-src;
          };
          # Flake input for downstream consumers that want the python env directly.
          python = import ./nix/shell.nix {
            inherit pkgs;
            src = odysseus-src;
            pythonOnly = true;
          };
        };

        packages = {
          default = odysseus;
          container = mkContainer pkgs odysseus;
        };
      }
    )
    // {
      nixosModules.default = odysseusModules.nixosModule;
      darwinModules.default = odysseusModules.darwinModule;
      checks = import ./nix/modules/checks/integration.nix {
        inherit
          self
          nixpkgs
          nix-darwin
          mkRuntimeLibs
          ;
      };
    };
}
