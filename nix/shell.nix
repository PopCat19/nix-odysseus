# shell.nix
#
# Purpose: Odysseus development shell with process-compose and Playwright wiring.
#
# Parameters (both optional):
#   src        : path to the odysseus source checkout (defaults to ../.)
#   pythonOnly : if true, skip process-compose/Playwright; provide only the Python env
{
  pkgs ? import <nixpkgs> { },
  src ? ../.,
  pythonOnly ? false,
}:
let
  inherit (import ./lib.nix) mkRuntimeLibs mkPythonEnv mkOdysseusPackage;
  runtimeLibs = mkRuntimeLibs pkgs;
  pythonEnv = mkPythonEnv pkgs (ps: [ ]);
  odysseus = mkOdysseusPackage pkgs src (ps: [ ]);

  # Full shell with process-compose and Playwright.
  fullBuildInputs =
    with pkgs;
    [
      git
      cmake
      nodejs
      tmux
      openssh
      curl
      gcc
      pkg-config
      process-compose
      gnumake
      pythonEnv
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      gosu
    ]
    ++ runtimeLibs;

  # Minimal shell: Python env + runtime libs only.
  pythonBuildInputs = [
    pythonEnv
  ] ++ runtimeLibs;

  fullHook = ''
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    SESSION_NAME="odysseus"

    echo "Odysseus Nix shell for ${pkgs.system} is loaded."

    if [ ! -d "$ODYSSEUS_DATA_DIR" ]; then
        echo "First configuration detected. Everything is being set-up!"
        ${odysseus}/bin/odysseus-setup
        echo "-----------------------------------------------------"
        echo "Make sure you remember your admin username and temporary password!"
    else
        echo "Setup has already been executed..."
    fi

    echo ""
    echo "How to run Odysseus:"
    echo ""
    echo "  Recommended - start the whole stack (ChromaDB + app) together:"
    echo "    process-compose up          # foreground, Ctrl-C to stop"
    echo "    process-compose up -D       # detached; 'process-compose down' to stop"
    echo "                                # 'process-compose attach' to view logs/TUI"
    echo ""
    echo "  Keep it running after you close the terminal (detached tmux):"
    echo "    tmux new -s $SESSION_NAME 'process-compose up'   # start in background"
    echo "    tmux attach -t $SESSION_NAME                     # reattach later"
    echo "    tmux kill-session -t $SESSION_NAME               # stop everything"
    echo ""
    echo "  Or run the pieces manually in separate shells:"
    echo "    chroma run --path ./data/chroma --host 0.0.0.0 --port 8100"
    echo "    odysseus"
  '';
in
pkgs.mkShell {
  name = "odysseus-dev-env";
  buildInputs = if pythonOnly then pythonBuildInputs else fullBuildInputs;
  env = {
    APP_HOST = "0.0.0.0";
    APP_PORT = "7000";
    PYTHONPATH = ".";
    ODYSSEUS_DATA_DIR = "./data";
    CHROMA_DATA_DIR = "./data/chroma";
  }
  // pkgs.lib.optionalAttrs (!pythonOnly) {
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };
  shellHook = if pythonOnly then "" else fullHook;
}
