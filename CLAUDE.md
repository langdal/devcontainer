# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Rules for Claude

- You may create commits when the user asks for them.
- If the repo requires GPG-signed commits and signing fails because no key/agent is available (typical inside this devcontainer or any other sandbox), assume you are running in a sandbox and commit **without** signing (e.g. `git -c commit.gpgsign=false commit ...`). The user will re-sign retroactively later.
- You are **NEVER** allowed to `git push` (including `--force`, tags, or any remote-affecting variant). Stop and leave the commit local even if the user previously authorized a push in another turn — re-ask each time.
- When you finish an implementation without committing, end the summary with a proposed one-line commit message in [Conventional Commits](https://www.conventionalcommits.org/) style (`type(scope): subject`, ~72 char max, imperative mood). This repo uses release-please, so the type drives the next version bump — pick `feat:` for user-visible additions, `fix:` for bug fixes, `chore:`/`docs:`/`refactor:`/`test:`/`ci:` for non-shipping changes. Format as a fenced bash block so the user can copy it directly.

## Project Overview

A portable, editor-agnostic development container using a plain Dockerfile and a `dev` bash wrapper script. Uses `mise` for per-project tool management. No devcontainer.json, no docker-compose, no editor-specific config.

## Build and Run

```bash
# Build the image
docker build -t generic-devcontainer .

# Start/attach to container (from any project directory).
# ./dev reads `id -u`/`id -g` and bakes them into the image automatically;
# no manual --build-arg is needed on macOS or Linux.
./dev up

# Run a command inside the container
./dev exec -- npm run dev

# Force rebuild (also triggered automatically on UID/GID mismatch)
./dev up --build

# Maintenance shell (firewall off, sudo enabled) — for installing system
# packages or fetching from non-allowlisted hosts. Container is named
# dev-<dir>-maint and is mutually exclusive with the normal/dind containers.
./dev up --maint

# Rootless Docker-in-Docker (separate :dind image, dev-<dir>-dind container).
./dev up --dind

# Rootless Podman-in-Podman (separate :pind image, dev-<dir>-pind container).
# Daemonless engine; exposes a Docker-API compat socket (DOCKER_HOST) for
# testcontainers / docker-compose. Mutually exclusive with --dind and
# --maint.
./dev up --pind

# dev up defaults to OPEN egress (no allowlist, no proxy). Add --closed (or
# set DEV_EGRESS=closed) to opt into the old default-deny + allowlist
# posture instead. `fw open`/`fw close` toggle an already-running
# container's egress mode in place without restarting; to start a FRESH
# container in a given mode instead, use `./dev up --open`/`--closed`.
./dev fw open
./dev fw close

# Observe egress on a running container, either mode:
./dev fw log     # closed mode: tail tinyproxy.log; open mode: DNS + connection log
./dev fw drops   # tcpdump on NFLOG group 1 (iptables drops; closed mode only)

# Remove this workspace's dev container(s) and prompt per named volume.
./dev reset

# Inject a curated snapshot of an AI agent's host credentials + settings
# into this workspace's home volume (claude/opencode/pi). One-way copy,
# not a mount; re-run to refresh. `list` shows status; `rm` removes.
./dev agent add claude
./dev agent list
./dev agent rm claude

# Inject an arbitrary dotfile/dir into this workspace's home volume, mirroring
# its path under $HOME (symlinks dereferenced). Generic counterpart to `agent`;
# same one-way-snapshot + dind/pind storage routing. --secret forces mode 0600.
./dev dotfile add ~/.config/nvim
./dev dotfile rm ~/.config/nvim

# Update a git-checkout install to the latest released tag.
./dev update

# Check the host for everything dev needs (no image or container required).
./dev doctor
```

Useful environment variables for `./dev`:

- `DEV_RUNTIME=docker|podman` — force a runtime when both are installed (default: docker preferred on Linux; podman only on macOS).
- `DEV_EGRESS=open|closed` — default egress mode for `dev up`/`dev exec` when neither `--open` nor `--closed` is given (default: `open`). Precedence: an explicit `--open`/`--closed` flag beats `DEV_EGRESS` beats the built-in `open` default; any other value is an error. Ignored under `--maint`, which never runs a firewall.
- `DEV_ASSUME_YES=1` — accept the rebuild prompts non-interactively. Covers the UID/GID mismatch prompt (which also wipes named volumes) and the dev-script version mismatch prompt (image rebuild only, volumes untouched). Also auto-approves `.devcontainer-allowlist` changes without the interactive diff/prompt, so setting it globally waives that review.
- `DEV_SKIP_APPARMOR_CHECK=1` — bypass the `--dind`/`--pind` AppArmor preflight (only safe with a custom profile that grants `userns,`).
- `DEV_SKIP_SUBID_CHECK=1` — bypass the `--dind`/`--pind` preflight that requires a rootless-runtime host to grant ≥165535 subuids/subgids (rootless dockerd/podman must map the image's `vscode:100000:65536` range inside the container's user namespace; the typical 65536-id grant is too small).
- `DEV_EXTRA_RUN_ARGS=...` — extra args passed to `docker run` (the test orchestrator uses this to inject `--dns=...` when in-container DNS is broken).
- `DEV_SHARED_HOME=1` — use the legacy shared `devcontainer-home` volume for every workspace instead of the per-workspace default (`devcontainer-home-<dir>`).

## Tests

There is an automated end-to-end test suite under `scripts/test/`:

```bash
# Full matrix, rootful docker. Needs passwordless sudo.
sudo bash scripts/test/run-all.sh

# The unprivileged subset under rootless podman. No sudo anywhere.
bash scripts/test/run-rootless.sh

# Run one scenario directly (each script under scenarios/ is self-contained
# and uses helpers from scripts/test/lib/). Pass/fail is determined by
# log_pass/log_fail/log_skip lines; any [FAIL] line fails the scenario,
# whatever else it printed.
bash scripts/test/scenarios/22-cold-start-budget.sh
```

Scenarios declare what they need in front-matter, and the orchestrator
filters on it:

```bash
# platform: linux        # linux | darwin | any
# privilege: root        # root = changes HOST state (sysctls, AppArmor,
                         # package installs, device nodes); user = needs
                         # only a working runtime
```

`DEV_TEST_PRIVILEGE=user` runs only the `user` subset and requires no sudo;
unset means "run everything". 9 of the 40 scenarios are `root`.

Two cells, two baselines on the dev host, both measured with `GITHUB_TOKEN`
set — without it the numbers are not reproducible, for the reason below.
Compare the failure SET, not just the tally: a run can hit the same count
with a different set.

| Cell | Command | Baseline |
| --- | --- | --- |
| rootful docker | `sudo --preserve-env=GITHUB_TOKEN bash scripts/test/run-all.sh` | 24 passed / 10 failed / 6 skipped |
| rootless podman | `bash scripts/test/run-rootless.sh` | 17 passed / 10 failed / 4 skipped |

Re-measured 2026-08-16. Every failure in both is environmental, not a defect,
and it is now the same story in each cell: exactly 10 failures, all tracing to
`kernel.apparmor_restrict_unprivileged_userns=1` on this host, which blocks
the rootless nested engines that every `--dind`/`--pind` scenario needs.
Host-specific, not inherent to unprivileged operation. The rootless cell's
failure set adds `16-rootless-subid-preflight` and drops one the rootful cell
skips, so compare sets rather than assuming the two 10s are identical.

**Set `GITHUB_TOKEN` before every run.** The 60/hr anonymous limit is per IP
and shared with everything else on the host, so it is usually already spent by
the time a suite reaches the image-building scenarios. It does not fail
loudly: the affected scenarios just fail, with no rate-limit text anywhere in
the log, which reads as a code regression. Confirmed on 2026-08-16 — a run
with the quota exhausted produced 23/11/6, and the single extra failure
(`46-version-mismatch`) passed on its own the moment a token was present. A
scopeless or fine-grained PAT is enough; it raises the limit to 5000/hr and
grants nothing. Under `sudo`, pass it with
`sudo --preserve-env=GITHUB_TOKEN` rather than on the command line, so it
does not appear in `ps`.

Comparing two runs requires capturing each to its own file —
`scripts/test/last-run.log` is shared and overwritten per run — and requires
that nothing else drives the suite concurrently. Two agents running it at once
share one image tag, one container namespace and one volume namespace, and
will produce results that agree with each other and with nothing else.

The orchestrator needs passwordless `sudo`. It auto-installs `docker.io`,
`docker-buildx`, and `podman` on Debian/Ubuntu hosts if a runtime is
missing, auto-detects broken in-container DNS resolvers and sets
`DEV_EXTRA_RUN_ARGS=--dns=8.8.8.8 --dns=1.1.1.1` if needed, builds the
base, `:dind`, and `:pind` image targets, then walks every script under
`scripts/test/scenarios/` and reports a pass/fail/skip table. Logs land
at `scripts/test/last-run.log` and `scripts/test/last-summary.log`.

In addition there are two in-container probes:

- `scripts/verify-firewall.sh` — 13 checks. 8 cover the firewall posture
  (including the direct-IPv6-bypass probe);
  checks 8–12 activate when `DEVCONTAINER_DIND=1` or `DEVCONTAINER_PIND=1`
  and verify the rootless nested engine, registry pulls through the proxy,
  and that nested containers can reach loopback ports but not the internet.
- `scripts/verify-dind.sh` — heavier checks (smoke build, postgres
  testcontainers smoke, self-build of this repo's Dockerfile).
- `scripts/verify-pind.sh` — the `--pind` counterpart to `verify-dind.sh`.
  There is no real Docker CLI in the pind image, so probes that would use
  `docker -H "$DOCKER_HOST" ...` talk to the Docker-API compat socket
  directly via curl instead.

Linting is `bash scripts/lint.sh`: shellcheck over every tracked shell file,
hadolint on the Dockerfile, actionlint on the workflows, the line budgets over
`dev` and `lib/dev/*.sh`, and a bash 3.2 portability gate. That last one
matters because macOS still ships bash 3.2 as `/bin/bash` and `dev` plus the
test harness run there directly: `declare -A`, `mapfile`, `${var^}` and
friends are rejected in host-side files. Container-side scripts
(`entrypoint.sh`, `firewall-init.sh`, `dind-init.sh`, `scripts/verify-*.sh`)
run against bash 5 and are exempt, as is `scripts/test/run-e2e.sh`, which is
Linux-only by construction.

lint.sh fetches pinned hadolint and actionlint binaries into
`${XDG_CACHE_HOME:-~/.cache}/devcontainer-ci/bin` on first run — a network
fetch and an executable written outside the repo, worth knowing before running
it on a machine you care about. Every platform's checksum is pinned and
verification fails closed: an unrecognised platform or a missing digest tool
refuses rather than skipping.

CI is `.github/workflows/ci.yml`. All jobs gate: `rootless-linux` and
`macos-checks` lost their bootstrap `continue-on-error` after their first
green runs (2026-08-16, run 31938260294).

## Architecture

Three components, each with a distinct role:

- **Dockerfile** — Builds the base image on `mcr.microsoft.com/devcontainers/base:ubuntu`. Installs mise to `/usr/local/bin/mise`, bakes in base tools from `mise.base.toml` into `/mise/`, stages `.zshrc` to `/etc/skel.devcontainer/` for entrypoint sync.

- **entrypoint.sh** — Runs on every container start. Idempotently ensures `mise activate zsh` is in `.zshrc`, runs `mise install` if a project `mise.toml` exists in `/workspace`, sets git safe.directory, then execs into the shell.

- **dev** — Host-side bash script managing the container lifecycle. Handles image auto-build, container reuse (attach to running/restart stopped), volume mounts, port forwarding, and `GITHUB_TOKEN` passthrough.

`dev` itself is a thin subcommand router: it sources every file under
`lib/dev/*.sh` and dispatches the first argument to a `cmd_*` function.
Each verb (`up`/`exec`/`shell`, `down`/`status`, `fw`, `agent`, `dotfile`,
`reset`, `update`, `install`, `doctor`) gets roughly one module, plus a
handful of shared-concern modules split out of the old monolith:
`container.sh` and `volumes.sh` (container lifecycle and mount/volume
logic), `lifecycle.sh` (`start_container`, the terminal step of the start
flow: reuse-vs-create, assembling the runtime's `run` command, exec or
`--dry-run` print), `image.sh` (image build, UID/version label checks,
rebuild cleanup), `inject.sh` (shared plumbing behind `agent`/`dotfile`),
`runtime.sh` (docker/podman detection), `approval.sh` (the
project-allowlist diff/approve flow), `usage.sh` (the `--help` text), and
`checks.sh` + `checks-catalog.sh` + `checks-catalog-nested.sh` (the
host-check registry shared by `dev doctor` and the blocking preflights in
`dev up`). `scripts/lint.sh` enforces a line-budget gate over `dev` and
`lib/dev/*.sh` so this stays split rather than regrowing into one large
file.

`checks.sh` holds the `CHECKS` array (one entry per requirement:
`id|phase|applies-to|severity|title`) plus the machinery that reads it
(`check_field`, `check_applies`, `run_check`, `checks_select`);
`checks-catalog.sh` holds the `_chk_<id>` / `_chk_<id>_fix` probe/fix
function pairs the registry dispatches to by name. `checks-catalog-nested.sh`
holds the subset of those pairs for `block-if-nested` checks only (userns
sysctl, subid grant, fuse device, cgroup2 — the `--dind`/`--pind`-only
gates), split out once `checks-catalog.sh` grew past its own line-budget.
There are four
severities: `block` refuses in both `dev up` and `dev doctor`;
`block-if-nested` blocks only under `--dind`/`--pind`; `block-in-doctor`
blocks `dev doctor` (readiness) but never `dev up`, because
`lib/dev/image.sh` already guards the real build site with the same probe;
`advise` never blocks anything. `dev doctor` runs every applicable entry,
`cmd_start` runs the blocking subset, so the two can never disagree about
whether a host is usable. Probes reach the outside world only through the
indirections in `runtime.sh`, which is what makes the macOS checks
testable from Linux.

## Key Design Decisions

- **Mise data lives at `/mise/`**, not in the home directory. `MISE_DATA_DIR`, `MISE_CONFIG_DIR`, and `MISE_CACHE_DIR` all point there. This allows the mise volume (`devcontainer-mise`) and the home volume to be independent.
- **Named Docker volumes** persist state: `devcontainer-mise:/mise` (tools/caches, shared across every workspace) and a home volume mounted at `/home/vscode` (shell history, git config, SSH keys). The home volume is **per-workspace by default** (`devcontainer-home-<dir>`, `<dir>` = basename of the directory `dev` was launched from) so one project's agent can't read another project's SSH keys/git creds/history out of a shared home; `DEV_SHARED_HOME=1` opts back into the legacy single `devcontainer-home` volume shared by every workspace. `--dind` adds a third, also shared, volume: `devcontainer-dind:/home/vscode/.local/share/docker`. `--pind` adds a sibling volume, `devcontainer-pind:/home/vscode/.local/share/containers` (mutually exclusive with `--dind`, so only one of the two is ever mounted). `dev` seeds the container's git identity (`user.name`/`user.email`) from the host's `git config` the first time a home volume is created — entrypoint.sh only fills in an empty in-container identity, so it never clobbers one set later inside the container. SSH keys are never copied in; see README's "Pushing from inside a container" for push-from-inside options.
- **Container runs as user `vscode`** (UID 1000 by default, overridable via `USER_UID` build arg).
- **On rootless podman, `dev` adds `--userns=keep-id`.** The image bakes the host UID/GID into `vscode` so it matches the bind-mounted workspace — true under Docker and rootful podman, which don't remap ids. Rootless podman remaps by default (container root → invoking host user, every other id including `vscode`'s → the subuid/subgid range), so without `keep-id` the workspace shows up root-owned to `vscode`. `keep-id` maps the invoking host user 1:1 onto `vscode`'s uid instead. Named volumes written before this fix are owned by the old mapping's subuid; `dev` detects that (raw owner ≠ `$HOST_UID`) and re-chowns each volume once via `podman unshare chown -R 0:0` (0:0 inside `podman unshare`'s own default mapping *is* the invoking host user).
- **Containers are `--rm`** (ephemeral) but the `dev` script reuses a running/stopped container named `dev-<dirname>` before creating a new one.
- **Base tools** (node LTS, ripgrep, eza, lazygit, neovim) are defined in `mise.base.toml` and baked into the image at build time. The name is deliberate: mise auto-discovers `mise.toml` / `.mise.toml`, so the baked-tools list lives under a non-discoverable name to keep it separable from the project-level `mise.toml` that consumers (and this repo itself) place at the workspace root.
- **Developer tools** for working on *this* repo (shellcheck, hadolint, actionlint, jq) live in a workspace-root `mise.toml`. Running `mise install` from the repo root installs them; `entrypoint.sh` also runs `mise install` automatically when the container starts with `/workspace/mise.toml` present. Per-project tools in *consuming* projects come from their own `mise.toml`.
- **Opt-in Docker-in-Docker** via `./dev up --dind`. Builds a separate
  `generic-devcontainer:dind` image (the `dind` target in the multi-stage
  Dockerfile) that adds rootless `dockerd`, fuse-overlayfs, and
  slirp4netns. The container is named `dev-<dir>-dind`, mounts
  `/dev/fuse` + `/dev/net/tun`, and uses a dedicated `devcontainer-dind`
  cache volume. Registry pulls flow through `tinyproxy` via the
  slirp4netns gateway (`HTTPS_PROXY=http://10.0.2.2:8888`). Mutually
  exclusive with `--maint` and `--pind` (four-way conflict guard
  between normal / maintenance / dind / pind containers). On Ubuntu 23.10+/Linux 6.x
  hosts `./dev` preflights `kernel.apparmor_restrict_unprivileged_userns=0`
  and refuses to start with a remediation message if it is `1`. See
  README.md for details.
- **Opt-in Podman-in-Podman** via `./dev up --pind`. Builds a separate
  `generic-devcontainer:pind` image (the `pind` target in the multi-stage
  Dockerfile) that adds rootless `podman`, fuse-overlayfs, and
  slirp4netns. The container is named `dev-<dir>-pind` and uses a
  dedicated `devcontainer-pind` cache volume
  (`/home/vscode/.local/share/containers`). Podman is daemonless: its own
  image pulls route through the proxy at `127.0.0.1:8888` in the
  container's main netns, while nested-container egress routes through
  `10.0.2.2:8888` via slirp4netns — the backend is pinned
  (`default_rootless_network_cmd = "slirp4netns"`,
  `allow_host_loopback=true`) so nested containers can reach that gateway.
  A `podman system service` unix socket at
  `/home/vscode/.pind-run/podman.sock` gives Docker-API compatibility,
  exported as `DOCKER_HOST` for testcontainers / docker-compose. Docker
  CLI compatibility comes from the `podman-docker` shim
  (`/usr/bin/docker` → podman) plus a `docker-compose` symlink to the
  compose v2 plugin — not the real Docker CLI. Mutually exclusive with
  `--dind` and `--maint` (four-way conflict guard: normal /
  maintenance / dind / pind). Shares the same `kernel.apparmor_restrict_unprivileged_userns=0`
  and subuid/subgid preflights as `--dind`. See README.md for details.
- **Opt-in agent credential injection** via `./dev agent add <name>`
  (`claude`/`opencode`/`pi`). Copies a curated allowlist of each agent's
  auth + settings + customizations from the host into the per-workspace home
  volume — a one-way snapshot, never a host mount and never baked into an
  image (secrets would leak into shared/cacheable layers). Excludes every
  tool's conversation/project/session history to preserve per-workspace home
  isolation. Secret files are forced to `0600`. Copy runs through a
  short-lived helper container executing `tar -x` as `vscode` under the same
  `--userns=keep-id` mapping as the real container, so ownership is correct
  across Docker, rootful podman, and rootless podman. For `claude`
  specifically, a follow-up helper (node, baked on the image PATH) merges a
  single `hasCompletedOnboarding: true` flag into the volume's `~/.claude.json`
  — that top-level file is never copied wholesale (it holds cross-workspace
  project history), but without the flag Claude's interactive onboarding/login
  wizard reappears in every fresh workspace despite valid copied credentials.
  The merge preserves any existing state and leaves a corrupt file untouched.
  On macOS, Claude Code stores its OAuth token in the login Keychain (generic
  password `Claude Code-credentials`) rather than `~/.claude/.credentials.json`,
  so `_agent_resolve` falls back to reading the Keychain when that file is
  absent and materializes the payload into the volume as `.credentials.json`
  (byte-for-byte what Claude reads on Linux). Refresh by re-running `add`;
  remove with `dev agent rm` or `dev reset`. See README.md.

## Firewall (security boundary)

The firewall is the project's primary security feature — the threat model
is containment of agent reach: the agent must not find or use host
keys/secrets by accident, or reach outside the sandbox in misguided
loyalty to a task. Allowlisted hosts are reachable and bidirectional by
design; this is **not** exfiltration prevention (see SECURITY.md for the
full write-up).

`dev up` defaults to **open** egress: no allowlist, no proxy, outbound
traffic is unrestricted. `dev up --closed` opts into the old default-deny +
curated-allowlist posture instead. Precedence, most-specific wins: an
explicit `--open`/`--closed` flag on `dev up`/`dev exec` beats
`DEV_EGRESS=open|closed` (a host env var that sets the default for every
invocation) beats the built-in `open` default. `--maint` never runs a
firewall regardless of egress mode. Isolation — no sudo, no host mounts
beyond the workspace, per-workspace home volume, the always-on
link-local/cloud-metadata block — is unchanged by egress mode; only closed
mode adds the hostname allowlist. `dev fw log` shows egress activity in
either mode — closed mode's tinyproxy log (hostnames from CONNECT), or open
mode's DNS-query + connection (NFLOG) log, since there is no proxy to log
through when open — so you don't have to close the firewall to get
visibility into what a container reached.

In closed mode, two layers enforce it, in the kernel and at L7:

- **iptables** defaults `OUTPUT` to DROP. DNS is allowed; only the `proxy`
  user can reach `:80`/`:443`. Raw-socket bypasses by `vscode` are dropped
  by the kernel owner rule.
- **tinyproxy** runs in the container and filters HTTPS by hostname
  (CONNECT). Clients honour `HTTPS_PROXY=http://127.0.0.1:8888`, exported
  by the entrypoint.
- **`vscode` has no sudo** in normal mode, in either egress mode. There is
  no path to disable iptables from inside the container.

Two allowlist files merge at container startup (deduplicated), consulted
only in closed mode:

- `allowlist.base` — baked into the image at `/etc/devcontainer/allowlist.base`
  (Anthropic, GitHub, common registries, mise, OS mirrors). Edit and rebuild
  to change.
- `.devcontainer-allowlist` at the workspace root — optional, project-specific.
  Because the workspace is agent-writable, the firewall **never** reads this
  file directly: `firewall-init.sh` only ever consumes the host-side
  APPROVED snapshot at `/etc/devcontainer/project/allowlist.approved`,
  mounted read-only. `dev` (`lib/dev/approval.sh`) maintains that snapshot —
  on every start it diffs the workspace file against the last approved copy
  (kept under `~/.local/state/devcontainer/`) and prompts to approve
  changes; declined or non-interactive runs start WITHOUT the project
  allowlist (fail-safe, never blocks). Editing the workspace file alone has
  no effect until it is approved; restart after approving to pick it up (no
  image rebuild needed).
- `allowlist.dind` — additionally merged when DinD/PinD is active (Docker
  Hub, MCR, Quay, GCR, etc.). `--pind` reuses this same file (there is no
  separate `allowlist.pind`) since both nested engines pull from the same
  registries.

Format: one entry per line, `#` comments. Bare hostname matches exactly;
`*.example.com` matches any subdomain (list both if you need both).

When the firewall is in the way on a closed run, prefer `--maint` (its own
container, sudo + no firewall) over toggling a running container open — the
toggle flags do not change the container name, so there is no visible
signal that egress is currently open.

For reaching a service on the Docker host (local LLM server, metrics
endpoint, etc.) prefer `--host-port PORT` (repeatable) over `--maint` or
`--network host`. It adds `--add-host=host.docker.internal:host-gateway`
plus a single iptables `ACCEPT` rule for that port against the host gateway
IP only. In closed mode the rest of the firewall posture is unchanged; in
open mode the gateway is already reachable like any other host, so
`--host-port` is mainly useful there for a stable `host.docker.internal`
hostname, or for `--closed` runs. Inside the container, reach the service at
`host.docker.internal:PORT`. The env contract is
`DEVCONTAINER_HOST_PORTS=p1,p2,...`, consumed by `firewall-init.sh`.
