# Generic Devcontainer

A development environment an AI coding agent can't break out of — and a complete one, so it doesn't need to.

Run `dev up` from a project directory and you (or an agent) land in a disposable Linux shell: the project mounted at `/workspace`, the right per-project tools via [`mise`](https://mise.jdx.dev/), and network access to what development actually needs. Everything else on the host — SSH keys, cloud credentials, other projects' code — is physically out of reach: no host mounts beyond this one project, a per-workspace home volume, an unprivileged user with no sudo. The point isn't just a shell, it's the whole edit-build-test-run loop: install a dependency, spin up Postgres/Keycloak/Redis via nested Docker or Podman, run the tests, fix the failure, commit — a bare `docker run -v $PWD:/work` can't safely hand you that.

```bash
curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash
cd your-project && dev up
```

That's the whole install. See [Getting Started](#getting-started) for pinning a release, manual install, and first-run details.

Two things worth knowing going in:

- **The agent closes the code loop; the human owns the environment loop.** Inside the container the agent can install packages, edit, run, and iterate freely — but it can't reshape its own cage. Extending the allowlist, switching egress modes, disabling the firewall, and pushing to a remote are each a deliberate action taken from *outside* the container, by a human.
- **Commit inside, push outside, is a review gate.** There are no push credentials inside the container (see [Pushing from inside a container](#pushing-from-inside-a-container) if you want to change that) — so every outbound change to your repos passes through a human running `git push`.

**Egress observability is a headline feature, not an afterthought.** `dev up`'s default posture is *open* egress — no allowlist, no proxy, outbound traffic just works, so day-to-day tooling doesn't hit 403s. What replaces confinement-by-default is transparency: `dev fw log` shows every host the container reached, DNS query names and live connections alike, so you can run an agent wide open and still see exactly what it talked to — you don't have to lock it down to get visibility. Want the old default-deny + curated-allowlist posture back for a given project or run? `dev up --closed`. See [Firewall](#firewall).

## What you get

- **A real dev container in one command.** `dev up` from any project folder lands you in a shell with your code mounted at `/workspace`. No per-project config files to write or maintain.
- **Per-project tool versions, no clutter.** Drop a `mise.toml` in your repo to pin node/go/python/etc. Tools install on start and cache in a shared volume — not in your home directory.
- **Open egress by default, observable either way.** Outbound traffic is unrestricted out of the box; `dev up --closed` opts into a hostname-allowlist firewall instead. `dev fw log` shows what the container reached in either mode. See [Firewall](#firewall).
- **State that stays isolated.** Shell history, git config, and dotfiles live in a per-project home volume, so one project's agent can't read another project's SSH keys or credentials.
- **Escape hatches when you need them.** A maintenance mode (`--maint`: sudo, no firewall), nested Docker or Podman for testcontainers and builds, and scoped access to host services — each opt-in and clearly named.

## How it stays safe

The boundary is **isolation**, not egress filtering, and it doesn't change with the egress mode. The container runs as an unprivileged user (`vscode`) with **no sudo**; it mounts only the current project, never the rest of the host; state (shell history, git config, SSH keys) lives in a per-workspace volume other projects can't read; and a link-local/cloud-metadata block (`169.254.0.0/16`, `fe80::/10`) is always on regardless of mode. None of that requires a closed firewall to hold. Egress confinement — the [Firewall](#firewall) section, opt-in via `--closed` — is an *additional* hardening layer for projects that want a reviewed allowlist instead of the open default; it narrows which hosts are reachable, it does not add exfiltration prevention (an allowlisted host is still fully, bidirectionally reachable).

`dev` itself is a thin dispatcher over roughly 20 `lib/dev/*.sh` modules, plus the Dockerfile and entrypoint.sh — see [How it works](#how-it-works) for the shape and [SECURITY.md](SECURITY.md) for the full threat model and reading order, or [`docs/architecture.html`](docs/architecture.html) for a picture.

## How it works

Three components, each with a distinct role — not three files; `dev` alone is a router over ~20 library modules under `lib/dev/`:

- **`dev`** — the host-side wrapper you run. Builds the image, starts/reuses the container, mounts volumes, forwards ports, picks the container mode and resolves the egress mode.
- **Dockerfile** — the image recipe. Ubuntu base + `mise` and a few baked-in tools; separate targets add nested Docker/Podman.
- **entrypoint.sh** — runs on every start: brings up the firewall (open or closed), installs project tools, then drops to your shell as `vscode`.

Jump to [Architecture](#architecture) for the full diagram.

## Getting Started

You need Docker (Linux) or Podman (macOS/Linux). See [Host requirements](#host-requirements).

### Install

The one-liner in the [top section](#generic-devcontainer) clones into
`${XDG_DATA_HOME:-~/.local/share}/devcontainer` and symlinks the `dev` script
onto your PATH.

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
dev up
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
dev up                    # start or attach to the container
dev exec -- npm test      # run a one-off command in the container
dev up --build            # rebuild the image
dev up --port 9000        # forward an extra port (repeatable)
dev up --default-ports    # forward 5173, 5174, 8080, 2345, 3000
dev up --host-port 8080   # allow egress to host.docker.internal:8080
dev doctor                # check this host for everything dev needs
dev doctor --dind         # also check nested-engine prerequisites
```

Multiple terminals: run `dev shell` to attach another shell to the running container (`dev up` also attaches when one is already running).

## Container Modes

Only one mode runs per workspace at a time. The script enforces this with a four-way conflict guard.

| Mode             | When to use                                        | Container name      |
| ---------------- | -------------------------------------------------- | ------------------- |
| Normal (default) | Day-to-day work. Open egress by default, no sudo.  | `dev-<dir>`         |
| `--maint`        | Install system packages, no firewall at all.       | `dev-<dir>-maint`   |
| `--dind`         | Run nested Docker (testcontainers, builds).        | `dev-<dir>-dind`    |
| `--pind`         | Run nested Podman (testcontainers, builds).        | `dev-<dir>-pind`    |

```bash
dev up --maint            # no firewall, sudo enabled
dev up --dind             # rootless dockerd inside the container
dev up --pind             # rootless podman inside the container
```

## Firewall

`dev up` defaults to **open** egress: no allowlist, no proxy, outbound traffic
just works, the same way it would on your host. What protects the host is
[isolation](#how-it-stays-safe) (unchanged by egress mode), not a hostname
filter — so opening egress by default doesn't weaken anything. Egress
confinement is opt-in **closed** mode: a curated hostname allowlist, for
projects or runs that want a reviewed, narrower surface. Neither mode is
exfiltration prevention: an allowlisted host stays fully bidirectionally
reachable, and open mode doesn't filter destinations at all. For the full
threat model, start at [SECURITY.md](SECURITY.md).

Mode resolution, most specific wins: an explicit `--open`/`--closed` flag on
`dev up`/`dev exec`, else the `DEV_EGRESS=open|closed` host environment
variable, else the built-in default of **open**. `dev up --maint` ignores
egress mode entirely — maintenance mode never runs a firewall.

```bash
dev up                 # open egress (default)
dev up --closed        # closed egress: allowlist + default-deny iptables
DEV_EGRESS=closed dev up   # same, set once for every invocation on this host
```

One block holds in **every** mode, including open: `169.254.0.0/16` (v4) and
`fe80::/10` (v6) — the cloud-metadata / link-local range — is always
dropped on `OUTPUT`, closing the one network path to host instance
credentials regardless of egress posture.

**Closed mode mechanics** (unchanged from before the open-default flip):

- iptables defaults `OUTPUT` to DROP. Only the `proxy` user can reach :80/:443.
- `tinyproxy` filters HTTPS by hostname (CONNECT). Clients honour `HTTPS_PROXY=http://127.0.0.1:8888`, exported by the entrypoint.
- `vscode` has no sudo in normal mode — there is no path to disable iptables from inside.

**Open mode mechanics:** iptables `OUTPUT` policy is `ACCEPT` (after the
always-on link-local DROP above) — no proxy, no allowlist, any port or
protocol. See [Egress observability](#egress-observability) for how it stays
watchable anyway.

### Allowlist files

Closed mode only — open mode doesn't consult these. One entry per line, `#` for comments. Bare hostnames match exactly; `*.example.com` matches any subdomain (list both if you need both).

- `allowlist.base` — baked into the image. Anthropic, GitHub, common registries, mise, OS mirrors. Edit and rebuild to change.
- `.devcontainer-allowlist` at the workspace root — optional, project-specific.
  Because the workspace is writable by the sandboxed agent, `dev` never feeds
  this file to the firewall directly: on start it diffs the file against the
  last **approved** copy (kept under `~/.local/state/devcontainer/`) and asks
  you to approve changes. Declined or non-interactive runs start *without*
  the project allowlist. Restart to pick up an approved change (no rebuild
  needed). Note: the approval gate itself is enforced by the baked
  `firewall-init.sh`, so it only applies on an image built with this version
  of the tooling — on an older image, run `dev up --build` once.
- `allowlist.dind` — additionally merged in `--dind` mode (Docker Hub, MCR, Quay, GCR, …). `--pind` reuses this same file — there is no separate `allowlist.pind` — since both nested engines pull from the same registries.

### What works out of the box

In closed mode, the default allowlist is validated end-to-end against the
mainstream dev workflows (probe suite run inside the firewalled container):
npm/yarn, pip/uv (mise-managed Python), Go modules, cargo (sparse index),
Maven Central, NuGet/.NET, git/gh against GitHub, mise toolchain installs,
and Claude Code as the in-container agent harness (login, model calls,
WebSearch, plugin marketplace). In open mode (the default) none of this is
filtered in the first place.

Known caveats, closed mode only unless noted:

- **Claude's WebFetch of arbitrary URLs is confined to the allowlist in
  closed mode.** WebSearch always works (it runs server-side via the
  Anthropic API, in either egress mode). In **open mode (the default)**,
  WebFetch can reach any host the container can, same as the host. In
  closed mode it's confined to allowlisted hosts — add project-specific
  documentation hosts to `.devcontainer-allowlist` if you need them there.
- **JVM tools ignore `HTTPS_PROXY`, but this only matters in closed mode.**
  Closed mode routes everything through a local proxy; Maven and Gradle
  don't honor the env var, so without explicit proxy config their downloads
  bypass it and the kernel silently drops them. The first time each file is
  absent, entrypoint.sh seeds `~/.m2/settings.xml` and
  `~/.gradle/gradle.properties` with a `127.0.0.1:8888` proxy entry — nothing
  to configure by hand, and it never overwrites a file you've since edited.
  Open mode has no proxy in the loop, so neither file is seeded there and
  none of this applies.
- **Telemetry endpoints are left blocked in closed mode** (e.g. .NET CLI's
  `dc.services.visualstudio.com`, Claude Code's Datadog log intake). Tools
  work fine without them. Open mode doesn't block them, or anything else.

### Firewall controls

```bash
dev fw open       # open egress on the running container, in place
dev fw close      # restore default-deny + allowlist on the running container
dev fw log        # show what the container has reached
dev fw drops      # tcpdump on iptables-dropped packets (NFLOG group 1)
```

`dev fw open`/`dev fw close` toggle an already-running workspace container
(normal, dind, or pind) in place; both error if none is running. To start a
**fresh** container in a given mode instead, use `dev up --open` /
`dev up --closed` (or `DEV_EGRESS`) — same end state as starting normally
and then toggling.

The container name does **not** change when egress mode is toggled, so for
longer-lived unrestricted work needing sudo too, prefer `--maint` — its name
(`-maint`) is a visible signal that something out of the ordinary is running.

#### Egress observability

`dev fw log` is mode-aware, but shows you something useful either way:

- **Open mode (the default):** no proxy log to tail, so it shows the
  kernel-level view instead — a single NFLOG group-2 feed carrying both DNS
  query names (which hosts the container looked up) and a live connection
  log (IP:port for every new outbound TCP connection, including literal IPs
  a DNS log alone would miss), read with one `tcpdump -i nflog:2`. NFLOG
  only needs `CAP_NET_ADMIN`, which the container already has for iptables —
  no `CAP_NET_RAW` capture required. That's the ceiling without terminating
  TLS — hostname and IP:port, not full URLs or request bodies — but it's
  enough to answer "what did the agent talk to just now" without confining
  it first.
- **Closed mode:** tails the tinyproxy log, the richer per-request hostname
  audit trail closed mode has always produced.

`dev fw drops` is closed-mode territory: it tails the NFLOG group that logs
packets the default-DROP policy discarded. Open mode's link-local block is
silent (no NFLOG rule is attached to it), so `dev fw drops` has nothing to
show there — `dev fw log`'s connection log is the source of truth for what
happened in open mode.

### Reaching a host service (e.g. local LLM)

`dev up --host-port 8080` (repeatable) is a scoped escape hatch for talking to a service on the Docker host. It:

- adds `--add-host=host.docker.internal:host-gateway` so the hostname resolves to the host gateway IP,
- passes `DEVCONTAINER_HOST_PORTS=8080[,…]` into the container,
- and, in **closed** mode, `firewall-init.sh` adds an iptables `ACCEPT` rule for **only that port to that gateway IP**.

In **closed** mode, everything else stays default-deny — this is the scoped way to reach one host-side service without opening egress entirely. Use it instead of `--network host` or `dev fw open` when an agent needs to call out to a local model server, a metrics endpoint, etc. In **open** mode (the default) the host gateway is already reachable like any other host, so `--host-port` is mainly useful for `--closed` runs, or to add a stable `host.docker.internal` hostname. From inside the container: `curl http://host.docker.internal:8080/...`.

To verify the firewall posture from inside:

```bash
dev exec -- /workspace/scripts/verify-firewall.sh
```

## Docker-in-Docker

Run a rootless `dockerd` inside the container — for the `docker` CLI, testcontainers, and image builds — without `--privileged` and without breaking the firewall.

```bash
dev up --dind
docker ps   # nested daemon
```

In **closed** mode, registry pulls flow through tinyproxy and are filtered
against the same allowlist machinery (extended with `allowlist.dind`); nested
containers' outbound traffic still appears to the host iptables as
originating from `vscode`, which the owner-rule blocks. In **open** mode (the
default), there's no tinyproxy in the loop for nested pulls either — the
nested daemon and its containers connect directly, same as the main
container. Loopback ports (the testcontainers pattern) work as expected in
either mode.

A separate `devcontainer-dind` named volume preserves the nested image cache across rebuilds.

```bash
dev exec --dind -- /workspace/scripts/verify-firewall.sh   # 14 checks
dev exec --dind -- /workspace/scripts/verify-dind.sh       # heavier smoke tests
```

## Podman-in-Podman

Run rootless `podman` inside the container — for image builds, testcontainers, and `docker`/`docker compose`-shaped tooling — without `--privileged` and without breaking the firewall. Unlike `--dind`, podman is daemonless: there's no background process, just the `podman` binary and (optionally) a Docker-API compat socket.

```bash
dev up --pind
podman ps   # nested engine
docker ps   # podman-docker shim; talks to the same engine
```

Docker CLI compatibility comes from the `podman-docker` package (`/usr/bin/docker` → `podman`) plus a `docker-compose` symlink to the compose v2 plugin — it is **not** the real Docker CLI, just enough of the surface for `docker`/`docker compose` invocations to work. For tooling that speaks the Docker API directly (testcontainers, `docker-compose` libraries), a `podman system service` unix socket at `/home/vscode/.pind-run/podman.sock` is exported as `DOCKER_HOST`.

In **closed** mode, registry pulls for podman's own images route through tinyproxy at `127.0.0.1:8888` in the container's main network namespace and are filtered against the same allowlist machinery (extended with `allowlist.dind` — there is no separate `allowlist.pind`, since both nested engines pull from the same registries). Nested containers get their own network namespace via slirp4netns, so their egress instead routes through the slirp4netns gateway at `10.0.2.2:8888`; the slirp4netns backend is pinned (podman 5.x's newer `pasta` default is not used) with `allow_host_loopback=true` so nested containers can reach that gateway. Non-allowlisted nested egress is blocked the same way as `--dind` (tinyproxy 403 + iptables). In **open** mode (the default), there is no tinyproxy listening — podman's own pulls and nested containers' egress both connect directly, same as the main container.

A separate `devcontainer-pind` named volume (`/home/vscode/.local/share/containers`) preserves the nested image cache across rebuilds. Like the other named volumes, it's covered by the rootless-podman `--userns=keep-id` ownership migration (see [Host requirements](#host-requirements)) — a `devcontainer-pind` volume written before that migration existed gets re-chowned automatically on first use with it.

```bash
dev exec --pind -- /workspace/scripts/verify-firewall.sh   # 14 checks
dev exec --pind -- /workspace/scripts/verify-pind.sh       # heavier smoke tests
```

**Build tip (closed mode only):** in closed mode, `podman build`/`RUN` steps that need network access require the nested build to reach tinyproxy from inside the pind container's own netns. Pass `--network=host` plus **lowercase** proxy build args:

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
DEV_EXTRA_RUN_ARGS="-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent" ./dev up
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

- If a `dev up --dind`/`--pind` container is **running**, `dev agent` auto-detects
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
`dev up --host-port PORT` and edit the in-volume config to use
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
`dev up --dind`/`--pind` container's storage is auto-detected, and `--dind`/`--pind`
target it explicitly. Remove with `dev dotfile rm <path>` or wipe the whole
home volume with `dev reset`.

## Host Requirements

Run `dev doctor` — it checks every requirement below on your actual machine
and prints the fix for anything missing. It needs no image, no container and
no running podman machine, so it works before anything is set up.

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

- **On rootless podman, `dev` runs the container with `--userns=keep-id`.** Rootless podman's default user-namespace mapping puts container root at the invoking host user and shifts every other container id — including the baked `vscode` uid — into the subuid/subgid range, so the baked-uid-matches-host-uid assumption above doesn't hold by default: the bind-mounted workspace shows up root-owned to `vscode`, who can't write to it. `--userns=keep-id` maps the invoking host user 1:1 onto the matching container id instead, fixing that. It only applies when the runtime is actually rootless podman (including the `podman-docker` shim) — Docker and rootful podman don't remap ids and don't need it. The first run after upgrading re-chowns the named volumes (`devcontainer-mise`, the resolved home volume — `devcontainer-home-<dir>` by default or `devcontainer-home` under `DEV_SHARED_HOME=1`, `devcontainer-dind`/`devcontainer-pind`), since their content was written under the old mapping; you'll see one `Migrating <volume> ownership for --userns=keep-id (one-time)...` line per volume, and nothing on subsequent runs. If a volume somehow ends up with the wrong owner anyway — `$HOME` or `/mise` unwritable inside the container — `dev down` then `dev up` re-triggers this migration.

## `dev` Flags

The authoritative flag reference is built into the script — it cannot drift
from the implementation:

```bash
dev --help
```

Highlights not covered above: `dev reset` removes this workspace's containers
and prompts per named volume; `dev update` updates a git-checkout install
to the latest tag.

### Environment variables

- `DEV_EGRESS=open|closed` — default egress mode for `dev up`/`dev exec` when neither `--open` nor `--closed` is given (default: `open`). An explicit flag always wins over this; any other value is an error. Ignored under `--maint`, which never runs a firewall. See [Firewall](#firewall).
- `DEV_RUNTIME=docker|podman` — force a runtime when both are installed.
- `DEV_ASSUME_YES=1` — accept the rebuild prompts non-interactively (UID/GID mismatch also wipes named volumes; version mismatch rebuilds the image only). Also auto-approves `.devcontainer-allowlist` changes without the interactive diff/prompt, so setting it globally waives that review.
- `DEV_SHARED_HOME=1` — use the legacy shared `devcontainer-home` volume for
  every workspace instead of the per-workspace default
  (`devcontainer-home-<dir>`). See [Persistence](#persistence).
- `DEV_SKIP_APPARMOR_CHECK=1` — bypass the `--dind`/`--pind` AppArmor preflight.
- `DEV_SKIP_SUBID_CHECK=1` — bypass the `--dind`/`--pind` preflight that requires a rootless-runtime host to grant ≥165535 subuids/subgids.
- `DEV_EXTRA_RUN_ARGS=...` — extra args appended to `docker run`.
- `GITHUB_TOKEN` — injected into the container if set on the host, and
  forwarded to image builds as a BuildKit secret. Its purpose is **rate-limit
  identification** (see the note below). It is **scope-guarded**: a
  no-permission fine-grained PAT or a classic token with zero scopes is
  injected silently, but a classic token that carries OAuth scopes prompts
  `[y/N]` before it is handed to the agent — an agent inside the container can
  read the token, so scopes it carries are scopes you hand to the agent.
  `DEV_ASSUME_YES=1` auto-approves; a non-TTY or `--dry-run` run starts
  *without* the token (fail-safe). A token whose scopes can't be verified
  (offline / probe failed) is injected anyway.
- `DEV_GITHUB_TOKEN` — explicit opt-in that injects its value as `GITHUB_TOKEN`
  with **no scope check and no prompt**, taking precedence over an ambient
  `GITHUB_TOKEN`. Setting a `DEV_`-prefixed variable is itself the act of
  intent, so a broader-scoped token here is legitimate — use it to hand the
  agent GitHub access on purpose (e.g. to let it push or open PRs).

> **NOTE:** To avoid GitHub's anonymous API rate limit (60 req/h, shared per
> IP and easily exhausted by `mise install`), give the container a token
> purely for identification. The safest choice is a **fine-grained PAT with
> no repository access and no permissions** (GitHub → Settings → Developer
> settings → Fine-grained tokens → "All repositories: none", zero permission
> grants): it raises the limit to 5000 req/h and grants the agent nothing.
> Export it as `GITHUB_TOKEN` (injected silently, since it carries no scopes),
> or as `DEV_GITHUB_TOKEN` if you also want to hand the agent a token with
> real access on purpose.

## Architecture

Three components, wired together — but "component" here means a role, not a
file: `dev` alone is a thin dispatcher over roughly 20 modules under
`lib/dev/*.sh` (container lifecycle, volumes, firewall control, agent/dotfile
injection, host checks, and more), not a single script.

- **Dockerfile** — Multi-stage build on `mcr.microsoft.com/devcontainers/base:ubuntu`. Bakes mise + base tools (node, ripgrep, eza, lazygit) into `/mise/`. The `dind` target adds rootless dockerd, fuse-overlayfs, slirp4netns; the `pind` target adds rootless podman, fuse-overlayfs, slirp4netns instead.
- **entrypoint.sh** — Runs on every container start. Brings up the firewall in the resolved egress mode (or skips it entirely in maintenance mode), runs `mise install` if a `mise.toml` is in `/workspace`, marks `/workspace` as a safe git directory, then `exec`s the shell.
- **dev** — Host-side dispatcher. Resolves the container mode and the egress mode, then manages container lifecycle: image build, container reuse, volume mounts, port forwarding, firewall toggling.

An agent running as `vscode` gets a real container to work in, isolated from
the rest of the host regardless of egress mode (see
[How it stays safe](#how-it-stays-safe)). A run flows from your terminal to
that shell like this — the diagram shows **closed** mode, the more involved
of the two egress paths; open mode skips step 1's tinyproxy/`HTTPS_PROXY`
plumbing entirely and leaves the kernel gate at ACCEPT instead of DROP:

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
  |    1. firewall-init.sh   [closed] iptables OUTPUT->DROP, tinyproxy up,            |
  |                          HTTPS_PROXY exported; [open] OUTPUT->ACCEPT, no proxy -- |
  |                          link-local/metadata block installed either way           |
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
  |  -- egress, closed mode shown --------------------------------------------------- |
  |    [ok]   allowed   tinyproxy -> allowlisted host:443                             |
  |    [xx]   dropped   raw socket / off-allowlist host  (iptables owner rule)        |
  |    (open mode: everything above is [ok] except link-local/metadata, still [xx])   |
  +===================================================================================+
```

Same wiring, four container modes crossed with two egress modes: `./dev up`
(open egress by default, no sudo), `./dev up --closed` (allowlist + iptables
default-deny instead), `./dev up --maint` (separate container, no firewall at
all, sudo back on — egress mode is irrelevant here), `./dev up --dind` (adds
rootless dockerd; nested pulls route through the proxy in closed mode, direct
in open mode), and `./dev up --pind` (adds rootless podman instead; same
routing story, daemonless engine).

A rendered version of this diagram lives at [`docs/architecture.html`](docs/architecture.html)
(open it in a browser).

## Tests

End-to-end suite under `scripts/test/` (needs passwordless `sudo`):

```bash
sudo bash scripts/test/run-all.sh
```

Builds both image targets, walks every script under `scripts/test/scenarios/`, and reports a pass/fail/skip table. Logs at `scripts/test/last-run.log` and `scripts/test/last-summary.log`.
