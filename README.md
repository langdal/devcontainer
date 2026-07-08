# Generic Devcontainer

A portable, editor-agnostic dev environment. One Dockerfile, one bash wrapper, per-project tools via [`mise`](https://mise.jdx.dev/). No `devcontainer.json`, no `docker-compose`, no editor lock-in.

## What you get

- **A real dev container in one command.** Run `dev` from any project folder and you land in a shell with your code mounted at `/workspace`. No per-project config files to write or maintain.
- **Per-project tool versions, no clutter.** Drop a `mise.toml` in your repo to pin node/go/python/etc. Tools install on start and cache in a shared volume — not in your home directory.
- **A network firewall built for AI agents.** Outbound traffic is default-deny and filtered to a curated allowlist. The design goal: an agent working inside the container **can freely read and edit your files, but cannot send your code to arbitrary hosts.**
- **State that stays isolated.** Shell history, git config, and dotfiles live in a per-project home volume, so one project's agent can't read another project's SSH keys or credentials.
- **Escape hatches when you need them.** A maintenance mode (sudo, firewall off), nested Docker or Podman for testcontainers and builds, and scoped access to host services — each opt-in and clearly named.

## How it stays safe

The container runs as an unprivileged user (`vscode`) with **no sudo**. The kernel drops all outbound traffic except through a local proxy that only permits connections to allowlisted hostnames. Because the agent can't become root, it has no way to turn the firewall off from the inside. That's the whole security boundary — see [Firewall](#firewall) for specifics, or [`docs/architecture.html`](docs/architecture.html) for a picture.

## How it works

Three files, nothing hidden:

- **`dev`** — the host-side wrapper you run. Builds the image, starts/reuses the container, mounts volumes, forwards ports, picks the mode.
- **Dockerfile** — the image recipe. Ubuntu base + `mise` and a few baked-in tools; separate targets add nested Docker/Podman.
- **entrypoint.sh** — runs on every start: brings up the firewall, installs project tools, then drops to your shell as `vscode`.

Jump to [Architecture](#architecture) for the full diagram.

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
dev update              # checkout the latest tag in the install dir
dev update --dry-run    # show what would change
```

`dev update` works whether you installed via the one-liner or manually with `git clone`. It only requires that the `dev` script lives in a clean git checkout; uncommitted edits abort the operation. The image rebuild prompt fires automatically on the next `dev` run if the script version changed.

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

Only one mode runs per workspace at a time. The script enforces this with a four-way conflict guard.

| Mode             | When to use                                        | Container name      |
| ---------------- | -------------------------------------------------- | ------------------- |
| Normal (default) | Day-to-day work. Firewalled, no sudo.              | `dev-<dir>`         |
| `--maintenance`  | Install system packages, fetch from blocked hosts. | `dev-<dir>-maint`   |
| `--dind`         | Run nested Docker (testcontainers, builds).        | `dev-<dir>-dind`    |
| `--pind`         | Run nested Podman (testcontainers, builds).        | `dev-<dir>-pind`    |

```bash
dev --maintenance         # firewall off, sudo enabled
dev --dind                # rootless dockerd inside the container
dev --pind                # rootless podman inside the container
```

## Firewall

The container restricts outbound HTTP(S) to a curated allowlist. Threat model: an AI agent running as `vscode` cannot exfiltrate workspace contents to arbitrary hosts.

- iptables defaults `OUTPUT` to DROP. Only the `proxy` user can reach :80/:443.
- `tinyproxy` filters HTTPS by hostname (CONNECT). Clients honour `HTTPS_PROXY=http://127.0.0.1:8888`, exported by the entrypoint.
- `vscode` has no sudo in normal mode — there is no path to disable iptables from inside.

### Allowlist files

One entry per line, `#` for comments. Bare hostnames match exactly; `*.example.com` matches any subdomain (list both if you need both).

- `allowlist.base` — baked into the image. Anthropic, GitHub, common registries, mise, OS mirrors. Edit and rebuild to change.
- `.devcontainer-allowlist` at the workspace root — optional, project-specific.
  Because the workspace is writable by the sandboxed agent, `dev` never feeds
  this file to the firewall directly: on start it diffs the file against the
  last **approved** copy (kept under `~/.local/state/devcontainer/`) and asks
  you to approve changes. Declined or non-interactive runs start *without*
  the project allowlist. Restart to pick up an approved change (no rebuild
  needed). Note: the approval gate itself is enforced by the baked
  `firewall-init.sh`, so it only applies on an image built with this version
  of the tooling — on an older image, run `dev --build` once.
- `allowlist.dind` — additionally merged in `--dind` mode (Docker Hub, MCR, Quay, GCR, …). `--pind` reuses this same file — there is no separate `allowlist.pind` — since both nested engines pull from the same registries.

### Firewall controls

```bash
dev fw disable    # open the firewall (running container, or fresh start)
dev fw enable     # restore default-deny + allowlist on the running container
dev fw log        # tail the tinyproxy log
dev fw drops      # tcpdump on iptables-dropped packets (NFLOG group 1)
```

`dev fw disable` is dual-purpose: if a workspace container (normal or dind) is already running it toggles that one in place; if none is running it starts a **fresh** container with the firewall already open — the same end state as starting normally and toggling off. `dev fw enable` only acts on a running container.

The container name does **not** change when the firewall is toggled, so for longer-lived unrestricted work prefer `--maintenance` — its name (`-maint`) is a visible signal.

### Reaching a host service (e.g. local LLM)

`dev --host-port 8080` (repeatable) is a scoped escape hatch for talking to a service on the Docker host. It:

- adds `--add-host=host.docker.internal:host-gateway` so the hostname resolves to the host gateway IP,
- passes `DEVCONTAINER_HOST_PORTS=8080[,…]` into the container,
- and `firewall-init.sh` adds an iptables `ACCEPT` rule for **only that port to that gateway IP**.

Everything else stays default-deny. Use it instead of `--network host` or `dev fw disable` when an agent inside the container needs to call out to a local model server, a metrics endpoint, etc. From inside the container: `curl http://host.docker.internal:8080/...`.

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

## Podman-in-Podman

Run rootless `podman` inside the container — for image builds, testcontainers, and `docker`/`docker compose`-shaped tooling — without `--privileged` and without breaking the firewall. Unlike `--dind`, podman is daemonless: there's no background process, just the `podman` binary and (optionally) a Docker-API compat socket.

```bash
dev --pind
podman ps   # nested engine
docker ps   # podman-docker shim; talks to the same engine
```

Docker CLI compatibility comes from the `podman-docker` package (`/usr/bin/docker` → `podman`) plus a `docker-compose` symlink to the compose v2 plugin — it is **not** the real Docker CLI, just enough of the surface for `docker`/`docker compose` invocations to work. For tooling that speaks the Docker API directly (testcontainers, `docker-compose` libraries), a `podman system service` unix socket at `/home/vscode/.pind-run/podman.sock` is exported as `DOCKER_HOST`.

Registry pulls for podman's own images route through tinyproxy at `127.0.0.1:8888` in the container's main network namespace and are filtered against the same allowlist machinery (extended with `allowlist.dind` — there is no separate `allowlist.pind`, since both nested engines pull from the same registries). Nested containers get their own network namespace via slirp4netns, so their egress instead routes through the slirp4netns gateway at `10.0.2.2:8888`; the slirp4netns backend is pinned (podman 5.x's newer `pasta` default is not used) with `allow_host_loopback=true` so nested containers can reach that gateway. Non-allowlisted nested egress is blocked the same way as `--dind` (tinyproxy 403 + iptables) — same firewall/exfiltration bar.

A separate `devcontainer-pind` named volume (`/home/vscode/.local/share/containers`) preserves the nested image cache across rebuilds.

```bash
dev --pind -- /workspace/scripts/verify-firewall.sh   # 12 checks
dev --pind -- /workspace/scripts/verify-pind.sh       # heavier smoke tests
```

**Build tip:** `podman build`/`RUN` steps that need network access require the nested build to reach tinyproxy from inside the pind container's own netns. Pass `--network=host` plus **lowercase** proxy build args:

```bash
podman build --network=host \
  --build-arg http_proxy=http://127.0.0.1:8888 \
  --build-arg https_proxy=http://127.0.0.1:8888 \
  .
```

buildah (podman's build backend) only auto-forwards uppercase `HTTP_PROXY`/`HTTPS_PROXY`, which `apt` ignores — so without the lowercase `--build-arg`s, `RUN apt-get update` and similar steps fail to reach the network even though the host is fine.

## Persistence

Named volumes preserve state across container restarts and rebuilds:

- `devcontainer-mise:/mise` — installed tools and caches. Shared across every
  workspace.
- `devcontainer-home-<dir>:/home/vscode` — shell history, git config, SSH
  keys, dotfiles. **Per-workspace by default** (`<dir>` is the basename of
  the project directory `dev` was launched from), so one project's agent
  can't read another project's SSH keys or git credentials out of a shared
  home. Set `DEV_SHARED_HOME=1` to opt back into the legacy single
  `devcontainer-home` volume shared by every workspace.
- `devcontainer-dind` — nested image cache, added by `--dind`. Shared across
  every workspace, same as mise.
- `devcontainer-pind` — nested image cache, added by `--pind`. Shared across
  every workspace, same as mise. Mutually exclusive with `--dind`, so only
  one of the two volumes is ever mounted for a given workspace.

```bash
docker volume rm devcontainer-mise devcontainer-home-myproject
```

### Pushing from inside a container

Git identity (`user.name` / `user.email`) is seeded automatically from the
host's `git config` at container start, while the in-container identity is
still empty — you don't need to set it up by hand. It only fills in an *empty*
in-container identity, so anything you set inside the container later is
never overwritten by this seeding on subsequent starts.

SSH keys are deliberately **not** shared — the per-workspace home volume
starts empty, and even the legacy shared one is opt-in via
`DEV_SHARED_HOME=1`, not a substitute for key isolation. To push over SSH
from inside a container, forward your host's ssh-agent socket (or mount a
per-project deploy key) via `DEV_EXTRA_RUN_ARGS`, e.g.:

```bash
DEV_EXTRA_RUN_ARGS="-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent" ./dev
```

## Injecting agent credentials

`dev agent` copies a **curated** set of an AI coding agent's credentials and
settings from your host into this workspace's home volume, so the agent is
logged in and configured inside the sandbox without re-running its login flow.

```bash
dev agent add claude            # copy claude's creds+settings into this workspace
dev agent add claude opencode   # several at once
dev agent add all               # every agent detected on the host
dev agent add claude --dry-run  # preview the exact file list, copy nothing
dev agent add claude --pind     # target a --pind container's storage (also --dind)
dev agent list                  # per-agent: present on host? injected here?
dev agent rm claude             # remove claude's injected files (confirms)
```

Supported agents: `claude`, `opencode`, `pi`.

**Match the storage to the container you run (macOS+podman).** The dind/pind
container lives in a separate rootful podman connection with its **own** home
volume; writing into the default rootless volume it never mounts means the
credentials silently never appear inside. `dev agent` handles this for you:

- If a `dev --dind`/`--pind` container is **running**, `dev agent` auto-detects
  it and targets that storage — no flag needed.
- Otherwise pass the matching flag explicitly (`dev agent add claude --pind`),
  which also works for `list`/`rm` (`dev agent list --pind`) and always wins
  over auto-detection. If a workspace has dind/pind storage but no container is
  running, `dev agent` prints a reminder to pass the flag.

On Linux and Docker there is a single storage backend, so the flag is a
harmless no-op there.

**It is a one-way snapshot, not a mount.** Files are *copied* into the
per-workspace home volume (`devcontainer-home-<dir>`). The host's live
credential files are never bind-mounted, nothing is baked into an image, and
changes inside the container are never mirrored back to the host. Credentials
rotate, so re-run `dev agent add <name>` to refresh the snapshot.

**What is copied (curated allowlist):** each agent's auth file(s), its
settings/config, and its user-level customizations (global instructions,
commands, agents, skills, extensions). **What is deliberately excluded:**
conversation, project, and session history; caches; and plugin-install
machinery — so injecting an agent does not drag one project's history into
another's sandbox. Files holding secrets (auth tokens, and any config with
inline provider API keys) are forced to mode `0600` in the volume.

**Claude onboarding:** Claude Code's account/onboarding state lives in
`~/.claude.json` (a top-level file, *outside* `~/.claude/`) that also holds
cross-workspace project history, so it is never copied. Copying only the
credential file authenticates the API but leaves Claude's interactive
onboarding wizard (theme picker → *Select login method*) to reappear in every
fresh workspace. To avoid that, `dev agent add claude` synthesizes a single
`hasCompletedOnboarding: true` flag into the volume's `~/.claude.json` —
merged into any existing file, never overwriting accumulated state. Claude
re-derives your account identity from the copied token on first run. (The
one-time "trust this folder" prompt is a separate per-workspace safety check
and is left intact.)

**Claude credentials on macOS:** on a Mac, Claude Code stores its OAuth token
in the login **Keychain** (a generic password under the service
`Claude Code-credentials`), not in `~/.claude/.credentials.json` — so the file
the manifest points at does not exist. `dev agent add claude` detects this and
reads the token straight from the Keychain, writing it into the volume as
`.claude/.credentials.json` (mode `0600`), which is exactly the file Claude
reads inside the Linux container. `dev agent list` and `--dry-run` report it as
present on-host too. On Linux the credential lives on disk and is copied as-is,
so this fallback is inert there. (Reading the Keychain may raise a one-time
macOS "allow access" prompt.)

Copying **dereferences symlinks** found inside those customization dirs (a
broken link is skipped with a warning, not fatal) — keep dirs like
`.claude/skills/` free of links to sensitive host files, since those would
be copied into the volume as real file contents.

**Teardown:** `dev agent rm <name>` removes just that agent's files;
`dev reset` prompts to remove the whole home volume.

**Local (127.0.0.1) providers:** if your agent config points at a
host-side server (e.g. a local LLM at `http://127.0.0.1:PORT`), that address
means the container itself inside the sandbox. Start with
`dev --host-port PORT` and edit the in-volume config to use
`host.docker.internal:PORT` instead.

## Injecting dotfiles

`dev dotfile` is the generic counterpart to `dev agent`: it copies an
**arbitrary** host file or directory into this workspace's home volume,
mirroring its path relative to `$HOME`.

```bash
dev dotfile add ~/.config/nvim          # -> ~/.config/nvim in the container
dev dotfile add ~/.tmux.conf ~/.gitconfig   # several at once
dev dotfile add ~/.config/gh --secret   # chmod 600 the copied paths
dev dotfile rm  ~/.config/nvim          # remove it again (confirms)
```

Same mechanics as agent injection: a **one-way snapshot** into the
per-workspace home volume (`devcontainer-home-<dir>`) — never a host mount,
never baked into an image. Re-run `add` to refresh. **Symlinks are
dereferenced** — a linked config dir is copied as real files, so the container
never depends on a host path. The source path must live under `$HOME` (the
dest is computed relative to it); paths elsewhere, or ones resolving to unsafe
locations, are rejected. `--secret` forces the copied paths to mode `0600`.

Storage routing matches `dev agent` exactly: on macOS+podman a running
`dev --dind`/`--pind` container's storage is auto-detected, and `--dind`/`--pind`
target it explicitly. Remove with `dev dotfile rm <path>` or wipe the whole
home volume with `dev reset`.

## Host Requirements

- **Linux**: `docker` or `podman`. Docker is preferred when both are installed. Override with `DEV_RUNTIME=docker` or `DEV_RUNTIME=podman`.
- **macOS**: `podman` only — Docker Desktop is not supported.

  ```bash
  brew install podman
  podman machine init
  podman machine start
  ```

- **`--dind`/`--pind` on Ubuntu 23.10+ / Linux 6.x**: `dev` preflights `kernel.apparmor_restrict_unprivileged_userns`. If it's `1`:

  ```bash
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  echo 'kernel.apparmor_restrict_unprivileged_userns=0' \
    | sudo tee /etc/sysctl.d/99-rootless-userns.conf
  ```

  Set `DEV_SKIP_APPARMOR_CHECK=1` to bypass (e.g. with a custom AppArmor profile that grants `userns,`).

- **`--dind`/`--pind` on a rootless runtime needs a subuid/subgid grant of at least 165535 ids** (rootless podman, the `podman-docker` shim, rootless docker). The dind/pind container's user namespace only spans the ids granted in `/etc/subuid`/`/etc/subgid` — typically 65536 — but the rootless nested engine inside the container must map container ids 100000–165535 (the image's baked `vscode` subuid range), so with the typical grant it dies with `newuidmap: write to uid_map failed: Operation not permitted`. `dev` preflights the grant and refuses fast with the remediation:

  ```bash
  sudo usermod --add-subuids 165536-365535 --add-subgids 165536-365535 $USER
  podman system migrate   # podman only: restart its user namespace
  ```

  Set `DEV_SKIP_SUBID_CHECK=1` to bypass the preflight. Rootful runtimes are unaffected.

The script reads `id -u` / `id -g` and bakes them into the image. If your host UID/GID later changes, the next `dev` invocation detects the mismatch and prompts to rebuild + wipe volumes.

- **On rootless podman, `dev` runs the container with `--userns=keep-id`.** Rootless podman's default user-namespace mapping puts container root at the invoking host user and shifts every other container id — including the baked `vscode` uid — into the subuid/subgid range, so the baked-uid-matches-host-uid assumption above doesn't hold by default: the bind-mounted workspace shows up root-owned to `vscode`, who can't write to it. `--userns=keep-id` maps the invoking host user 1:1 onto the matching container id instead, fixing that. It only applies when the runtime is actually rootless podman (including the `podman-docker` shim) — Docker and rootful podman don't remap ids and don't need it. The first run after upgrading re-chowns the named volumes (`devcontainer-mise`, the resolved home volume — `devcontainer-home-<dir>` by default or `devcontainer-home` under `DEV_SHARED_HOME=1`, `devcontainer-dind`/`devcontainer-pind`), since their content was written under the old mapping; you'll see one `Migrating <volume> ownership for --userns=keep-id (one-time)...` line per volume, and nothing on subsequent runs.

## `dev` Flags

The authoritative flag reference is built into the script — it cannot drift
from the implementation:

```bash
dev --help
```

Highlights not covered above: `dev reset` removes this workspace's containers
and prompts per named volume; `dev update` updates a git-checkout install
to the latest tag; `dev scaffold` generates a `.devcontainer/` for
VS Code (`dev scaffold --pind` emits a pind-flavored one).

Note: the old flag spellings (`--disable-firewall`, `--enable-firewall`,
`--monitor`, `--monitor-fw`, `--reset`, `--self-update`,
`--create-dev-container`) still work as deprecated aliases — they print a
warning to stderr and route to the subcommand above.

### Environment variables

- `DEV_RUNTIME=docker|podman` — force a runtime when both are installed.
- `DEV_ASSUME_YES=1` — accept the rebuild prompts non-interactively (UID/GID mismatch also wipes named volumes; version mismatch rebuilds the image only). Also auto-approves `.devcontainer-allowlist` changes without the interactive diff/prompt, so setting it globally waives that review.
- `DEV_SHARED_HOME=1` — use the legacy shared `devcontainer-home` volume for
  every workspace instead of the per-workspace default
  (`devcontainer-home-<dir>`). See [Persistence](#persistence).
- `DEV_SKIP_APPARMOR_CHECK=1` — bypass the `--dind`/`--pind` AppArmor preflight.
- `DEV_SKIP_SUBID_CHECK=1` — bypass the `--dind`/`--pind` preflight that requires a rootless-runtime host to grant ≥165535 subuids/subgids.
- `DEV_EXTRA_RUN_ARGS=...` — extra args appended to `docker run`.
- `GITHUB_TOKEN` — passed through to the container if set on the host, and
  forwarded to image builds as a BuildKit secret. Its purpose is **rate-limit
  identification** (the anonymous GitHub API limit of 60 req/h is shared per
  IP and easily exhausted by `mise install`), so use a token with no power:
  create a **fine-grained PAT** with *no repository access* and *no
  permissions* (GitHub → Settings → Developer settings → Fine-grained tokens
  → "All repositories: none", zero permission grants). `dev` warns once per
  token if a classic token with OAuth scopes is detected — an agent inside
  the container can read the token, so scopes it carries are scopes you hand
  to the agent.

## Architecture

Three components:

- **Dockerfile** — Multi-stage build on `mcr.microsoft.com/devcontainers/base:ubuntu`. Bakes mise + base tools (node, ripgrep, eza, lazygit) into `/mise/`. The `dind` target adds rootless dockerd, fuse-overlayfs, slirp4netns; the `pind` target adds rootless podman, fuse-overlayfs, slirp4netns instead.
- **entrypoint.sh** — Runs on every container start. Sets up the firewall (or skips it in maintenance mode), runs `mise install` if a `mise.toml` is in `/workspace`, marks `/workspace` as a safe git directory, then `exec`s the shell.
- **dev** — Host-side wrapper. Manages container lifecycle: image build, container reuse, volume mounts, port forwarding, mode selection, firewall toggling.

The whole tool is those three files wired so an agent running as `vscode` can
code in a real container but cannot reach the network except through a filtered
gate. A run flows from your terminal to a locked-down shell like this:

```
  HOST  (runs as you)
  +---------------------------------------+   +---------------------------------------+
  | ./dev  -- lifecycle wrapper           |   | Dockerfile  -- image recipe           |
  |   * bakes UID/GID, builds the image   |   |   * mise + base tools  -> /mise       |
  |   * reuses the dev-<dir> container    |   |   * allowlist.base + firewall scripts |
  |   * mounts volumes, forwards ports    |   |   * stages entrypoint.sh + .zshrc     |
  |   * passes GITHUB_TOKEN + git ident   |   |                                       |
  |   * merges allowlists, picks a mode   |   |   Dockerfile  --build-->  image       |
  +---------------------------------------+   +---------------------------------------+
                     |
                     |  ./dev  ->  docker run
                     v
  +===================================================================================+   user: vscode, no sudo
  |                                                                                   |
  |  entrypoint.sh   (runs as root on start, then drops privilege)                    |
  |    1. firewall-init.sh   iptables OUTPUT->DROP, tinyproxy up, exports HTTPS_PROXY |
  |         |  [fails closed -- no firewall, no container]                            |
  |    2. mise install       installs tools from /workspace/mise.toml                 |
  |         |                                                                         |
  |    3. git config         marks /workspace safe; seeds git identity if unset       |
  |         |                                                                         |
  |    4. exec gosu vscode   your shell -- unprivileged, behind the wall              |
  |                                                                                   |
  |  persisted state:   devcontainer-mise -> /mise            (shared)                |
  |                     home-<dir>        -> /home/vscode      (per-project)          |
  |                     devcontainer-dind -> docker data       (dind only)            |
  |                     devcontainer-pind -> podman data       (pind only)            |
  |                     bind mount        -> ./ = /workspace   (your live code)       |
  |                                                                                   |
  |  -- the only way out is the gate ------------------------------------------       |
  |    [ok]   allowed   tinyproxy -> allowlisted host:443                             |
  |    [xx]   dropped   raw socket / off-allowlist host  (iptables owner rule)        |
  +===================================================================================+
```

Same wiring, four modes: `./dev` (firewall on, no sudo — the default),
`./dev --maintenance` (separate container, firewall off, sudo back on),
`./dev --dind` (adds rootless dockerd; nested pulls still routed through the
proxy), and `./dev --pind` (adds rootless podman instead; same routing,
daemonless engine).

A rendered version of this diagram lives at [`docs/architecture.html`](docs/architecture.html)
(open it in a browser).

## Tests

End-to-end suite under `scripts/test/` (needs passwordless `sudo`):

```bash
sudo bash scripts/test/run-all.sh
```

Builds both image targets, walks every script under `scripts/test/scenarios/`, and reports a pass/fail/skip table. Logs at `scripts/test/last-run.log` and `scripts/test/last-summary.log`.
