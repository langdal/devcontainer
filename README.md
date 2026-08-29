# Generic Devcontainer

A sandbox for running AI coding agents in auto mode without watching their
every move.

`dev up` from a project directory starts a disposable container with the
project mounted at `/workspace` and a clean, per-project home directory.
Your SSH keys, cloud credentials, `gh` login, and other projects stay on the
host — an agent inside can't push to origin, open issues under your name, or
leak secrets it was never given, because the material isn't there. It still
gets a full dev loop: per-project tools via [`mise`](https://mise.jdx.dev/),
nested Docker/Podman for testcontainers, and network access.

To log the agent itself in, `dev agent add claude` copies that agent's own
credentials and settings from the host into the container's home
(`claude`, `opencode`, and `pi` are supported) — a one-way snapshot; nothing
else from your host home comes along.

## Install

Requires Docker (Linux) or Podman (macOS/Linux) — see
[Host requirements](#host-requirements).

```bash
curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash
```

This clones into `${XDG_DATA_HOME:-~/.local/share}/devcontainer` and symlinks
`dev` onto your PATH. Pin a release with `REF=v1.0.0 curl ... | bash`;
override the location with `INSTALL_DIR=...`. Or install manually:

```bash
git clone https://github.com/langdal/devcontainer.git ~/devcontainer
~/devcontainer/dev install
```

Upgrade later with `dev update` (`--dry-run` to preview). It works for both
install methods, requires a clean git checkout, and the next `dev` run
prompts to rebuild the image if the script version changed.

## Getting started

```bash
cd ~/projects/my-project
dev up
```

The first run builds the image; you land in a Zsh shell at `/workspace` as
the unprivileged user `vscode`. Pin per-project tools with a `mise.toml` in
the project root — they install on every container start:

```toml
[tools]
node = "20"
go = "1.22"
python = "3.12"
```

If an agent should run inside, seed its login:

```bash
dev agent add claude    # or: opencode, pi, all
```

## Daily use

```bash
dev up                    # start or attach
dev exec -- npm test      # run one command inside
dev shell                 # extra shell in the running container
dev up --build            # rebuild the image
dev up --port 9000        # forward an extra port (repeatable)
dev up --default-ports    # forward 5173, 5174, 8080, 2345, 3000
dev up --host-port 8080   # let the container reach host.docker.internal:8080
dev fw log                # what has the container talked to?
dev fw close              # turn on outbound firewall (closed mode)
dev fw open               # turn off outbound firewall (open mode)
dev doctor                # check the host for everything dev needs
dev ls                    # every dev container + volume on this machine
dev reset                 # remove this workspace's containers/volumes
```

`dev --help` is the authoritative flag reference.

## What the agent can and can't do

Inside the container the agent edits, installs packages, runs tests, and
commits freely. It cannot:

- **read host secrets or other projects** — only the current project is
  mounted, and the home directory is a fresh per-workspace volume;
- **push** — no push credentials exist inside (opt in via
  [Pushing from inside a container](#pushing-from-inside-a-container)), so
  every outbound change passes through you running `git push`;
- **reach cloud metadata** — `169.254.0.0/16` and `fe80::/10` are dropped in
  every mode;
- **escalate** — no sudo, no path to disable the firewall from inside.
  Reshaping the sandbox (allowlist changes, egress toggles, maintenance mode)
  is always a host-side action.

Egress is **open** by default: outbound traffic works as on your host, and
`dev fw log` shows every host the container reached. `dev up --closed`
switches to default-deny with a curated hostname allowlist. Isolation, not
the allowlist, is the security boundary — closed mode narrows reach but is
not exfiltration prevention (an allowlisted host is fully reachable both
ways). Full threat model: [SECURITY.md](SECURITY.md).

## Container modes

One mode per workspace at a time (enforced).

| Mode             | Use for                                      | Container name    |
| ---------------- | -------------------------------------------- | ----------------- |
| Normal (default) | Day-to-day work. No sudo.                    | `dev-<dir>`       |
| `--maint`        | Installing system packages. Sudo, no firewall. | `dev-<dir>-maint` |
| `--dind`         | Nested Docker (testcontainers, builds).      | `dev-<dir>-dind`  |
| `--pind`         | Nested Podman (testcontainers, builds).      | `dev-<dir>-pind`  |

## Firewall

Egress mode resolution, most specific wins: `--open`/`--closed` flag on
`dev up`/`dev exec` → `DEV_EGRESS=open|closed` → built-in default (open).
`--maint` never runs a firewall.

- **Open** (default): iptables `OUTPUT` is ACCEPT apart from the always-on
  link-local/metadata drop. No proxy, no allowlist.
- **Closed**: iptables defaults `OUTPUT` to DROP; only the `proxy` user
  reaches :80/:443; `tinyproxy` filters HTTPS by hostname (clients get
  `HTTPS_PROXY=http://127.0.0.1:8888` from the entrypoint). Raw-socket
  bypasses by `vscode` are dropped by a kernel owner rule.

```bash
dev up --closed        # start closed (or: DEV_EGRESS=closed dev up)
dev fw open            # toggle a running container open, in place
dev fw close           # and back
dev fw log             # closed: tinyproxy hostname log; open: DNS + connection log
dev fw drops           # kernel-dropped packets (closed mode only)
```

Toggling does not rename the container, so nothing shows egress is currently
open — for longer unrestricted work prefer `--maint`, whose `-maint` name is
a visible signal. In open mode `dev fw log` reads an NFLOG feed: DNS query
names plus every new outbound connection (hostname and IP:port, not URLs).

Verify the posture from inside:

```bash
dev exec -- /workspace/scripts/verify-firewall.sh
```

### Allowlists (closed mode only)

One hostname per line, `#` comments; `*.example.com` matches subdomains
(list the bare host too if you need it).

- `allowlist.base` — baked into the image: Anthropic, GitHub, common
  registries, mise, OS mirrors. Edit and rebuild to change.
- `.devcontainer-allowlist` — optional, at the workspace root. The workspace
  is agent-writable, so the firewall never reads this file directly: on each
  start `dev` diffs it against the last approved copy and asks you to approve
  changes. Declined or non-interactive runs start without it. Restart (no
  rebuild) to pick up an approved change.
- `allowlist.dind` — merged additionally under `--dind`/`--pind` (Docker Hub,
  MCR, Quay, GCR, …).

The default allowlist is validated end-to-end against npm/yarn, pip/uv, Go
modules, cargo, Maven Central, NuGet, git/gh, mise installs, and Claude Code
as the in-container agent (login, model calls, WebSearch, plugins). Closed-mode
caveats:

- Claude's WebFetch only reaches allowlisted hosts (WebSearch always works —
  it runs server-side). Add documentation hosts to `.devcontainer-allowlist`
  as needed.
- Maven and Gradle ignore `HTTPS_PROXY`, so the entrypoint seeds
  `~/.m2/settings.xml` and `~/.gradle/gradle.properties` with the proxy on
  first run (never overwriting your edits).
- Telemetry endpoints stay blocked; tools work fine without them.

### Reaching a host service (e.g. local LLM)

`dev up --host-port 8080` (repeatable) makes `host.docker.internal:8080`
resolve and adds an iptables ACCEPT for only that port to the host gateway —
in closed mode everything else stays default-deny. The ACCEPT is installed
in *both* egress modes, before the always-on link-local block: podman ≥ 5's
pasta backend maps the gateway to a link-local address (`169.254.1.2`), so
without it the block would swallow the traffic even under open egress.
Prefer it over `--network host` or opening egress when an agent needs one
host-side service.

Don't map `host.docker.internal` in the **host's** `/etc/hosts` (e.g. to
`127.0.0.1`): podman seeds the container's `/etc/hosts` from the host's, and
the copied loopback entry shadows the real gateway mapping inside the
container — clients then talk to the container's own loopback instead of the
host. `dev` ignores loopback entries when punching the firewall hole, but it
cannot fix what address a client in the container picks first.

## Nested Docker / Podman

Run containers *inside* the container — testcontainers, image builds,
`docker compose` — without `--privileged` and behind the firewall.

```bash
dev up --dind    # rootless dockerd; real docker CLI
dev up --pind    # rootless podman, daemonless; docker CLI is a podman shim
```

In closed mode, nested registry pulls route through tinyproxy and the
allowlist (extended with `allowlist.dind`); in open mode they connect
directly. Loopback ports — the testcontainers pattern — work in either mode.
Nested image caches persist in the `devcontainer-dind` / `devcontainer-pind`
volumes.

Pind specifics: `docker` is the `podman-docker` shim and `docker-compose`
symlinks to the compose v2 plugin — not the real Docker CLI. Tooling that
speaks the Docker API directly (testcontainers, compose libraries) uses the
`podman system service` socket exported as `DOCKER_HOST`. In closed mode,
`podman build` steps that need network access must reach the proxy
explicitly — buildah only auto-forwards the uppercase proxy vars, which
`apt` ignores:

```bash
podman build --network=host \
  --build-arg http_proxy=http://127.0.0.1:8888 \
  --build-arg https_proxy=http://127.0.0.1:8888 \
  .
```

Smoke tests: `dev exec --dind -- /workspace/scripts/verify-dind.sh`
(or `--pind` + `verify-pind.sh`).

## Persistence

Named volumes survive container restarts and rebuilds:

- `devcontainer-mise:/mise` — installed tools and caches, shared across
  workspaces.
- `devcontainer-home-<dir>:/home/vscode` — shell history, git config,
  injected credentials. **Per-workspace** (`<dir>` = project directory
  basename), so one project's agent can't read another's. `DEV_SHARED_HOME=1`
  opts back into a single shared home volume.
- `devcontainer-dind` / `devcontainer-pind` — nested image caches, shared,
  mutually exclusive.

`dev ls` inventories every dev container and `devcontainer-*` volume on the
machine (not just this workspace's), marks the rows belonging to the current
directory, and calls out orphaned home volumes left behind by deleted
projects. It never removes anything; `dev reset` (from the project directory)
or `docker volume rm <name>` does. `dev ls --sizes` adds disk usage.

Two projects with the same directory basename share one home volume — the
volume name only records the basename.

### Pushing from inside a container

Git identity (`user.name`/`user.email`) is seeded from the host's git config
when the home volume is first created; anything you set inside later is never
overwritten. SSH keys are deliberately not shared. To push from inside,
forward your ssh-agent socket (or mount a per-project deploy key):

```bash
DEV_EXTRA_RUN_ARGS="-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent" dev up
```

## Injecting agent credentials

`dev agent` copies a curated set of an AI agent's credentials, settings, and
customizations (global instructions, commands, skills) from the host into
this workspace's home volume, so the agent is logged in without re-running
its login flow. Supported: `claude`, `opencode`, `pi`.

```bash
dev agent add claude            # copy creds+settings into this workspace
dev agent add claude opencode   # several at once
dev agent add all               # every agent detected on the host
dev agent add claude --dry-run  # preview the file list, copy nothing
dev agent list                  # per-agent: on host? injected here?
dev agent rm claude             # remove the injected files (confirms)
```

- **One-way snapshot, not a mount.** Host files are copied into the home
  volume, never bind-mounted or baked into an image; changes inside are
  never mirrored back. Re-run `add` after rotating credentials.
- **History is excluded.** Conversation/project/session history, caches, and
  plugin-install machinery are never copied, so one project's history can't
  leak into another's sandbox. Secret files are forced to mode `0600`.
- **Claude onboarding:** `~/.claude.json` holds cross-workspace history and
  is never copied wholesale; instead a single `hasCompletedOnboarding: true`
  is merged into the volume's copy so the onboarding wizard doesn't reappear
  per workspace.
- **Claude on macOS** stores its OAuth token in the login Keychain, not on
  disk; `dev agent add claude` reads it from there and materializes
  `~/.claude/.credentials.json` in the volume (may raise a one-time macOS
  "allow access" prompt).
- **macOS + podman with `--dind`/`--pind`:** those containers use separate
  storage. A running dind/pind container is auto-detected and targeted;
  otherwise pass the matching flag (`dev agent add claude --pind`). On
  Linux/Docker the flag is a no-op.
- **Symlinks are dereferenced** — keep dirs like `.claude/skills/` free of
  links to sensitive host files, or their contents get copied in.
- **Local providers:** a config pointing at `http://127.0.0.1:PORT` means the
  container itself once inside. Use `dev up --host-port PORT` and switch the
  in-volume config to `host.docker.internal:PORT`.

## Injecting dotfiles

`dev dotfile` is the generic counterpart: copy any host file or directory
under `$HOME` into the workspace's home volume, mirroring its path. Same
mechanics as `dev agent` — one-way snapshot, symlinks dereferenced, same
dind/pind storage routing.

```bash
dev dotfile add ~/.config/nvim          # -> ~/.config/nvim in the container
dev dotfile add ~/.config/gh --secret   # chmod 600 the copied paths
dev dotfile rm  ~/.config/nvim          # remove again (confirms)
```

## Host requirements

Run `dev doctor` — it checks everything below on your machine and prints the
fix for anything missing, before any image or container exists.
`dev doctor --dind` adds the nested-engine checks.

- **Linux:** `docker` or `podman` (docker preferred when both are installed;
  override with `DEV_RUNTIME=`).
- **macOS:** `podman` only — Docker Desktop is not supported.
  `brew install podman && podman machine init && podman machine start`.
- **`--dind`/`--pind` on Ubuntu 23.10+ / Linux 6.x:** requires
  `kernel.apparmor_restrict_unprivileged_userns=0`. `dev` preflights it and
  prints the `sysctl`/`sysctl.d` remediation if it's `1`
  (`DEV_SKIP_APPARMOR_CHECK=1` bypasses, e.g. with a custom AppArmor profile
  granting `userns,`).
- **`--dind`/`--pind` on a rootless runtime:** needs a subuid/subgid grant of
  at least 165535 ids — the typical 65536 grant is too small for the nested
  engine's own user namespace and fails with
  `newuidmap: write to uid_map failed`. `dev` preflights and prints:

  ```bash
  sudo usermod --add-subuids 165536-365535 --add-subgids 165536-365535 $USER
  podman system migrate   # podman only
  ```

`dev` bakes your `id -u`/`id -g` into the image so `vscode` owns the
bind-mounted workspace; if the host UID/GID later changes, the next run
detects the mismatch and prompts to rebuild and wipe volumes. On rootless
podman, which remaps ids, `dev` instead keeps `vscode` at uid 1000 and maps
your host user onto it with `--userns=keep-id:uid=1000,gid=1000`
(podman 4.3+; older podman falls back to baking the host uid with bare
`keep-id`). The first run after upgrading to this scheme re-chowns the named
volumes once and prompts to rebuild the image; if a volume ever ends up
unwritable inside, `dev down && dev up` re-triggers the migration.

## Environment variables

- `DEV_EGRESS=open|closed` — default egress mode when no `--open`/`--closed`
  flag is given. Ignored by `--maint`.
- `DEV_RUNTIME=docker|podman` — force a runtime when both are installed.
- `DEV_SHARED_HOME=1` — one shared home volume for every workspace instead of
  per-workspace homes.
- `DEV_ASSUME_YES=1` — accept rebuild prompts non-interactively; also
  auto-approves `.devcontainer-allowlist` changes, waiving that review.
- `DEV_SKIP_APPARMOR_CHECK=1` / `DEV_SKIP_SUBID_CHECK=1` — bypass the
  `--dind`/`--pind` preflights.
- `DEV_EXTRA_RUN_ARGS=...` — extra args appended to `docker run`.
- `GITHUB_TOKEN` — injected into the container and forwarded to image builds,
  purely to avoid GitHub's anonymous rate limit (60 req/h per IP, easily
  exhausted by `mise install`). Use a **fine-grained PAT with no repository
  access and no permissions**: 5000 req/h, grants the agent nothing. The
  injection is scope-guarded — a token carrying OAuth scopes prompts `[y/N]`
  first, since an agent inside can read it; non-TTY runs start without it.
- `DEV_GITHUB_TOKEN` — injected as `GITHUB_TOKEN` with no scope check or
  prompt. Use it to hand the agent real GitHub access on purpose (e.g. to
  push or open PRs).

## Architecture

Three roles: **`dev`** (host-side dispatcher over ~20 modules in
`lib/dev/*.sh`: image build, container lifecycle, volumes, ports, firewall
control, injection, host checks), the **Dockerfile** (multi-stage image on
`mcr.microsoft.com/devcontainers/base:ubuntu`, mise + base tools baked into
`/mise/`; `dind`/`pind` targets add the nested engines), and
**entrypoint.sh** (per start: bring up the firewall in the resolved mode,
`mise install`, git safe.directory + identity seed, then drop to `vscode`).

The diagram shows closed mode, the more involved egress path; open mode skips
the tinyproxy/`HTTPS_PROXY` plumbing and leaves the kernel gate at ACCEPT:

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

A rendered version lives at [`docs/architecture.html`](docs/architecture.html).

## Tests

End-to-end suite under `scripts/test/` (needs passwordless `sudo`):

```bash
sudo bash scripts/test/run-all.sh
```

Builds every image target, walks the scenarios under
`scripts/test/scenarios/`, and reports a pass/fail/skip table. Logs at
`scripts/test/last-run.log` and `scripts/test/last-summary.log`.
