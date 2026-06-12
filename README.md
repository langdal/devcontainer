# Generic Devcontainer

A portable, editor-agnostic dev environment. One Dockerfile, one bash wrapper, per-project tools via [`mise`](https://mise.jdx.dev/). No `devcontainer.json`, no `docker-compose`, no editor lock-in.

## Getting Started

You need Docker (Linux) or Podman (macOS/Linux). See [Host requirements](#host-requirements).

### Install in one line

Clones into `${XDG_DATA_HOME:-~/.local/share}/devcontainer` and symlinks the `dev` script onto your PATH:

```bash
curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash
```

Pin to a specific release:

```bash
REF=v1.0.0 curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash
```

Override the install location with `INSTALL_DIR=...`. Re-running upgrades the existing checkout.

Once installed, upgrade in place at any time:

```bash
dev --self-update          # checkout the latest tag in the install dir
dev --self-update --dry-run  # show what would change
```

`--self-update` works whether you installed via the one-liner or manually with `git clone`. It only requires that the `dev` script lives in a clean git checkout; uncommitted edits abort the operation. The image rebuild prompt fires automatically on the next `dev` run if the script version changed.

### Manual install

```bash
git clone https://github.com/langdal/devcontainer.git ~/devcontainer
~/devcontainer/dev install
```

### First use

```bash
cd ~/projects/my-project
dev
```

The first run builds the image. You land in a Zsh shell at `/workspace` with your project mounted.

To install per-project tools, drop a `mise.toml` in your project root:

```toml
[tools]
node = "20"
go = "1.22"
python = "3.12"
```

`mise install` runs on every container start.

## Daily Use

```bash
dev                       # start or attach to the container
dev -- npm test           # run a one-off command in the container
dev --build               # rebuild the image
dev --port 9000           # forward an extra port (repeatable)
dev --default-ports       # forward 5173, 5174, 8080, 2345, 3000
dev --host-port 8080      # allow egress to host.docker.internal:8080
```

Multiple terminals: just run `dev` again — it `exec`s into the running container.

## Container Modes

Only one mode runs per workspace at a time. The script enforces this with a three-way conflict guard.

| Mode             | When to use                                        | Container name      |
| ---------------- | -------------------------------------------------- | ------------------- |
| Normal (default) | Day-to-day work. Firewalled, no sudo.              | `dev-<dir>`         |
| `--maintenance`  | Install system packages, fetch from blocked hosts. | `dev-<dir>-maint`   |
| `--dind`         | Run nested Docker (testcontainers, builds).        | `dev-<dir>-dind`    |

```bash
dev --maintenance         # firewall off, sudo enabled
dev --dind                # rootless dockerd inside the container
```

## Firewall

The container restricts outbound HTTP(S) to a curated allowlist. Threat model: an AI agent running as `vscode` cannot exfiltrate workspace contents to arbitrary hosts.

- iptables defaults `OUTPUT` to DROP. Only the `proxy` user can reach :80/:443.
- `tinyproxy` filters HTTPS by hostname (CONNECT). Clients honour `HTTPS_PROXY=http://127.0.0.1:8888`, exported by the entrypoint.
- `vscode` has no sudo in normal mode — there is no path to disable iptables from inside.

### Allowlist files

One entry per line, `#` for comments. Bare hostnames match exactly; `*.example.com` matches any subdomain (list both if you need both).

- `allowlist.base` — baked into the image. Anthropic, GitHub, common registries, mise, OS mirrors. Edit and rebuild to change.
- `.devcontainer-allowlist` at the workspace root — optional, read at every container start. Restart the container to pick up changes (no rebuild).
- `allowlist.dind` — additionally merged in `--dind` mode (Docker Hub, MCR, Quay, GCR, …).

### Firewall controls

```bash
dev --disable-firewall    # open the firewall (running container, or fresh start)
dev --enable-firewall     # restore default-deny + allowlist on the running container
dev --monitor             # tail the tinyproxy log
dev --monitor-fw          # tcpdump on iptables-dropped packets (NFLOG group 1)
```

`--disable-firewall` is dual-purpose: if a workspace container (normal or dind) is already running it toggles that one in place; if none is running it starts a **fresh** container with the firewall already open — the same end state as starting normally and toggling off. `--enable-firewall` only acts on a running container.

The container name does **not** change when the firewall is toggled, so for longer-lived unrestricted work prefer `--maintenance` — its name (`-maint`) is a visible signal.

### Reaching a host service (e.g. local LLM)

`dev --host-port 8080` (repeatable) is a scoped escape hatch for talking to a service on the Docker host. It:

- adds `--add-host=host.docker.internal:host-gateway` so the hostname resolves to the host gateway IP,
- passes `DEVCONTAINER_HOST_PORTS=8080[,…]` into the container,
- and `firewall-init.sh` adds an iptables `ACCEPT` rule for **only that port to that gateway IP**.

Everything else stays default-deny. Use it instead of `--network host` or `--disable-firewall` when an agent inside the container needs to call out to a local model server, a metrics endpoint, etc. From inside the container: `curl http://host.docker.internal:8080/...`.

To verify the firewall posture from inside:

```bash
dev -- /workspace/scripts/verify-firewall.sh
```

## Docker-in-Docker

Run a rootless `dockerd` inside the container — for the `docker` CLI, testcontainers, and image builds — without `--privileged` and without breaking the firewall.

```bash
dev --dind
docker ps   # nested daemon
```

Registry pulls flow through tinyproxy and are filtered against the same allowlist machinery (extended with `allowlist.dind`). Nested containers' outbound traffic still appears to the host iptables as originating from `vscode`, which the owner-rule blocks. Loopback ports (the testcontainers pattern) work as expected.

A separate `devcontainer-dind` named volume preserves the nested image cache across rebuilds.

```bash
dev --dind -- /workspace/scripts/verify-firewall.sh   # 12 checks
dev --dind -- /workspace/scripts/verify-dind.sh       # heavier smoke tests
```

## Persistence

Two named volumes preserve state across container restarts and rebuilds:

- `devcontainer-mise:/mise` — installed tools and caches
- `devcontainer-home:/home/vscode` — shell history, git config, SSH keys, dotfiles

`--dind` adds `devcontainer-dind` for the nested image cache.

```bash
docker volume rm devcontainer-mise devcontainer-home
```

## Host Requirements

- **Linux**: `docker` or `podman`. Docker is preferred when both are installed. Override with `DEV_RUNTIME=docker` or `DEV_RUNTIME=podman`.
- **macOS**: `podman` only — Docker Desktop is not supported.

  ```bash
  brew install podman
  podman machine init
  podman machine start
  ```

- **`--dind` on Ubuntu 23.10+ / Linux 6.x**: `dev` preflights `kernel.apparmor_restrict_unprivileged_userns`. If it's `1`:

  ```bash
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  echo 'kernel.apparmor_restrict_unprivileged_userns=0' \
    | sudo tee /etc/sysctl.d/99-rootless-userns.conf
  ```

  Set `DEV_SKIP_APPARMOR_CHECK=1` to bypass (e.g. with a custom AppArmor profile that grants `userns,`).

The script reads `id -u` / `id -g` and bakes them into the image. If your host UID/GID later changes, the next `dev` invocation detects the mismatch and prompts to rebuild + wipe volumes.

## `dev` Flags

```
dev [OPTIONS] [-- COMMAND...]
dev install

OPTIONS:
  --help                  Show help
  --version               Print the dev script version and exit
  --dry-run               Print the docker command without running it
  --build                 Force rebuild of the image
  --port PORT             Forward an additional port (repeatable)
  --default-ports         Forward 5173, 5174, 8080, 2345, 3000
  --host-port PORT        Allow egress to host.docker.internal:PORT
                          (repeatable). Adds an iptables ACCEPT for the host
                          gateway only — the firewall stays default-deny
                          everywhere else.
  --maintenance           Start with firewall off and sudo enabled
  --dind                  Start with rootless docker available inside
  --monitor               Tail the firewall proxy log of the running container
  --monitor-fw            Stream iptables-dropped packets of the running container
  --disable-firewall      Open the firewall on the running container, or
                          start a fresh container with the firewall off
  --enable-firewall       Restore the firewall on the running container
  --create-dev-container  Scaffold a self-contained .devcontainer/ for VS Code
                          in the current directory (compose with --dind for
                          the DinD variant)
  --force                 Overwrite existing files when used with
                          --create-dev-container
  --                      Pass the rest as a command into the container

COMMANDS:
  install                 Symlink this script into a writable directory on PATH
```

### Environment variables

- `DEV_RUNTIME=docker|podman` — force a runtime when both are installed.
- `DEV_ASSUME_YES=1` — accept the rebuild prompts non-interactively (UID/GID mismatch also wipes named volumes; version mismatch rebuilds the image only).
- `DEV_SKIP_APPARMOR_CHECK=1` — bypass the `--dind` AppArmor preflight.
- `DEV_EXTRA_RUN_ARGS=...` — extra args appended to `docker run`.
- `GITHUB_TOKEN` — passed through to the container if set on the host.

## Architecture

Three components:

- **Dockerfile** — Multi-stage build on `mcr.microsoft.com/devcontainers/base:ubuntu`. Bakes mise + base tools (node, ripgrep, eza, lazygit) into `/mise/`. The `dind` target adds rootless dockerd, fuse-overlayfs, slirp4netns.
- **entrypoint.sh** — Runs on every container start. Sets up the firewall (or skips it in maintenance mode), runs `mise install` if a `mise.toml` is in `/workspace`, marks `/workspace` as a safe git directory, then `exec`s the shell.
- **dev** — Host-side wrapper. Manages container lifecycle: image build, container reuse, volume mounts, port forwarding, mode selection, firewall toggling.

## Tests

End-to-end suite under `scripts/test/` (needs passwordless `sudo`):

```bash
sudo bash scripts/test/run-all.sh
```

Builds both image targets, walks every script under `scripts/test/scenarios/`, and reports a pass/fail/skip table. Logs at `scripts/test/last-run.log` and `scripts/test/last-summary.log`.
