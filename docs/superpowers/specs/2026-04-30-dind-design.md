# Docker-in-Docker (rootless) — Design

**Date:** 2026-04-30
**Status:** Draft
**Scope:** This repository (the generic devcontainer)

## Goal

Add an opt-in `--dind` mode that gives the agent inside the dev container a working `docker` CLI backed by a rootless `dockerd` running inside the same container. Primary use case: testcontainers / integration tests. Secondary: building images, including iterating on this devcontainer's own Dockerfile.

The existing security model is preserved: no sudo for `vscode`, default-DROP outbound, registry pulls go through the existing `tinyproxy` allowlist, and nested containers have no outbound by default.

The `dev` host script must work on Linux (with docker, podman, or both) and on macOS (with podman only — Docker Desktop is explicitly out of scope).

## Threat model

**In scope.** Same threat model as the firewall design. A semi-trusted agent runs as `vscode`. Adding `--dind` must not give that agent:

- A path to root on the host (rules out mounting the host docker/podman socket).
- A path to disable the in-container firewall (rules out `--privileged` and `cap-add=SYS_ADMIN`).
- Unfiltered outbound network access from spawned containers (the existing iptables owner-rule continues to block this).

**Out of scope.**

- Outbound network access for nested containers. Testcontainers' usual loopback-port pattern works without it. Future work could expose tinyproxy on the slirp4netns gateway interface and document `HTTPS_PROXY=http://10.0.2.2:8888` for nested containers that need internet.
- Multi-platform `buildx` / qemu emulation.
- Concurrent `--dind` and `--maintenance` modes.
- Docker Desktop on macOS.
- Hosts with `/dev/fuse` unavailable, `kernel.unprivileged_userns_clone=0`, or cgroup-v1-only — these will fail closed with a clean diagnostic, not silently degrade.

## Architecture

```
┌───────────── dev container (no --privileged, no host-socket mount) ─────────────┐
│  vscode (uid 1000) — agent shell                                                │
│     │   DOCKER_HOST=unix:///home/vscode/.dind-run/docker.sock                   │
│     ▼                                                                           │
│  dockerd-rootless.sh  (runs as vscode in a userns via newuidmap)                │
│     │   HTTPS_PROXY=http://127.0.0.1:8888  (registry pulls)                     │
│     │   --iptables=false                                                        │
│     ▼                                                                           │
│  tinyproxy (uid=proxy)                                                          │
│     │   filter = base + project + dind allowlists                               │
│     ▼                                                                           │
│  iptables OUTPUT (default DROP, owner-rule allows uid=proxy on 80/443)          │
│     │                                                                           │
│     ▼                                                                           │
│   internet                                                                      │
│                                                                                 │
│  Nested containers spawned by dockerd-rootless:                                 │
│    • own netns; networking via slirp4netns (which runs as vscode)               │
│    • outbound on 80/443 → blocked by owner-rule (slirp ≠ proxy)                 │
│    • loopback ports (testcontainers) → reachable from the agent shell ✓         │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Why this preserves the firewall.** dockerd-rootless does its registry pulls itself, not the spawned container, and we set `HTTPS_PROXY` in dockerd's environment. Loopback is in the iptables ACCEPT list, so dockerd → tinyproxy works. Tinyproxy's outbound runs as `proxy` UID and the owner-rule lets it through. Spawned containers' slirp4netns runs as `vscode`, so the owner-rule continues to block them — exactly the property we want for an agent sandbox.

**Container runtime knobs added by `--dind`:**

- `--device=/dev/fuse` (fuse-overlayfs)
- `--security-opt apparmor=unconfined`
- `--security-opt seccomp=unconfined`
- `-v devcontainer-dind:/home/vscode/.local/share/docker`
- `-e DEVCONTAINER_DIND=1`

Existing flags (`--cap-add=NET_ADMIN`, workspace/mise/home volumes, port forwards, `GITHUB_TOKEN`) are kept. No `--privileged`, no host-socket mount, no extra capabilities.

## Image strategy

Multi-stage Dockerfile with two final tags:

- `generic-devcontainer` — built with `--target base`. Unchanged behavior.
- `generic-devcontainer:dind` — built with `--target dind`. Adds the rootless docker bundle on top of base.

```dockerfile
FROM mcr.microsoft.com/devcontainers/base:ubuntu AS base
# ... existing layers (firewall stack, mise, allowlist.base, etc.) ...

FROM base AS dind
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        fuse-overlayfs uidmap iproute2 dbus-user-session && \
    rm -rf /var/lib/apt/lists/*

# Pinned static rootless docker bundle. Versions and sha256 hashes are
# committed to the repo so the image build is reproducible.
ARG DOCKER_VERSION=27.3.1
ARG DOCKER_SHA256_AMD64=...    # filled in at implementation time
ARG DOCKER_SHA256_ARM64=...
RUN arch="$(uname -m)" && \
    case "$arch" in \
        x86_64)  sha="$DOCKER_SHA256_AMD64" ;; \
        aarch64) sha="$DOCKER_SHA256_ARM64" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/docker.tgz \
        "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_VERSION}.tgz" && \
    echo "${sha}  /tmp/docker.tgz" | sha256sum -c - && \
    tar -xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1 && \
    rm /tmp/docker.tgz
# Same pattern for docker-rootless-extras-${DOCKER_VERSION}.tgz.

# Allocate a sub-uid/gid range for the vscode user (newuidmap).
RUN echo "vscode:100000:65536" >> /etc/subuid && \
    echo "vscode:100000:65536" >> /etc/subgid

COPY --chmod=755 dind-init.sh /usr/local/sbin/dind-init.sh
COPY allowlist.dind /etc/devcontainer/allowlist.dind
USER vscode
```

Architecture handling: `$(uname -m)` selects the correct static bundle, so the same Dockerfile builds on linux/amd64 and linux/arm64 (Apple silicon under podman machine).

## `dev` script changes

### New flag

```
--dind   Start container with rootless Docker daemon available inside.
         Uses generic-devcontainer:dind, suffixes container name with
         -dind, mounts /dev/fuse, and uses a dedicated image cache volume.
         Mutually exclusive with --maintenance.
```

### Mode matrix and conflict guards

| mode         | container name      | image tag                    |
|--------------|---------------------|------------------------------|
| normal       | `dev-<dir>`         | `generic-devcontainer`       |
| maintenance  | `dev-<dir>-maint`   | `generic-devcontainer`       |
| dind         | `dev-<dir>-dind`    | `generic-devcontainer:dind`  |

The existing two-way conflict guard (normal ↔ maintenance) extends to a three-way pairwise guard. `dev` refuses to start any mode while another mode's container is running for the same workspace.

`--monitor`, `--monitor-fw`, `--disable-firewall`, and `--enable-firewall` continue to act on the normal container only. `--dind` has its own firewall posture but no separate monitor flags in v1.

### Host runtime detection

The script replaces every literal `docker` with `$RUNTIME`, picked once at startup:

```bash
detect_runtime() {
  if [[ -n "${DEV_RUNTIME:-}" ]]; then
    RUNTIME="$DEV_RUNTIME"; return
  fi
  case "$(uname -s)" in
    Darwin)
      command -v podman >/dev/null && { RUNTIME=podman; return; }
      die "On macOS, podman is required (Docker Desktop is not supported)."
      ;;
    Linux)
      command -v docker >/dev/null && { RUNTIME=docker; return; }
      command -v podman >/dev/null && { RUNTIME=podman; return; }
      die "Neither docker nor podman found on PATH."
      ;;
    *)
      die "Unsupported platform: $(uname -s)"
      ;;
  esac
}
```

Override via `DEV_RUNTIME=podman`. On macOS, when `RUNTIME=podman`, the script also verifies `podman machine` is running and emits an actionable error (`podman machine start`) if not.

### Subcommand differences (docker vs podman)

The script touches `build`, `run`, `ps`, `exec`, `start`, `images`, `volume`. Of these, only the build path differs:

- `docker buildx build --network=host` → for podman use `podman build --network=host` (no `buildx` subcommand).

A small shim function `runtime_build` handles this. Everything else is plain `$RUNTIME` substitution.

### `docker run` additions for `--dind`

```
--device=/dev/fuse
--security-opt apparmor=unconfined
--security-opt seccomp=unconfined
-v devcontainer-dind:/home/vscode/.local/share/docker
-e DEVCONTAINER_DIND=1
```

## Entrypoint and dockerd lifecycle

`entrypoint.sh` gains one branch after firewall init, before user-context tasks:

```
1. firewall-init.sh                 (existing; unchanged)
2. write /etc/profile.d/proxy.sh    (existing; unchanged)
3. if [ -n "$DEVCONTAINER_DIND" ]; then
       /usr/local/sbin/dind-init.sh   (new)
   fi
4. gosu vscode bash <<INNER ... INNER  (existing; mise/git/zshrc)
5. exec gosu vscode "$@"
```

### `dind-init.sh` (new)

Runs as root; drops to vscode for the dockerd start.

```
1. Ensure /etc/subuid and /etc/subgid contain a vscode range (idempotent;
   matters when --build-arg USER_UID=501 has rewritten the user).
2. Ensure /home/vscode/.local/share/docker is owned by vscode (the
   named volume comes up empty on first mount).
3. Write /etc/profile.d/dind.sh:
       export DOCKER_HOST=unix:///home/vscode/.dind-run/docker.sock
       export XDG_RUNTIME_DIR=/home/vscode/.dind-run
4. As vscode (gosu vscode):
       mkdir -p /home/vscode/.dind-run
       chmod 0700 /home/vscode/.dind-run
       env XDG_RUNTIME_DIR=/home/vscode/.dind-run \
           HTTPS_PROXY=http://127.0.0.1:8888 \
           HTTP_PROXY=http://127.0.0.1:8888 \
           NO_PROXY=localhost,127.0.0.1 \
           PATH=/usr/local/bin:$PATH \
           nohup dockerd-rootless.sh \
               --iptables=false \
               > /var/log/dockerd-rootless.log 2>&1 &
5. Wait up to 15s for /home/vscode/.dind-run/docker.sock to appear.
   If it doesn't, tail /var/log/dockerd-rootless.log to stderr and
   exit non-zero (fail-closed; same posture as firewall-init.sh).
```

### Why `--iptables=false`

The dev container's iptables OUTPUT chain is owned by `firewall-init.sh`. dockerd-rootless cannot acquire NET_ADMIN inside its userns anyway, so letting it try would either fail or fight with the existing chain. Rootless docker doesn't need iptables on the host side — slirp4netns handles per-container networking.

### Why proxy env vars are set on dockerd

Image and build-context pulls happen in the dockerd process, not in the agent shell. The shell already has the proxy exported via `/etc/profile.d/proxy.sh`. dockerd inherits nothing from the user shell because it's started by the entrypoint, so it gets the proxy explicitly here.

### Lifecycle on container restart

`dockerd-rootless` is a child of the entrypoint's main process and dies when the container stops. On `docker start dev-<dir>-dind` the entrypoint runs again and restarts dockerd cleanly. The named `devcontainer-dind` volume preserves images and containers across restarts.

## Allowlist additions

`firewall-init.sh` gains one branch in the merge step:

```bash
{
    cat "$BASE"
    [ -f "$PROJECT" ] && cat "$PROJECT"
    [ -n "${DEVCONTAINER_DIND:-}" ] && [ -f /etc/devcontainer/allowlist.dind ] \
        && cat /etc/devcontainer/allowlist.dind
} | sed 's/#.*//' | tr -d ' \t' | awk 'NF' | sort -u | …
```

`allowlist.dind` is bundled in the `dind` image stage only and starts with everything testcontainers + a `docker build` of this repo's Dockerfile would touch:

```
# Docker Hub
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
*.cloudfront.net

# Docker static binaries
download.docker.com

# Microsoft Container Registry (devcontainers/base; multi-arch)
mcr.microsoft.com
*.data.mcr.microsoft.com
*.azureedge.net

# Quay
quay.io
*.quay.io
cdn.quay.io
cdn03.quay.io
cdn04.quay.io

# Google Container Registry (some testcontainers images)
gcr.io
storage.googleapis.com

# ghcr.io is already in allowlist.base
```

**Subtlety to flag.** Image layer downloads on Docker Hub redirect to `*.cloudfront.net` URLs that change between requests. Tinyproxy's hostname filter applies to each CONNECT target, so any tightening of `*.cloudfront.net` would break pulls. The broad cloudfront entry is the realistic tradeoff for image-registry support.

**Project-level overrides** still work: `.devcontainer-allowlist` in the workspace continues to merge in for both modes. A team using a private registry (e.g. `harbor.example.com`) puts it in their project file rather than touching either base file.

## Verification and testing strategy

All testing is scripted and runnable end-to-end on a Linux VM by another Claude Code instance via a single entry point: `scripts/test/run-all.sh`. Mac-only scenarios live in the same tree but are tagged for platform-skip.

### Layout

```
scripts/
  verify-firewall.sh      # existing, extended with checks 8–12
  verify-dind.sh          # NEW: heavier in-container checks (D1–D5)
  test/
    run-all.sh            # orchestrator; entry point for the VM
    lib/
      assert.sh           # log_pass / log_fail / log_skip / expect_*
      runtime.sh          # detect docker/podman, helpers
      restore.sh          # snapshot+restore for sysctl, iptables, packages, PATH
    scenarios/            # each script: setup → run → assert → restore (trap EXIT)
      01-host-docker-only.sh
      02-host-podman-noshim.sh
      03-host-podman-with-shim.sh
      04-host-both-runtimes.sh
      05-runtime-env-override.sh
      10-cgroupv2-default.sh
      11-userns-clone-disabled.sh
      12-fuse-missing.sh
      13-apparmor-enforcing.sh
      14-selinux-enforcing.sh
      20-mode-conflict-pairs.sh
      22-cold-start-budget.sh           # Linux <=10s, Darwin <=20s; fail at 30s
      23-cache-persists-restart.sh
      24-cache-persists-rebuild.sh
      25-private-registry-allowlist.sh
      30-attack-sudo-iptables.sh
      31-attack-privileged-flag.sh
      32-attack-host-mount.sh
      33-attack-nested-egress.sh
      90-mac-podman-machine-stopped.sh    # platform: darwin
      91-mac-only-docker-desktop.sh       # platform: darwin
    fixtures/
      Dockerfile.smoke
      testcontainers-smoke.go             # ~30 lines, uses ory/dockertest
```

### In-container checks: extending `verify-firewall.sh`

Add checks 8–12, only active when `DEVCONTAINER_DIND=1`:

| # | Check | Command (essence) | Expected |
|---|---|---|---|
| 8 | dockerd reachable | `docker version` | client + server respond |
| 9 | rootless mode confirmed | `docker info -f '{{.SecurityOptions}}'` | `rootless` present |
| 10 | image pull through proxy | `docker pull alpine:3.20` | success; tinyproxy log shows the CONNECT |
| 11 | nested container has no outbound | `docker run --rm alpine wget -T3 https://example.com` | failure (timeout / refused) |
| 12 | nested container loopback works | `docker run --rm -p 127.0.0.1:0:8080 …` + curl from agent | port reachable |

### `verify-dind.sh` (new)

Heavier checks not run on every container start:

| # | Check | Why |
|---|---|---|
| D1 | `docker build` of `fixtures/Dockerfile.smoke` (which does `RUN apt-get update`) | proxy works during build |
| D2 | testcontainers smoke (`go run fixtures/testcontainers-smoke.go`, brings up postgres) | the actual primary use case |
| D3 | `docker build` of this repo's Dockerfile from inside `--dind` | the secondary use case (improving sandbox project from inside it) |
| D4 | image cache persists: pull → exit container → re-attach → image still present | named volume working |
| D5 | dockerd restart: `docker stop dev-<dir>-dind && docker start … && docker version` succeeds | lifecycle |

### Orchestrator (`run-all.sh`)

```
1. Verify VM preconditions (sudo capable, internet reachable, ≥10GB free).
2. Build both images (generic-devcontainer base and :dind).
3. Walk scenarios in lexicographic order; each in its own subshell.
4. Per scenario:
     - source lib/assert.sh and lib/restore.sh
     - register `trap restore_host EXIT` BEFORE any mutation
     - check platform tag at top; log SKIP and exit 0 if not applicable
     - run; emit PASS/FAIL/SKIP with reason
5. Aggregate: print a summary table and exit non-zero if any FAIL.
6. Tee the full log to scripts/test/last-run.log.
```

### Scenario skeleton

```bash
#!/bin/bash
# scenarios/11-userns-clone-disabled.sh
# platform: linux
set -u
. "$(dirname "$0")/../lib/assert.sh"
. "$(dirname "$0")/../lib/restore.sh"

snapshot_sysctl kernel.unprivileged_userns_clone
trap restore_host EXIT

sudo sysctl -w kernel.unprivileged_userns_clone=0

out=$(./dev --dind -- true 2>&1) && log_fail "expected non-zero exit" && exit 1
expect_grep "$out" "user namespaces" || expect_grep "$out" "unprivileged_userns_clone"
log_pass "userns disabled produces clean diagnostic"
```

### What `restore.sh` covers

- sysctl values (snapshot/restore).
- iptables rules at the host level (the dev container has its own ruleset; we don't touch it from the host except through `dev`).
- Package install state — uninstall what scenarios installed for the test (e.g. transient `podman`/`docker.io` flips). Idempotent.
- PATH manipulation — runtime-detection scenarios mock missing binaries by prepending a temp dir with stub `docker`/`podman` scripts; no real uninstall needed.
- `podman machine` state on Darwin.
- `devcontainer-*` named volumes the scenario created (via `volume rm`).

### Coverage map

Every row in the design's edge-case matrix maps to a scenario:

| matrix row | scenario file |
|---|---|
| docker-only host | 01 |
| podman without shim | 02 |
| podman with shim | 03 |
| both runtimes | 04 |
| `DEV_RUNTIME` override | 05 |
| cgroup v2 | 10 |
| userns disabled | 11 |
| `/dev/fuse` missing | 12 |
| AppArmor enforcing | 13 |
| SELinux enforcing | 14 |
| mode conflicts (3 pairs) | 20 |
| cold-start budget | 22 |
| cache persists across restart | 23 |
| cache persists across rebuild | 24 |
| private registry allowlist | 25 |
| attack: sudo iptables | 30 |
| attack: `docker run --privileged` | 31 |
| attack: host-path mount | 32 |
| attack: nested-container egress | 33 |
| Mac scenarios | 90–91 (skipped on Linux VM) |

### Deferred (cannot be reliably automated on a single VM)

- cgroup-v1 testing — modern Linux distros are v2-only by default. Documented as "run on a host with `systemd.unified_cgroup_hierarchy=0` if you need to verify."
- Heavy testcontainers performance characterization — `testcontainers-smoke` covers correctness, not throughput.

## Alternatives considered

- **DooD (mount host docker/podman socket).** Lightest-weight, but gives the agent root-equivalent on the host. Defeats the entire sandbox premise; rejected.
- **Privileged DinD with full `dockerd`.** Self-contained but requires `--privileged`, which lets the agent flush iptables and so disables the firewall. Rejected.
- **Podman-in-Podman inside the container** (instead of rootless dockerd). Possible, but the user requested docker CLI inside, and rootless docker has more battle-tested integration with testcontainers libraries. Revisit if rootless docker turns out to have unfixable issues on common hosts.
- **Single image with build-arg gate** instead of multi-stage. Rejected: every layer becomes conditional, and the image bloats for non-DinD users. Multi-stage cleanly separates the two artifacts.
- **System-installed dockerd-rootless via apt.** Rejected: distro packages lag upstream and the version pinning we want for reproducibility is harder. Static tarballs with sha256 are cleaner.

## Files added or changed

**New:**

- `dind-init.sh` — root-side init that ensures subuid range + storage perms, writes `/etc/profile.d/dind.sh`, and starts dockerd-rootless as vscode.
- `allowlist.dind` — registry hostnames (Docker Hub, MCR, Quay, GCR, etc.).
- `scripts/verify-dind.sh` — heavier in-container checks (D1–D5).
- `scripts/test/run-all.sh` — orchestrator.
- `scripts/test/lib/{assert,runtime,restore}.sh` — shared helpers.
- `scripts/test/scenarios/*.sh` — one script per matrix row.
- `scripts/test/fixtures/Dockerfile.smoke` and `testcontainers-smoke.go`.

**Changed:**

- `Dockerfile` — convert to multi-stage; add `dind` stage with rootless docker bundle (pinned), fuse-overlayfs, uidmap, subuid/subgid, copies of `dind-init.sh` and `allowlist.dind`.
- `entrypoint.sh` — add `DEVCONTAINER_DIND` branch invoking `dind-init.sh`.
- `firewall-init.sh` — merge `allowlist.dind` when `DEVCONTAINER_DIND` is set.
- `scripts/verify-firewall.sh` — add checks 8–12 (DinD-aware, gated on `DEVCONTAINER_DIND`).
- `dev` — `--dind` flag, three-way conflict guard, `$RUNTIME` substitution, `detect_runtime`, `runtime_build` shim, `:dind` tag, `devcontainer-dind` volume, fuse/seccomp/apparmor opts, podman-machine check on Darwin, help text.
- `README.md` — document the `--dind` flag, host-runtime expectations (Linux: docker or podman; Mac: podman only), and the testing entry point.
