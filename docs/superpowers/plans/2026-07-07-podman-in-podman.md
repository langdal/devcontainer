# Podman-in-Podman (`--pind`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `--pind` mode that runs a rootless podman engine inside the dev container, meeting the same firewall/exfiltration security bar as the existing `--dind` mode, without changing `--dind`.

**Architecture:** A parallel structure to dind — new `pind` Dockerfile target, `pind-init.sh`, `--pind` flag, `dev-<dir>-pind` container, `devcontainer-pind` volume, `DEVCONTAINER_PIND=1` env. Podman is daemonless, so its own image pulls go straight through `127.0.0.1:8888`; nested-container egress reuses dind's `10.0.2.2:8888` slirp path. A `podman system service` unix socket provides Docker-API compatibility (testcontainers / docker-compose / `DOCKER_HOST`). Shared device/capability/security args, the two preflights, and the registry allowlist are factored to serve both modes.

**Tech Stack:** Bash, Dockerfile (multi-stage, BuildKit), rootless podman + slirp4netns + fuse-overlayfs, tinyproxy + iptables firewall, shellcheck/hadolint lint, bash e2e scenario harness under `scripts/test/`.

## Global Constraints

- Firewall threat model is inviolable: every egress path (engine pulls + nested workloads) MUST be funneled through the tinyproxy allowlist; `vscode` has no sudo and no route to disable iptables. Copied from spec §"Networking & firewall".
- `--pind` is mutually exclusive with `--dind` and `--maintenance` (four-way guard: normal / maintenance / dind / pind). From spec §"Mutual exclusion".
- Pin podman's network backend to `slirp4netns` in `containers.conf` (NOT the podman-5.x pasta default) so nested egress reaches `10.0.2.2:8888`. From spec §"The one real risk".
- `--dind` mode must remain behaviorally unchanged. From spec §"Success criteria" #6.
- Container finalizes as root; entrypoint runs firewall-init + init scripts as root, then drops to `vscode` via gosu. Do NOT add `USER vscode` to the `pind` target.
- Nested-workload proxy = `http://10.0.2.2:8888`; engine's own-pull proxy = `http://127.0.0.1:8888`. From spec §"Key architectural difference".
- Commits: Conventional Commits, imperative, ~72 char subject. `feat:` for the user-visible `--pind` addition. In this sandbox, sign-off fails — commit with `git -c commit.gpgsign=false commit ...`. NEVER `git push`.
- Lint gate for every task touching `*.sh` or `Dockerfile`: `bash scripts/lint.sh` (shellcheck + hadolint + actionlint) must pass.

## File Structure

- **Create** `pind-init.sh` (repo root) — rootless podman engine setup, run as root by entrypoint, drops to vscode. Sibling of `dind-init.sh`.
- **Create** `scripts/verify-pind.sh` — in-container heavy probe. Sibling of `scripts/verify-dind.sh`.
- **Create** `scripts/test/scenarios/34-attack-nested-egress-pind.sh` — pind nested-egress firewall probe. Sibling of `33-attack-nested-egress.sh`.
- **Modify** `Dockerfile` — add `FROM base AS pind` target (after the `dind` target).
- **Modify** `entrypoint.sh` — add a `DEVCONTAINER_PIND` branch alongside the `DEVCONTAINER_DIND` branch.
- **Modify** `firewall-init.sh` — merge `allowlist.dind` when `DEVCONTAINER_PIND` is set too.
- **Modify** `dev` — parse `--pind`, resolve `PIND_NAME`, set image/target/name, four-way mutex, `refuse_if_running` entry, scaffold arg.
- **Modify** `lib/dev/lifecycle.sh` — gate the shared device/cap/security block on `DIND || PIND`; add pind volume + `DEVCONTAINER_PIND=1`.
- **Modify** `lib/dev/preflight.sh` — extend apparmor + subid preflight triggers to include `PIND`.
- **Modify** `lib/dev/scaffold.sh` — emit a pind `.devcontainer/` for `./dev scaffold --pind`.
- **Modify** `scripts/verify-firewall.sh` — generalize checks 8–12 to nested-runtime-agnostic (`DEVCONTAINER_DIND || DEVCONTAINER_PIND`).
- **Modify** `scripts/test/scenarios/20-mode-conflict-pairs.sh` — add pind pairs to the mutex matrix.
- **Modify** `scripts/test/scenarios/16-rootless-subid-preflight.sh` and `15-apparmor-userns-restrict.sh` — exercise `--pind`.
- **Modify** `README.md`, `CLAUDE.md` — document `--pind`.

---

### Task 1: Dockerfile `pind` target

**Files:**
- Modify: `Dockerfile` (append a new stage after the `dind` target, which ends around the compose/buildx plugin blocks near line 273)

**Interfaces:**
- Produces: a build target named `pind` producing image `generic-devcontainer:pind` with `podman`, `slirp4netns`, `fuse-overlayfs`, `uidmap`, `dbus-user-session`, `jq`, and the `docker compose` v2 plugin present. Copies `pind-init.sh` to `/usr/local/sbin/pind-init.sh` and `allowlist.dind` to `/etc/devcontainer/allowlist.dind` (already copied by the dind target; the pind target needs its own COPY since it is a separate stage `FROM base`).

- [ ] **Step 1: Add the `pind` stage to the Dockerfile**

Append after the `dind` target's final instruction:

```dockerfile
# =============================================================================
FROM base AS pind
# Rootless podman engine as a sibling to the dind (rootless dockerd) target.
# Podman is daemonless: `podman pull`/`build` run in the calling vscode
# process in the container's main netns, so their own egress uses the same
# OUTPUT chain as an ordinary curl. Nested-container egress still routes via
# the slirp gateway 10.0.2.2:8888, exactly like dind.
# Stays root: entrypoint runs firewall-init.sh + pind-init.sh as root, then
# drops to vscode via gosu. Do NOT set USER vscode here.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3002
USER root

# podman            - the nested container engine (pulls in crun/conmon/
#                     containers-common transitively)
# fuse-overlayfs    - rootless storage driver
# uidmap            - newuidmap / newgidmap for user-namespace allocation
# slirp4netns       - per-container network stack (pinned backend; see
#                     containers.conf in pind-init.sh)
# dbus-user-session - user session paths for rootless podman
# jq                - pind-init.sh merges config json
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        podman \
        fuse-overlayfs \
        uidmap \
        slirp4netns \
        dbus-user-session \
        jq && \
    rm -rf /var/lib/apt/lists/*

# docker compose v2 CLI plugin, so `docker compose ...` (and DOCKER_HOST-based
# tooling) resolves against the podman compat socket. Installed under the
# system-wide plugin path.
ARG COMPOSE_VERSION=2.40.3
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${arch}"; \
    curl -fsSLo /tmp/docker-compose "${url}"; \
    expected="$(curl -fsSL "${url}.sha256" | awk '{print $1}')"; \
    echo "${expected}  /tmp/docker-compose" | sha256sum -c -; \
    install -D -m 0755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose; \
    rm -f /tmp/docker-compose

COPY allowlist.dind /etc/devcontainer/allowlist.dind
COPY --chmod=755 pind-init.sh /usr/local/sbin/pind-init.sh

# NOTE: do NOT switch USER to vscode here (same reason as the dind target).
```

- [ ] **Step 2: Create a placeholder `pind-init.sh` so the COPY succeeds**

The image build's `COPY pind-init.sh` needs the file to exist. Create a minimal fail-closed stub (Task 2 fills it in):

```bash
cat > pind-init.sh <<'EOF'
#!/bin/bash
# /usr/local/sbin/pind-init.sh — placeholder, implemented in Task 2.
set -euo pipefail
echo "pind-init.sh: not yet implemented" >&2
exit 1
EOF
chmod +x pind-init.sh
```

- [ ] **Step 3: Build the pind target**

Run: `docker build --network=host --target pind -t generic-devcontainer:pind .`
Expected: build completes successfully; `podman`, `slirp4netns`, `fuse-overlayfs` install without error.

- [ ] **Step 4: Verify the tools are present**

Run: `docker run --rm generic-devcontainer:pind bash -lc 'command -v podman && command -v slirp4netns && command -v fuse-overlayfs && ls /usr/local/lib/docker/cli-plugins/docker-compose'`
Expected: four non-empty paths printed, exit 0.

- [ ] **Step 5: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS (hadolint clean on the new stage).

- [ ] **Step 6: Commit**

```bash
git add Dockerfile pind-init.sh
git -c commit.gpgsign=false commit -m "feat: add pind Dockerfile target with rootless podman"
```

---

### Task 2: `pind-init.sh` engine setup

**Files:**
- Modify: `pind-init.sh` (replace the Task 1 stub with the full script)

**Interfaces:**
- Consumes: run as root from entrypoint (Task 3), drops to `vscode` via `gosu`. Reads `DEVCONTAINER_PIND` implicitly (entrypoint gates the call).
- Produces: a running `podman system service` on `unix:///home/vscode/.pind-run/podman.sock`; writes `/etc/profile.d/pind.sh` exporting `DOCKER_HOST` + `XDG_RUNTIME_DIR`; exits 0 only once the socket exists. Storage at `/home/vscode/.local/share/containers`.

- [ ] **Step 1: Write the full `pind-init.sh`**

```bash
cat > pind-init.sh <<'SCRIPT'
#!/bin/bash
# /usr/local/sbin/pind-init.sh
#
# Set up rootless podman inside the dev container. Runs as root from
# entrypoint.sh, drops to vscode for the actual engine config + service.
# Fail-closed: any error => non-zero exit; entrypoint aborts the container.
#
# Podman is daemonless for pulls (they run in the calling vscode process in
# the container main netns), so the engine's own HTTPS_PROXY points at
# 127.0.0.1:8888 directly. Nested containers get their network from
# slirp4netns in vscode's netns; their egress reaches tinyproxy via the
# slirp gateway 10.0.2.2:8888 — same mechanism dind uses. We expose a
# Docker-API-compatible socket via `podman system service` for
# testcontainers / docker-compose / DOCKER_HOST tooling.
set -euo pipefail

RUN_DIR=/home/vscode/.pind-run
SOCK="${RUN_DIR}/podman.sock"
DATA_DIR=/home/vscode/.local/share/containers
CFG_DIR=/home/vscode/.config/containers
LOG=/var/log/podman-service.log

# 1. Allocate subuid/subgid range for vscode. Done at runtime (not in the
#    Dockerfile) because --build-arg USER_UID rewrites the user after the
#    base image is built. Range is conventional and container-local.
if ! grep -q '^vscode:' /etc/subuid; then
    echo "vscode:100000:65536" >> /etc/subuid
fi
if ! grep -q '^vscode:' /etc/subgid; then
    echo "vscode:100000:65536" >> /etc/subgid
fi

# 2. Ensure storage + config dirs exist and are owned by vscode. The named
#    volume (containers storage) comes up empty on first mount.
mkdir -p "$DATA_DIR" "$CFG_DIR"
chown -R vscode:vscode "$DATA_DIR" "$CFG_DIR"

# 3. storage.conf: rootless overlay via fuse-overlayfs.
cat > "$CFG_DIR/storage.conf" <<EOF
[storage]
driver = "overlay"
runroot = "$RUN_DIR/containers"
graphroot = "$DATA_DIR/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF

# 4. containers.conf: pin slirp4netns (NOT podman 5.x's pasta default, whose
#    host-loopback mapping does not expose 10.0.2.2) and inject the proxy env
#    into every nested container so `podman build` RUN steps and `podman run`
#    workloads reach tinyproxy. This is the podman analogue of dind's
#    ~/.docker/config.json proxies block.
cat > "$CFG_DIR/containers.conf" <<EOF
[network]
network_backend = "slirp4netns"

[containers]
env = [
    "http_proxy=http://10.0.2.2:8888",
    "https_proxy=http://10.0.2.2:8888",
    "HTTP_PROXY=http://10.0.2.2:8888",
    "HTTPS_PROXY=http://10.0.2.2:8888",
    "no_proxy=localhost,127.0.0.1,::1",
    "NO_PROXY=localhost,127.0.0.1,::1",
]
EOF
chown -R vscode:vscode "$CFG_DIR"

# 5. Export DOCKER_HOST/XDG_RUNTIME_DIR for interactive (login) shells, and
#    the engine's own-pull proxy (127.0.0.1, main netns).
cat > /etc/profile.d/pind.sh <<EOF
export DOCKER_HOST=unix://${SOCK}
export XDG_RUNTIME_DIR=${RUN_DIR}
export HTTPS_PROXY=http://127.0.0.1:8888
export HTTP_PROXY=http://127.0.0.1:8888
export NO_PROXY=localhost,127.0.0.1
EOF
chmod 644 /etc/profile.d/pind.sh

# 6. RUN_DIR lives under the /home/vscode named volume; stale sockets / state
#    from a previous container look "live". Treat it as ephemeral: wipe on
#    every boot, then recreate locked-down and owned by vscode.
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/containers"
chown -R vscode:vscode "$RUN_DIR"
chmod 0700 "$RUN_DIR"

touch "$LOG"
chown vscode:vscode "$LOG"

# 7. Start `podman system service` as vscode in the background. --time=0 =>
#    no idle-exit timeout (the service stays up for the container lifetime).
#    HTTPS_PROXY here is for podman's own pulls (main netns => 127.0.0.1).
gosu vscode env \
    XDG_RUNTIME_DIR="$RUN_DIR" \
    HOME=/home/vscode \
    HTTPS_PROXY=http://127.0.0.1:8888 \
    HTTP_PROXY=http://127.0.0.1:8888 \
    NO_PROXY=localhost,127.0.0.1 \
    PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    nohup podman system service --time=0 "unix://${SOCK}" \
        > "$LOG" 2>&1 &

# 8. Wait up to 15s for the socket to appear.
for _ in $(seq 1 30); do
    if [ -S "$SOCK" ]; then
        # stderr, not stdout: keep `dev -- <cmd>` payload output clean.
        echo "pind-init: podman service socket ready at $SOCK" >&2
        exit 0
    fi
    sleep 0.5
done

echo "FATAL: podman system service did not produce a socket at $SOCK within 15s" >&2
echo "--- last 50 lines of $LOG ---" >&2
tail -50 "$LOG" >&2 || true
exit 1
SCRIPT
chmod +x pind-init.sh
```

- [ ] **Step 2: Lint the script**

Run: `bash scripts/lint.sh`
Expected: PASS (shellcheck clean on `pind-init.sh`).

- [ ] **Step 3: Rebuild the image so the real script is baked in**

Run: `docker build --network=host --target pind -t generic-devcontainer:pind .`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add pind-init.sh
git -c commit.gpgsign=false commit -m "feat: implement pind-init.sh podman engine setup"
```

---

### Task 3: entrypoint.sh routing

**Files:**
- Modify: `entrypoint.sh` (add a `DEVCONTAINER_PIND` branch immediately after the existing `DEVCONTAINER_DIND` branch, ~line 77)

**Interfaces:**
- Consumes: `DEVCONTAINER_PIND` env (set by `dev` in Task 5).
- Produces: runs `/usr/local/sbin/pind-init.sh`, exports `DOCKER_HOST` + `XDG_RUNTIME_DIR` into the entrypoint env so non-login `gosu vscode CMD` children see them.

- [ ] **Step 1: Add the pind branch**

After the closing `fi` of the `if [ -n "${DEVCONTAINER_DIND:-}" ]; then` block, insert:

```bash
# --- PinD mode: launch rootless podman system service ---
if [ -n "${DEVCONTAINER_PIND:-}" ]; then
    if ! /usr/local/sbin/pind-init.sh; then
        echo "FATAL: pind-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    # Export to entrypoint's env so non-login children (gosu vscode CMD) see
    # DOCKER_HOST / XDG_RUNTIME_DIR. pind-init.sh also writes these to
    # /etc/profile.d/pind.sh for login shells.
    export DOCKER_HOST=unix:///home/vscode/.pind-run/podman.sock
    export XDG_RUNTIME_DIR=/home/vscode/.pind-run
fi
```

- [ ] **Step 2: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 3: Rebuild pind image (entrypoint is baked at base layer)**

Run: `docker build --network=host --target pind -t generic-devcontainer:pind .`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add entrypoint.sh
git -c commit.gpgsign=false commit -m "feat: route pind mode in entrypoint"
```

---

### Task 4: firewall-init.sh allowlist merge for pind

**Files:**
- Modify: `firewall-init.sh:24-25` (the allowlist-merge block)

**Interfaces:**
- Consumes: `DEVCONTAINER_DIND` / `DEVCONTAINER_PIND` env.
- Produces: `allowlist.dind` merged into the tinyproxy filter when EITHER nested mode is active.

- [ ] **Step 1: Broaden the merge condition**

Change the existing block:

```bash
    if [ -n "${DEVCONTAINER_DIND:-}" ] && [ -f /etc/devcontainer/allowlist.dind ]; then
        cat /etc/devcontainer/allowlist.dind
```

to:

```bash
    if { [ -n "${DEVCONTAINER_DIND:-}" ] || [ -n "${DEVCONTAINER_PIND:-}" ]; } \
       && [ -f /etc/devcontainer/allowlist.dind ]; then
        cat /etc/devcontainer/allowlist.dind
```

- [ ] **Step 2: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add firewall-init.sh
git -c commit.gpgsign=false commit -m "feat: merge registry allowlist for pind mode"
```

---

### Task 5: `dev` + lifecycle wiring (`--pind` flag, image, name, volume, mutex)

**Files:**
- Modify: `dev` (arg parsing ~line 529 and ~644; `PIND=false` init ~line 206; name resolution ~line 471–477 and 752; image/target/name selection ~line 738–765; four-way mutex ~line 681–686)
- Modify: `lib/dev/lifecycle.sh:326-346` (gate shared block on `DIND || PIND`, add pind volume + env)

**Interfaces:**
- Consumes: `PIND` bash var.
- Produces: `./dev --pind` builds/uses `generic-devcontainer:pind`, container `dev-<dir>-pind`, volume `devcontainer-pind:/home/vscode/.local/share/containers`, env `DEVCONTAINER_PIND=1`. Refuses when `--dind` or `--maintenance` is combined, and when a conflicting-mode container is already running.

- [ ] **Step 1: Add `PIND=false` init**

In `dev` next to `DIND=false` (~line 206):

```bash
PIND=false
```

- [ ] **Step 2: Parse `--pind` in both arg loops**

In the scaffold-args loop (next to `--dind) DIND=true; shift ;;` ~line 529):

```bash
        --pind) PIND=true; shift ;;
```

In the main arg loop (next to the `--dind)` case ~line 644):

```bash
    --pind)
      PIND=true
      shift
      ;;
```

- [ ] **Step 3: Add the four-way mutex guard**

Replace the existing dind/maintenance guard (~line 685):

```bash
if [[ "$DIND" == true && "$MAINTENANCE" == true ]]; then
  echo "Error: --dind and --maintenance are mutually exclusive." >&2
```

with a block covering all three flag pairs:

```bash
if [[ "$DIND" == true && "$MAINTENANCE" == true ]]; then
  echo "Error: --dind and --maintenance are mutually exclusive." >&2
  exit 1
fi
if [[ "$PIND" == true && "$MAINTENANCE" == true ]]; then
  echo "Error: --pind and --maintenance are mutually exclusive." >&2
  exit 1
fi
if [[ "$PIND" == true && "$DIND" == true ]]; then
  echo "Error: --pind and --dind are mutually exclusive." >&2
  exit 1
fi
```

(Delete the now-duplicated `exit 1`/`fi` from the original block so only one remains.)

- [ ] **Step 4: Resolve `PIND_NAME` where `DIND_NAME` is resolved**

Next to each `DIND_NAME="dev-${WORKSPACE_BASENAME}-dind"` occurrence (~line 477 and ~line 752):

```bash
PIND_NAME="dev-${WORKSPACE_BASENAME}-pind"
```

- [ ] **Step 5: Select image/target/name for pind**

In the image/target selection block (~line 738), after the `if [[ "$DIND" == true ]]; then ... fi`:

```bash
if [[ "$PIND" == true ]]; then
  IMAGE_TAG="${IMAGE_NAME}:pind"
  BUILD_TARGET="pind"
fi
```

In the container-name selection (~line 755), add a pind branch and its cross-mode refusals:

```bash
elif [[ "$PIND" == true ]]; then
  CONTAINER_NAME="$PIND_NAME"
  refuse_if_running "$NORMAL_NAME" "normal"
  refuse_if_running "$MAINT_NAME" "maintenance"
  refuse_if_running "$DIND_NAME" "dind" "$DIND_RUNTIME_ARGS"
```

Also add `refuse_if_running "$PIND_NAME" "pind"` to the normal, maintenance, and dind branches so those modes refuse when a pind container is running.

- [ ] **Step 6: Gate the shared device block on `DIND || PIND` and add pind volume/env**

In `lib/dev/lifecycle.sh`, change `if [[ "$DIND" == true ]]; then` (line 326) to:

```bash
  if [[ "$DIND" == true || "$PIND" == true ]]; then
```

Inside that block, the `devcontainer-dind` volume mount (line 345) is dind-specific — replace the single mount line with a per-mode mount:

```bash
    if [[ "$DIND" == true ]]; then
      DOCKER_CMD+=(-v devcontainer-dind:/home/vscode/.local/share/docker)
    else
      DOCKER_CMD+=(-v devcontainer-pind:/home/vscode/.local/share/containers)
    fi
```

Add the pind env signal next to the dind one (~line 412):

```bash
  if [[ "$PIND" == true ]]; then
    DOCKER_CMD+=(-e DEVCONTAINER_PIND=1)
  fi
```

- [ ] **Step 7: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 8: Smoke-test the flag end to end**

Run: `./dev --pind -- podman version`
Expected: prints podman client + server (service) versions; exit 0. (First run builds the pind image.)

- [ ] **Step 9: Commit**

```bash
git add dev lib/dev/lifecycle.sh
git -c commit.gpgsign=false commit -m "feat: wire --pind flag, container, volume, and mutex into dev"
```

---

### Task 6: Preflights extend to pind

**Files:**
- Modify: `lib/dev/preflight.sh` (the callers `preflight_apparmor_userns` at `dev:690` and the subid preflight; extend their trigger to include `PIND`)

**Interfaces:**
- Consumes: `DIND` / `PIND` vars.
- Produces: apparmor + subid preflights run for `--pind` exactly as for `--dind`.

- [ ] **Step 1: Find the current trigger conditions**

Run: `grep -n "DIND" dev lib/dev/preflight.sh`
Expected: shows where `preflight_apparmor_userns` and `preflight_subid_grant` (or inline subid check) are gated on `$DIND`.

- [ ] **Step 2: Broaden each `$DIND`-only preflight trigger**

For each preflight call/guard currently gated as `if [[ "$DIND" == true ]]`, change to:

```bash
  if [[ "$DIND" == true || "$PIND" == true ]]; then
```

(Apply to the apparmor preflight guard and the subid-grant preflight guard. Leave any dind-storage-connection resolution — the macOS `DIND_RUNTIME_ARGS` block — as-is unless Step 3 shows pind needs it.)

- [ ] **Step 3: Decide macOS+podman rootful-connection routing for pind**

The dind mode routes `--dind` through the rootful podman connection on macOS because rootless podman drops `/dev/net/tun`. pind uses the same slirp4netns/tun path, so it needs the same routing. If `RUNTIME_ARGS`/`DIND_RUNTIME_ARGS` is set for dind under `[[ "$(uname -s)" == "Darwin" && "$RUNTIME" == "podman" ]]`, extend the `RUNTIME_ARGS="$DIND_RUNTIME_ARGS"` assignment (currently under `if [[ "$DIND" == true ]]`) to also fire for `PIND`:

```bash
if [[ "$DIND" == true || "$PIND" == true ]]; then
  IMAGE_TAG=...   # already set per-mode in Task 5
  RUNTIME_ARGS="$DIND_RUNTIME_ARGS"
fi
```

(On Linux `DIND_RUNTIME_ARGS` is empty, so this is a no-op there.)

- [ ] **Step 4: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add dev lib/dev/preflight.sh
git -c commit.gpgsign=false commit -m "feat: apply apparmor and subid preflights to pind mode"
```

---

### Task 7: `./dev scaffold --pind`

**Files:**
- Modify: `lib/dev/scaffold.sh` (emit pind `.devcontainer/` when the scaffold PIND flag is set)

**Interfaces:**
- Consumes: `PIND` var (parsed in the scaffold arg loop in Task 5 Step 2).
- Produces: a `.devcontainer/` referencing `generic-devcontainer:pind`, `DEVCONTAINER_PIND=1`, and the same `--device`/`--security-opt` run args the dind scaffold uses.

- [ ] **Step 1: Inspect the current dind scaffold branch**

Run: `grep -n "DIND\|dind\|DEVCONTAINER_DIND\|IMAGE\|--device\|--security" lib/dev/scaffold.sh`
Expected: shows the dind image tag + env + run-arg emission.

- [ ] **Step 2: Add a pind branch mirroring dind**

Wherever the scaffold picks the image tag / env / run args based on `$DIND`, add the `$PIND` equivalent: image `generic-devcontainer:pind`, `"DEVCONTAINER_PIND": "1"`, and the identical `--device=/dev/fuse`, `--device=/dev/net/tun`, `--security-opt apparmor=unconfined`, `seccomp=unconfined`, `systempaths=unconfined`, `label=disable`, `--cap-add=SYS_ADMIN` run args (these are shared between dind and pind). Keep the `kernel.apparmor_restrict_unprivileged_userns=0` comment.

- [ ] **Step 3: Test scaffold output**

Run: `cd "$(mktemp -d)" && /path/to/repo/dev scaffold --pind && cat .devcontainer/devcontainer.json | jq '.image, .containerEnv.DEVCONTAINER_PIND'`
Expected: image ends in `:pind`; `DEVCONTAINER_PIND` == `"1"`.

- [ ] **Step 4: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/dev/scaffold.sh
git -c commit.gpgsign=false commit -m "feat: scaffold pind .devcontainer via dev scaffold --pind"
```

---

### Task 8: Generalize `verify-firewall.sh` checks 8–12

**Files:**
- Modify: `scripts/verify-firewall.sh:59-113` (dind-aware helpers + the SKIP_UNLESS_DIND gating)

**Interfaces:**
- Consumes: `DEVCONTAINER_DIND` / `DEVCONTAINER_PIND`.
- Produces: checks 8–12 run under either nested mode; probe commands branch on which engine is active.

- [ ] **Step 1: Generalize the activation helper**

Change `dind_active()` (line 60) to a nested-runtime helper:

```bash
nested_active() { [ -n "${DEVCONTAINER_DIND:-}" ] || [ -n "${DEVCONTAINER_PIND:-}" ]; }
# Which engine? Both expose a Docker-API socket at DOCKER_HOST, so probes
# use `docker`/socket calls uniformly; podman ships a `docker` shim only if
# aliased, so prefer the socket via DOCKER_HOST for pulls.
nested_engine() { if [ -n "${DEVCONTAINER_PIND:-}" ]; then echo podman; else echo docker; fi; }
```

- [ ] **Step 2: Branch the probe commands**

For each of `dockerd_reachable`, `dockerd_rootless`, `nested_pull_works`, `nested_egress_blocked`, `nested_loopback_works`, branch on `nested_engine`. Example for the pull check:

```bash
nested_pull_works() {
    if [ "$(nested_engine)" = podman ]; then
        podman pull alpine:3.20 >/dev/null 2>&1
    else
        docker pull alpine:3.20 >/dev/null 2>&1
    fi
}
```

Apply the analogous `podman` vs `docker` branch to the other four helpers (service reachable => `podman info` vs `docker info`; rootless => `podman info --format '{{.Host.Security.Rootless}}'` returns `true` vs the docker rootless check already present; egress-blocked and loopback => `podman run`/`docker run` with the same wget probes).

- [ ] **Step 3: Rename the skip gate**

Replace the `SKIP_UNLESS_DIND=1` prefix on checks 8–12 (lines 111–113 and the two below) with a `SKIP_UNLESS_NESTED=1` prefix, and update the `run_check` skip logic that reads that variable to call `nested_active`.

- [ ] **Step 4: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 5: Run the probe under pind**

Run: `./dev --pind -- bash /workspace/scripts/verify-firewall.sh`
Expected: checks 1–7 pass (firewall posture); checks 8–12 pass (podman service reachable, rootless, pull through proxy, nested egress blocked, nested loopback works).

- [ ] **Step 6: Regression — run under dind**

Run: `./dev --dind -- bash /workspace/scripts/verify-firewall.sh`
Expected: all checks still pass (dind unchanged).

- [ ] **Step 7: Commit**

```bash
git add scripts/verify-firewall.sh
git -c commit.gpgsign=false commit -m "test: generalize firewall verify checks 8-12 to pind"
```

---

### Task 9: `scripts/verify-pind.sh`

**Files:**
- Create: `scripts/verify-pind.sh` (sibling of `scripts/verify-dind.sh`)

**Interfaces:**
- Consumes: runs inside a `--pind` container; uses `podman` + `DOCKER_HOST` compat socket.
- Produces: exit 0 on all probes passing; each probe prints a pass/fail line.

- [ ] **Step 1: Inspect the dind probe to mirror its structure**

Run: `cat scripts/verify-dind.sh`
Expected: shows the smoke-build / testcontainers / self-build structure and its pass/fail helpers.

- [ ] **Step 2: Write `verify-pind.sh`**

Mirror `verify-dind.sh`, swapping `docker` for `podman` and asserting the compat socket works:

```bash
#!/bin/bash
# scripts/verify-pind.sh — heavier in-container checks for --pind mode.
# Run inside a pind container: ./dev --pind -- bash /workspace/scripts/verify-pind.sh
set -u

fail=0
pass() { echo "PASS: $1"; }
die()  { echo "FAIL: $1"; fail=1; }

# 1. podman pull + run through the proxy allowlist.
if podman run --rm alpine:3.20 true; then pass "podman run alpine"; else die "podman run alpine"; fi

# 2. Docker-API compat socket reachable (testcontainers / docker-compose path).
if docker -H "$DOCKER_HOST" info >/dev/null 2>&1; then
    pass "compat socket (DOCKER_HOST) reachable"
else
    die "compat socket (DOCKER_HOST) not reachable"
fi

# 3. postgres testcontainers-style smoke: start postgres, wait for readiness.
cid=$(podman run -d -e POSTGRES_PASSWORD=pw docker.io/library/postgres:16-alpine)
ok=0
for _ in $(seq 1 30); do
    if podman exec "$cid" pg_isready -U postgres >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
done
podman rm -f "$cid" >/dev/null 2>&1
if [ "$ok" = 1 ]; then pass "postgres smoke"; else die "postgres smoke"; fi

# 4. self-build of this repo's Dockerfile base target with podman build.
if podman build --network=host --target base -t pind-selfbuild /workspace >/dev/null 2>&1; then
    pass "self-build of base target"
else
    die "self-build of base target"
fi

exit "$fail"
```

- [ ] **Step 3: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 4: Run it**

Run: `./dev --pind -- bash /workspace/scripts/verify-pind.sh`
Expected: four `PASS:` lines, exit 0. (If the postgres or self-build probe needs a registry not yet allowlisted, add the host to `allowlist.dind` and note it — do NOT silently skip.)

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-pind.sh
git -c commit.gpgsign=false commit -m "test: add verify-pind.sh in-container probe"
```

---

### Task 10: e2e scenario — pind nested-egress firewall probe

**Files:**
- Create: `scripts/test/scenarios/34-attack-nested-egress-pind.sh` (sibling of `33-attack-nested-egress.sh`)

**Interfaces:**
- Consumes: the e2e harness helpers (`assert.sh`, `restore.sh`), `$RUNTIME`.
- Produces: `log_pass`/`log_fail` — a nested podman container must be BLOCKED from reaching a non-allowlisted host.

- [ ] **Step 1: Write the scenario**

```bash
cat > scripts/test/scenarios/34-attack-nested-egress-pind.sh <<'EOF'
#!/bin/bash
# scripts/test/scenarios/34-attack-nested-egress-pind.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
P="dev-${WS}-pind"
remember_container "$P"
"$RUNTIME" rm -f "$P" 2>/dev/null

./dev --pind -- podman pull alpine:3.20 >/dev/null 2>&1 || true

out=$(./dev --pind -- podman run --rm alpine:3.20 \
    wget -T3 -q -O- https://example.com 2>&1 || echo BLOCKED)
if expect_grep "$out" "BLOCKED"; then
    log_pass "nested podman container blocked from reaching example.com"
    exit 0
fi
log_fail "nested podman container reached example.com (firewall is broken); got: $out"
exit 1
EOF
chmod +x scripts/test/scenarios/34-attack-nested-egress-pind.sh
```

- [ ] **Step 2: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 3: Run the scenario**

Run: `bash scripts/test/scenarios/34-attack-nested-egress-pind.sh`
Expected: `PASS` line (nested podman container blocked).

- [ ] **Step 4: Commit**

```bash
git add scripts/test/scenarios/34-attack-nested-egress-pind.sh
git -c commit.gpgsign=false commit -m "test: add pind nested-egress firewall scenario"
```

---

### Task 11: Extend mutex + preflight scenarios to pind

**Files:**
- Modify: `scripts/test/scenarios/20-mode-conflict-pairs.sh` (add pind pairs)
- Modify: `scripts/test/scenarios/16-rootless-subid-preflight.sh` and `scripts/test/scenarios/15-apparmor-userns-restrict.sh` (add a `--pind` case)

**Interfaces:**
- Consumes: e2e harness.
- Produces: pind is proven mutually exclusive with dind + maintenance, and pind triggers the same preflights.

- [ ] **Step 1: Add pind to the mutex matrix**

In `20-mode-conflict-pairs.sh`, after resolving names add `P="dev-${WS}-pind"; remember_container "$P"`, include `$P` in the `rm -f` cleanups, and add pairs:

```bash
# Pair 5: normal running -> --pind refused.
"$RUNTIME" rm -f "$N" "$M" "$D" "$P" 2>/dev/null
run_bg ./dev -- sleep 60
refuse_flag_due_to --pind "$N" || exit 1
"$RUNTIME" stop "$N" 2>/dev/null; "$RUNTIME" rm -f "$N" 2>/dev/null

# Pair 6: --pind running -> normal, --dind, --maintenance refused.
run_bg ./dev --pind -- sleep 60
sleep 6   # podman service startup
refuse_normal_due_to "$P" || exit 1
refuse_flag_due_to --dind "$P" || exit 1
refuse_flag_due_to --maintenance "$P" || exit 1
"$RUNTIME" stop "$P" 2>/dev/null; "$RUNTIME" rm -f "$P" 2>/dev/null

# Pair 7: --pind with --dind / --maintenance in one invocation are rejected.
"$RUNTIME" rm -f "$N" "$M" "$D" "$P" 2>/dev/null
if out=$(./dev --pind --dind -- true 2>&1); then
    log_fail "--pind --dind together should have been rejected"; exit 1
fi
expect_grep "$out" "mutually exclusive" \
    || { log_fail "expected mutual-exclusivity error; got: $out"; exit 1; }
if out=$(./dev --pind --maintenance -- true 2>&1); then
    log_fail "--pind --maintenance together should have been rejected"; exit 1
fi
expect_grep "$out" "mutually exclusive" \
    || { log_fail "expected mutual-exclusivity error; got: $out"; exit 1; }
```

Update the final `log_pass` message to mention the four-way guard.

- [ ] **Step 2: Add a `--pind` case to the subid + apparmor preflight scenarios**

In `16-rootless-subid-preflight.sh` and `15-apparmor-userns-restrict.sh`, wherever the scenario asserts the preflight fires for `--dind`, duplicate the assertion for `--pind` (same expected error text). Read each scenario first (`cat scripts/test/scenarios/16-rootless-subid-preflight.sh`) and mirror its exact assertion structure — do not invent a new one.

- [ ] **Step 3: Lint**

Run: `bash scripts/lint.sh`
Expected: PASS.

- [ ] **Step 4: Run the extended scenarios**

Run: `bash scripts/test/scenarios/20-mode-conflict-pairs.sh`
Expected: `PASS` (four-way guard correct).

- [ ] **Step 5: Commit**

```bash
git add scripts/test/scenarios/20-mode-conflict-pairs.sh scripts/test/scenarios/16-rootless-subid-preflight.sh scripts/test/scenarios/15-apparmor-userns-restrict.sh
git -c commit.gpgsign=false commit -m "test: extend mutex and preflight scenarios to pind"
```

---

### Task 12: Documentation

**Files:**
- Modify: `README.md` (add a `--pind` section parallel to `--dind`)
- Modify: `CLAUDE.md` ("Build and Run" + "Opt-in Docker-in-Docker" + Key Design Decisions)

**Interfaces:**
- Produces: user-facing docs for `--pind`.

- [ ] **Step 1: Add the CLAUDE.md build/run entry**

In the "Build and Run" fenced block, after the `--dind` entry:

```bash
# Rootless Podman-in-Podman (separate :pind image, dev-<dir>-pind container).
# Daemonless engine; exposes a Docker-API compat socket (DOCKER_HOST) for
# testcontainers / docker-compose. Mutually exclusive with --dind and
# --maintenance.
./dev --pind
```

- [ ] **Step 2: Add a Key Design Decisions bullet**

Append to the DinD design-decision bullet a sibling note:

```markdown
- **Opt-in Podman-in-Podman** via `./dev --pind`. Builds a separate
  `generic-devcontainer:pind` image (the `pind` target) adding rootless
  `podman`, fuse-overlayfs, and slirp4netns. Container `dev-<dir>-pind`,
  cache volume `devcontainer-pind:/home/vscode/.local/share/containers`.
  Podman is daemonless, so its own image pulls route through the proxy at
  `127.0.0.1:8888` in the container's main netns; nested-container egress
  routes through `10.0.2.2:8888` via slirp4netns (backend pinned; podman
  5.x's pasta default is not used). A `podman system service` unix socket
  provides Docker-API compatibility. Mutually exclusive with `--dind` and
  `--maintenance` (four-way guard).
```

- [ ] **Step 3: Add the README `--pind` section**

Mirror the README's `--dind` section: what it is, when to use it, the compat socket, the slirp4netns pin, the shared apparmor/subid preflights, and that it is mutually exclusive with `--dind`/`--maintenance`. Read the existing `--dind` README section first and match its depth and tone.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git -c commit.gpgsign=false commit -m "docs: document --pind podman-in-podman mode"
```

---

### Task 13: Full e2e matrix regression

**Files:** none (verification only)

- [ ] **Step 1: Run the full matrix**

Run: `sudo bash scripts/test/run-all.sh`
Expected: pass/fail table shows all previously-passing scenarios still pass, plus the new `34-attack-nested-egress-pind.sh` and the extended `20`/`16`/`15` scenarios pass. dind scenarios (`21`, `33`) unchanged. Logs at `scripts/test/last-run.log` / `last-summary.log`.

- [ ] **Step 2: If any dind scenario regressed, stop and fix**

dind must be behaviorally unchanged (Global Constraint). Any dind regression is a blocker — investigate before proceeding.

- [ ] **Step 3: No commit** (verification task; nothing to commit unless a fix was needed)

---

## Notes for the implementer

- **The slirp4netns nested-egress path (Task 2 §4, Task 10) is the load-bearing unknown.** If a nested `podman build`/`run` can't reach `10.0.2.2:8888`, the fallback is pasta with `--map-guest-addr` (spec §"The one real risk"). Validate Task 10 early; if it fails, resolve the networking before layering the rest.
- **Do not silently skip a probe** that fails because a registry host isn't allowlisted — add the host to `allowlist.dind` and note it (per the firewall's fail-closed philosophy).
- Each `./dev --pind` first-run builds the `:pind` image (minutes). Subsequent runs reuse it.
