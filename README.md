# nix-odysseus

Standalone Nix flake for the [Odysseus AI workspace](https://github.com/pewdiepie-archdaemon/odysseus) — a self-hosted AI platform with chat, agents, memory, documents, research, and email. Rebased from upstream [PR #1523](https://github.com/pewdiepie-archdaemon/odysseus/pull/1523).

Provides a native Nix derivation — no pip, venv, or Docker at runtime.

## Quickstart

<details open>
<summary>Dev shell</summary>

```sh
nix develop github:your-user/nix-odysseus
```
Drops into a shell with Python 3.13, Node.js, process-compose, and Playwright browsers wired. Run `process-compose up` to start ChromaDB + the app, or `odysseus` directly.
</details>

<details open>
<summary>NixOS module</summary>

Add to your system flake:

```nix
inputs.odysseus.url = "github:your-user/nix-odysseus";
```
In configuration:
```nix
imports = [ inputs.odysseus.nixosModules.default ];
services.odysseus = {
  enable = true;
  environmentFile = "/run/secrets/odysseus-env";
};
```
Starts Odysseus + ChromaDB as systemd services. Data lives at `/var/lib/odysseus/data`.
</details>

<details>
<summary>nix-darwin module</summary>

```nix
inputs.odysseus.url = "github:your-user/nix-odysseus";
# In darwin-configuration:
imports = [ inputs.odysseus.darwinModules.default ];
services.odysseus = { enable = true; };
```
</details>

## Flake outputs

- `packages.default` — the app derivation with `odysseus`, `odysseus-setup`, `odysseus-chroma` wrappers
- `packages.container` — layered OCI image (`dockerTools.buildLayeredImage`)
- `devShells.default` — dev shell with process-compose, Playwright, all build tools
- `devShells.python` — Python environment only (no Node.js, no Playwright)
- `nixosModules.default` — NixOS systemd service module
- `darwinModules.default` — nix-darwin launchd service module
- `checks` — NixOS VM test, container validation, Darwin integration test

## Module options

<details>
<summary>services.odysseus options</summary>

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the service |
| `port` | port | `7000` | App listen port |
| `host` | str | `"0.0.0.0"` | Bind address |
| `dataDir` | path | `"/var/lib/odysseus"` | Persistent data root |
| `environmentFile` | nullOr path | `null` | Secrets file path |
| `extraEnvironmentVariables` | attrsOf str | `{}` | Extra env vars for app. Set `ODYSSEUS_ADMIN_PASSWORD` here to pre-seed the admin password on first boot. |
| `extraPythonPackages` | functionTo (listOf package) | `ps: []` | Extra Python deps (e.g., `ps: [ps.hf-transfer ps.rembg]`) |
| `chromaPort` | port | `8100` | ChromaDB vector DB port |
| `openFirewall` | bool | `false` | Open app port in firewall |
| `searxng.enable` | bool | `false` | Bundled SearXNG metasearch |
| `searxng.port` | port | `8888` | SearXNG port |
| `searxng.secretKey` | str | placeholder | Must be changed |
| `llamaCpp.enable` | bool | `false` | llama.cpp on service PATH |
| `llamaCpp.package` | package | `pkgs.llama-cpp` | Override for GPU backend |

</details>

## Admin password

On first boot, `setup.py` runs the admin account flow with this priority:

1. `ODYSSEUS_ADMIN_USER` + `ODYSSEUS_ADMIN_PASSWORD` env vars → use directly
2. Interactive TTY → prompts for username + password
3. Non-interactive (systemd, Docker, CI) → generates a random password, prints it to stderr

The random password is logged by systemd. Retrieve it:
```bash
journalctl -u odysseus --no-pager | grep 'Temporary password'
```

Or set it declaratively:
```nix
services.odysseus.extraEnvironmentVariables = {
  ODYSSEUS_ADMIN_PASSWORD = "your-secure-password";
};
```

Set this **before** first boot. If `auth.json` already exists, the env var is ignored.
To reset: stop the service, delete `/var/lib/odysseus/data/auth.json`, set the env var, start.

## Architecture

```
nix/lib.nix                       Shared kernel: mkRuntimeLibs, mkPythonEnv, mkOdysseusPackage, mkContainer
nix/shell.nix                     Dev shell with process-compose + Playwright
nix/modules/services/odysseus.nix NixOS + nix-darwin service modules
nix/modules/checks/integration.nix Integration tests
```

<details>
<summary>Modules and boundaries</summary>

- **Shared kernel** — `nix/lib.nix`: package builders consumed by shell, service modules, and checks
- **Context boundary** — `flake.nix`: wires source input, passes `src` to modules
- **Service modules** — `nix/modules/services/`: system configuration for systemd and launchd
- **Integration tests** — `nix/modules/checks/`: VM test, container validation, Darwin process check
- **Dev shell** — `nix/shell.nix`: development environment, imports shared kernel

</details>

## Built-in MCP servers

Pins `pewdiepie-archdaemon/odysseus/dev`. The upstream repo evolves rapidly — pin to a specific commit in `flake.nix` for reproducible deployments:

```nix
inputs.odysseus-src = {
  url = "github:pewdiepie-archdaemon/odysseus/<commit-sha>";
  flake = false;
};
```
