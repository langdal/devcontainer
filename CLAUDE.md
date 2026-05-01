# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A portable, editor-agnostic development container using a plain Dockerfile and a `dev` bash wrapper script. Uses `mise` for per-project tool management. No devcontainer.json, no docker-compose, no editor-specific config.

## Build and Run

```bash
# Build the image
docker build -t generic-devcontainer .

# macOS users (UID 501)
docker build -t generic-devcontainer --build-arg USER_UID=501 .

# Start/attach to container (from any project directory)
./dev

# Run a command inside the container
./dev -- npm run dev

# Force rebuild
./dev --build
```

## Tests

There is an automated end-to-end test suite under `scripts/test/`:

```bash
sudo bash scripts/test/run-all.sh
```

The orchestrator needs passwordless `sudo`. It auto-installs `docker.io`,
`docker-buildx`, and `podman` on Debian/Ubuntu hosts if a runtime is
missing, auto-detects broken in-container DNS resolvers and sets
`DEV_EXTRA_RUN_ARGS=--dns=8.8.8.8 --dns=1.1.1.1` if needed, builds both
the base and `:dind` image targets, then walks every script under
`scripts/test/scenarios/` and reports a pass/fail/skip table.

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
  normal / maintenance / dind containers). See README.md for details.
