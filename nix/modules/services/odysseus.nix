# odysseus.nix
#
# Purpose: NixOS and nix-darwin service modules for the Odysseus AI workspace.
#
# Provides { nixosModule, darwinModule }.  `src` is the upstream source path,
# passed by the flake so package builds resolve correctly from this nested file.
{ src }:
let
  inherit (import ../../lib.nix) mkOdysseusPackage mkRuntimeLibs;
  mkServiceTools =
    pkgs: with pkgs; [
      bash
      nodejs
      tmux
      openssh
      curl
      git
    ];
in
{
  nixosModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.odysseus;
      runtimeLibs = mkRuntimeLibs pkgs;
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        types
        optionalAttrs
        ;
    in
    {
      options.services.odysseus = {
        enable = mkEnableOption "Odysseus AI assistant";

        extraPythonPackages = mkOption {
          type = with lib.types; functionTo (listOf package);
          default = ps: [ ];
          example = lib.literalExpression "ps: [ ps.hf-transfer ps.rembg ps.diffusers ]";
          description = ''
            Extra Python packages merged into the app environment, in
            withPackages form (ps: [ ps.hf-transfer ps.rembg ]).
          '';
        };

        package = mkOption {
          type = types.package;
          default = mkOdysseusPackage pkgs src cfg.extraPythonPackages;
          defaultText = lib.literalExpression "odysseus built with config.services.odysseus.extraPythonPackages";
          description = "The odysseus package to use.";
        };

        port = mkOption {
          type = types.port;
          default = 7000;
          description = "Port to listen on.";
        };

        host = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = "Interface to bind.";
        };

        chromaPort = mkOption {
          type = types.port;
          default = 8100;
          description = ''
            Port for the bundled ChromaDB vector database server.
          '';
        };

        searxng = {
          enable = mkEnableOption "bundled SearXNG metasearch";
          port = mkOption {
            type = types.port;
            default = 8888;
            description = "Port for the bundled SearXNG instance.";
          };
          secretKey = mkOption {
            type = types.str;
            default = "change-me-before-exposing-to-the-network";
            description = ''
              SearXNG secret_key. MUST be changed from the default before
              enabling.
            '';
          };
        };

        extraEnvironmentVariables = mkOption {
          type = with lib.types; attrsOf str;
          default = { };
          example = {
            SEARXNG_GENERAL_ENGINES = "bing,mojeek";
            LLM_HOST = "http://10.0.0.5:11434";
          };
          description = ''
            Extra environment variables for the app service. Merged last.
          '';
        };

        llamaCpp = {
          enable = mkEnableOption "bundling llama.cpp for Cookbook GGUF serving";
          package = mkOption {
            type = types.package;
            default = pkgs.llama-cpp;
            example = lib.literalExpression "pkgs.llama-cpp-rocm";
            description = ''
              llama.cpp build providing `llama-server`.
            '';
          };
        };

        dataDir = mkOption {
          type = types.path;
          default = "/var/lib/odysseus";
          description = "Root directory for all persistent app data.";
        };

        user = mkOption {
          type = types.str;
          default = "odysseus";
        };

        group = mkOption {
          type = types.str;
          default = "odysseus";
        };

        environmentFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Path to a file of KEY=VALUE environment variables.
          '';
        };

        openFirewall = lib.mkEnableOption "opening the firewall for the Odysseus app port";
      };

      config = mkIf cfg.enable {
        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = cfg.dataDir;
          createHome = true;
          description = "Odysseus service user";
        };
        users.groups.${cfg.group} = { };

        assertions = [
          {
            assertion =
              !cfg.searxng.enable
              || cfg.searxng.secretKey != "change-me-before-exposing-to-the-network";
            message = "services.odysseus.searxng.secretKey must be changed from its default before enabling SearXNG.";
          }
        ];

        services.searx = mkIf cfg.searxng.enable {
          enable = true;
          settings = {
            server = {
              port = cfg.searxng.port;
              bind_address = "127.0.0.1";
              secret_key = cfg.searxng.secretKey;
              limiter = false;
            };
            search.formats = [
              "html"
              "json"
            ];
          };
        };

        systemd.services.odysseus-chroma = {
          description = "Odysseus ChromaDB vector database";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          path = [ pkgs.bash ] ++ runtimeLibs;

          environment = {
            PYTHONUNBUFFERED = "1";
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
          };

          preStart = ''
            mkdir -p "${cfg.dataDir}/data/chroma"
          '';

          serviceConfig = {
            Type = "simple";
            User = cfg.user;
            Group = cfg.group;
            WorkingDirectory = cfg.dataDir;
            ExecStart = ''
              ${cfg.package}/bin/odysseus-chroma run \
                --path ${cfg.dataDir}/data/chroma \
                --host 127.0.0.1 \
                --port ${toString cfg.chromaPort}
            '';
            StateDirectory = "odysseus";
            StateDirectoryMode = "0750";
            Restart = "on-failure";
            RestartSec = "3s";
          };
        };

        systemd.services.odysseus = {
          description = "Odysseus AI assistant";
          after = [
            "network.target"
            "odysseus-chroma.service"
          ];
          wants = [ "odysseus-chroma.service" ];
          wantedBy = [ "multi-user.target" ];

          path =
            mkServiceTools pkgs
            ++ lib.optional cfg.llamaCpp.enable cfg.llamaCpp.package
            ++ runtimeLibs;

          environment = {
            PYTHONUNBUFFERED = "1";
            ODYSSEUS_DATA_DIR = "${cfg.dataDir}/data";
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
            CHROMADB_HOST = "127.0.0.1";
            CHROMADB_PORT = toString cfg.chromaPort;
          }
          // optionalAttrs cfg.searxng.enable {
            SEARXNG_INSTANCE = "http://127.0.0.1:${toString cfg.searxng.port}";
          }
          // cfg.extraEnvironmentVariables;

          preStart =
            let
              data = "${cfg.dataDir}/data";
            in
            ''
              for d in "${data}" \
                        "${data}/uploads" \
                        "${data}/personal_docs" \
                        "${data}/personal_docs/runbook" \
                        "${data}/tts_cache" \
                        "${data}/generated_images" \
                        "${data}/deep_research" \
                        "${data}/chroma" \
                        "${data}/rag" \
                        "${data}/memory_vectors" \
                        "${data}/logs"; do
                mkdir -p "$d"
              done

              if [ ! -f "${data}/auth.json" ]; then
                ODYSSEUS_DATA_DIR="${data}" \
                  ${cfg.package}/bin/odysseus-setup
              fi
            '';

          serviceConfig = {
            Type = "simple";
            User = cfg.user;
            Group = cfg.group;
            WorkingDirectory = cfg.dataDir;
            ExecStart = "${cfg.package}/bin/odysseus --host ${cfg.host} --port ${toString cfg.port}";
            StateDirectory = "odysseus";
            StateDirectoryMode = "0750";
            Restart = "on-failure";
            RestartSec = "3s";
          }
          // optionalAttrs (cfg.environmentFile != null) {
            EnvironmentFile = "-${cfg.environmentFile}";
          };
        };

        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
      };
    };

  darwinModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.odysseus;
      runtimeLibs = mkRuntimeLibs pkgs;
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        types
        optionalAttrs
        ;
    in
    {
      options.services.odysseus = {
        enable = mkEnableOption "Odysseus AI assistant";

        extraPythonPackages = mkOption {
          type = with lib.types; functionTo (listOf package);
          default = ps: [ ];
          example = lib.literalExpression "ps: [ ps.hf-transfer ps.rembg ps.diffusers ]";
          description = ''
            Extra Python packages merged into the app environment.
          '';
        };

        package = mkOption {
          type = types.package;
          default = mkOdysseusPackage pkgs src cfg.extraPythonPackages;
          defaultText = lib.literalExpression "odysseus built with config.services.odysseus.extraPythonPackages";
          description = "The odysseus package to use.";
        };

        port = mkOption {
          type = types.port;
          default = 7000;
          description = "Port to listen on.";
        };

        host = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = "Interface to bind.";
        };

        chromaPort = mkOption {
          type = types.port;
          default = 8100;
          description = "Port for the bundled ChromaDB vector database server.";
        };

        searxng = {
          enable = mkEnableOption "bundled SearXNG metasearch";
          port = mkOption {
            type = types.port;
            default = 8888;
            description = "Port for the bundled SearXNG instance.";
          };
          secretKey = mkOption {
            type = types.str;
            default = "change-me-before-exposing-to-the-network";
            description = ''
              SearXNG secret_key. MUST be changed from the default before
              enabling.
            '';
          };
        };

        extraEnvironmentVariables = mkOption {
          type = with lib.types; attrsOf str;
          default = { };
          example = {
            SEARXNG_GENERAL_ENGINES = "bing,mojeek";
            LLM_HOST = "http://10.0.0.5:11434";
          };
          description = ''
            Extra environment variables for the app service. Merged last.
          '';
        };

        llamaCpp = {
          enable = mkEnableOption "bundling llama.cpp for Cookbook GGUF serving";
          package = mkOption {
            type = types.package;
            default = pkgs.llama-cpp;
            example = lib.literalExpression "pkgs.llama-cpp-rocm";
            description = "llama.cpp build providing `llama-server`.";
          };
        };

        dataDir = mkOption {
          type = types.path;
          default = "/var/lib/odysseus";
          description = "Root directory for all persistent app data.";
        };

        user = mkOption {
          type = types.str;
          default = "odysseus";
        };

        group = mkOption {
          type = types.str;
          default = "odysseus";
        };

        environmentFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file of KEY=VALUE environment variables.";
        };
      };

      config = mkIf cfg.enable {
        users.users.${cfg.user} = {
          gid = config.users.groups.${cfg.group}.gid or null;
          home = cfg.dataDir;
          createHome = true;
          description = "Odysseus service user";
        };
        users.groups.${cfg.group} = { };

        assertions = [
          {
            assertion =
              !cfg.searxng.enable
              || cfg.searxng.secretKey != "change-me-before-exposing-to-the-network";
            message = "services.odysseus.searxng.secretKey must be changed from its default before enabling SearXNG.";
          }
        ];

        launchd.daemons.odysseus-searxng = mkIf cfg.searxng.enable {
          command =
            let
              settings = pkgs.writeText "searxng-settings.yml" ''
                use_default_settings: true
                server:
                  port: ${toString cfg.searxng.port}
                  bind_address: "127.0.0.1"
                  secret_key: "${cfg.searxng.secretKey}"
                  limiter: false
                search:
                  formats:
                    - html
                    - json
              '';
            in
            ''
              #!/bin/sh
              mkdir -p "${cfg.dataDir}/logs"
              export SEARXNG_SETTINGS_PATH=${settings}
              exec ${pkgs.searxng}/bin/searxng-run
            '';

          serviceConfig = {
            KeepAlive = true;
            RunAtLoad = true;
            StandardOutPath = "${cfg.dataDir}/logs/searxng.out.log";
            StandardErrorPath = "${cfg.dataDir}/logs/searxng.err.log";
          };
        };

        launchd.daemons.odysseus-chroma = {
          command =
            let
              data = "${cfg.dataDir}/data";
            in
            ''
              #!/bin/sh
              mkdir -p "${data}/chroma" "${cfg.dataDir}/logs"
              exec ${cfg.package}/bin/odysseus-chroma run \
                --path "${data}/chroma" \
                --host 127.0.0.1 \
                --port ${toString cfg.chromaPort}
            '';

          serviceConfig = {
            KeepAlive = true;
            RunAtLoad = true;
            StandardOutPath = "${cfg.dataDir}/logs/chroma.out.log";
            StandardErrorPath = "${cfg.dataDir}/logs/chroma.err.log";
            EnvironmentVariables = {
              PYTHONUNBUFFERED = "1";
              LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
            };
          };
        };

        launchd.daemons.odysseus = {
          command =
            let
              data = "${cfg.dataDir}/data";
            in
            ''
              #!/bin/sh
              for d in "${data}" \
                        "${data}/uploads" \
                        "${data}/personal_docs" \
                        "${data}/personal_docs/runbook" \
                        "${data}/tts_cache" \
                        "${data}/generated_images" \
                        "${data}/deep_research" \
                        "${data}/chroma" \
                        "${data}/rag" \
                        "${data}/memory_vectors" \
                        "${data}/logs"; do
                mkdir -p "$d"
              done

              if [ ! -f "${data}/auth.json" ]; then
                ODYSSEUS_DATA_DIR="${data}" \
                  ${cfg.package}/bin/odysseus-setup
              fi

              exec ${cfg.package}/bin/odysseus --host ${cfg.host} --port ${toString cfg.port}
            '';

          serviceConfig = {
            KeepAlive = true;
            RunAtLoad = true;
            WorkingDirectory = cfg.dataDir;
            StandardOutPath = "${cfg.dataDir}/logs/launchd.out.log";
            StandardErrorPath = "${cfg.dataDir}/logs/launchd.err.log";
            EnvironmentVariables = {
              PYTHONUNBUFFERED = "1";
              ODYSSEUS_DATA_DIR = "${cfg.dataDir}/data";
              LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
              PATH = "${
                pkgs.lib.makeBinPath (
                  mkServiceTools pkgs ++ lib.optional cfg.llamaCpp.enable cfg.llamaCpp.package
                )
              }:/usr/bin:/bin:/usr/sbin:/sbin";
              CHROMADB_HOST = "127.0.0.1";
              CHROMADB_PORT = toString cfg.chromaPort;
            }
            // optionalAttrs cfg.searxng.enable {
              SEARXNG_INSTANCE = "http://127.0.0.1:${toString cfg.searxng.port}";
            }
            // cfg.extraEnvironmentVariables;
          };
        };

        environment.systemPackages = mkServiceTools pkgs ++ runtimeLibs;
      };
    };
}
