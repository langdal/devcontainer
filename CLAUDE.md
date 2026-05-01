# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A portable, editor-agnostic development container using a plain Dockerfile and a `dev` bash wrapper script. Uses `mise` for per-project tool management. No devcontainer.json, no docker-compose, no editor-specific config.

## Build and Run

```bash
# Build the image
docker build -t generic-devcontainer .

# Start/attach to container (from any project directory).
# ./dev reads `id -u`/`id -g` and bakes them into the image automatically;
# no manual --build-arg is needed on macOS or Linux.
./dev

# Run a command inside the container
./dev -- npm run dev

# Force rebuild (also triggered automatically on UID/GID mismatch)
./dev --build

# Maintenance shell (firewall off, sudo enabled) — for installing system
# packages or fetching from non-allowlisted hosts. Container is named
# dev-<dir>-maint and is mutually exclusive with the normal/dind containers.
./dev --maintenance

# Rootless Docker-in-Docker (separate :dind image, dev-<dir>-dind container).
./dev --dind

# Toggle the firewall on a running container without restarting:
./dev --disable-firewall
./dev --enable-firewall

# Observe firewall behaviour on a running container:
./dev --monitor       # tail tinyproxy.log
./dev --monitor-fw    # tcpdump on NFLOG group 1 (iptables drops)
```

Useful environment variables for `./dev`:

- `DEV_RUNTIME=docker|podman` — force a runtime when both are installed (default: docker preferred on Linux; podman only on macOS).
- `DEV_ASSUME_YES=1` — accept the rebuild-and-wipe-volumes prompt non-interactively (used when UID/GID labels disagree with the host).
- `DEV_SKIP_APPARMOR_CHECK=1` — bypass the `--dind` AppArmor preflight (only safe with a custom profile that grants `userns,`).
- `DEV_EXTRA_RUN_ARGS=...` — extra args passed to `docker run` (the test orchestrator uses this to inject `--dns=...` when in-container DNS is broken).

## Tests

There is an automated end-to-end test suite under `scripts/test/`:

```bash
# Full matrix
sudo bash scripts/test/run-all.sh

# Run one scenario directly (each script under scenarios/ is self-contained
# and uses helpers from scripts/test/lib/). Pass/fail is determined by
# log_pass/log_fail/log_skip lines.
bash scripts/test/scenarios/22-cold-start-budget.sh
```

The orchestrator needs passwordless `sudo`. It auto-installs `docker.io`,
`docker-buildx`, and `podman` on Debian/Ubuntu hosts if a runtime is
missing, auto-detects broken in-container DNS resolvers and sets
`DEV_EXTRA_RUN_ARGS=--dns=8.8.8.8 --dns=1.1.1.1` if needed, builds both
the base and `:dind` image targets, then walks every script under
`scripts/test/scenarios/` and reports a pass/fail/skip table. Logs land
at `scripts/test/last-run.log` and `scripts/test/last-summary.log`.

In addition there are two in-container probes:

- `scripts/verify-firewall.sh` — 12 checks. 7 cover the firewall posture;
  checks 8–12 activate when `DEVCONTAINER_DIND=1` and verify the rootless
  dockerd, registry pulls through the proxy, and that nested containers
  can reach loopback ports but not the internet.
- `scripts/verify-dind.sh` — heavier checks (smoke build, postgres
  testcontainers smoke, self-build of this repo's Dockerfile).

There is no linter or CI pipeline.

## Architecture

Three components, each with a distinct role:

- **Dockerfile** — Builds the base image on `mcr.microsoft.com/devcontainers/base:ubuntu`. Installs mise to `/usr/local/bin/mise`, bakes in base tools from `mise.base.toml` into `/mise/`, stages `.zshrc` to `/etc/skel.devcontainer/` for entrypoint sync.

- **entrypoint.sh** — Runs on every container start. Idempotently ensures `mise activate zsh` is in `.zshrc`, runs `mise install` if a project `mise.toml` exists in `/workspace`, sets git safe.directory, then execs into the shell.

- **dev** — Host-side bash script managing the container lifecycle. Handles image auto-build, container reuse (attach to running/restart stopped), volume mounts, port forwarding, and `GITHUB_TOKEN` passthrough.

## Key Design Decisions

- **Mise data lives at `/mise/`**, not in the home directory. `MISE_DATA_DIR`, `MISE_CONFIG_DIR`, and `MISE_CACHE_DIR` all point there. This allows the mise volume (`devcontainer-mise`) and home volume (`devcontainer-home`) to be independent.
- **Two named Docker volumes** persist state: `devcontainer-mise:/mise` (tools/caches) and `devcontainer-home:/home/vscode` (shell history, git config, SSH keys).
- **Container runs as user `vscode`** (UID 1000 by default, overridable via `USER_UID` build arg).
- **Containers are `--rm`** (ephemeral) but the `dev` script reuses a running/stopped container named `dev-<dirname>` before creating a new one.
- **Base tools** (node LTS, ripgrep, eza, lazygit) are defined in `mise.base.toml` and baked into the image at build time. The file is named `mise.base.toml` rather than `mise.toml` so mise does not treat it as a project config when this repo is itself opened in the devcontainer. Per-project tools come from the consuming project's own `mise.toml` and are installed at container startup.
- **Opt-in Docker-in-Docker** via `./dev --dind`. Builds a separate
  `generic-devcontainer:dind` image (the `dind` target in the multi-stage
  Dockerfile) that adds rootless `dockerd`, fuse-overlayfs, and
  slirp4netns. The container is named `dev-<dir>-dind`, mounts
  `/dev/fuse` + `/dev/net/tun`, and uses a dedicated `devcontainer-dind`
  cache volume. Registry pulls flow through `tinyproxy` via the
  slirp4netns gateway (`HTTPS_PROXY=http://10.0.2.2:8888`). Mutually
  exclusive with `--maintenance` (three-way conflict guard between
  normal / maintenance / dind containers). On Ubuntu 23.10+/Linux 6.x
  hosts `./dev` preflights `kernel.apparmor_restrict_unprivileged_userns=0`
  and refuses to start with a remediation message if it is `1`. See
  README.md for details.

## Firewall (security boundary)

The firewall is the project's primary security feature — the threat model
is "an AI agent running as `vscode` cannot exfiltrate workspace contents
to arbitrary hosts." Two layers, enforced in the kernel and at L7:

- **iptables** defaults `OUTPUT` to DROP. DNS is allowed; only the `proxy`
  user can reach `:80`/`:443`. Raw-socket bypasses by `vscode` are dropped
  by the kernel owner rule.
- **tinyproxy** runs in the container and filters HTTPS by hostname
  (CONNECT). Clients honour `HTTPS_PROXY=http://127.0.0.1:8888`, exported
  by the entrypoint.
- **`vscode` has no sudo** in normal mode. There is no path to disable
  iptables from inside the container.

Two allowlist files merge at container startup (deduplicated):

- `allowlist.base` — baked into the image at `/etc/devcontainer/allowlist.base`
  (Anthropic, GitHub, common registries, mise, OS mirrors). Edit and rebuild
  to change.
- `.devcontainer-allowlist` at the workspace root — optional, read at every
  container start. No image rebuild needed; restart the container.
- `allowlist.dind` — additionally merged when DinD is active (Docker Hub,
  MCR, Quay, GCR, etc.).

Format: one entry per line, `#` comments. Bare hostname matches exactly;
`*.example.com` matches any subdomain (list both if you need both).

When the firewall is in the way, prefer `--maintenance` (its own container,
sudo + no firewall) over toggling on the running container — the toggle
flags do not change the container name, so there is no visible signal that
the firewall is off.
