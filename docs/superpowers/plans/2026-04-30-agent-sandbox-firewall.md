# Agent Sandbox Firewall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Constrain outbound traffic from inside the dev container to a curated allowlist of domains, with a `--maintenance` mode that disables the firewall and grants sudo for admin tasks.

**Architecture:** Default-deny iptables on `OUTPUT`, with a hostname-filtering `tinyproxy` as the only allowed path to `:80`/`:443`. iptables `-m owner --uid-owner proxy` ensures only the `proxy` system user can reach those ports, so an agent running as `vscode` cannot bypass the proxy via raw sockets. `vscode` has no sudo in normal mode, removing any path to root and thus any path to disable iptables. `--maintenance` mode flips both knobs off and uses a separate container name (`dev-<dir>-maint`) to avoid clashing with normal mode.

**Tech Stack:** Bash, Docker, iptables, tinyproxy, gosu. No test framework — verification via a packaged `verify-firewall.sh` helper plus per-task manual checks.

**Spec:** [`docs/superpowers/specs/2026-04-30-agent-sandbox-firewall-design.md`](../specs/2026-04-30-agent-sandbox-firewall-design.md)

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `allowlist.base` | new | Base allowlist of approved domains, baked into the image |
| `firewall-init.sh` | new | Merge allowlists, configure tinyproxy, apply iptables (runs as root at startup) |
| `scripts/verify-firewall.sh` | new | In-container helper that probes firewall posture and reports pass/fail |
| `Dockerfile` | modify | Install firewall packages, create `proxy` user, remove vscode sudo, drop trailing `USER vscode` |
| `entrypoint.sh` | modify | Branch on `DEVCONTAINER_MAINTENANCE`, run firewall-init, drop privileges via gosu |
| `dev` | modify | Add `--maintenance` flag, container name suffix, conflict guard, `--cap-add=NET_ADMIN`, env passthrough |
| `README.md` | modify | Document the firewall feature, allowlist files, maintenance mode |

---

## Task 1: Install firewall dependencies and the base allowlist

Adds packages and the static base allowlist file. No behavior change yet — `dev` should still work exactly as before. This is the foundation; later tasks wire it up.

**Files:**
- Create: `allowlist.base`
- Modify: `Dockerfile`

- [ ] **Step 1: Create the base allowlist file**

Create `/workspace/allowlist.base` with this content:

```text
# Anthropic
api.anthropic.com

# GitHub (HTTPS clone, API, raw, releases)
github.com
api.github.com
codeload.github.com
*.githubusercontent.com
ghcr.io

# Package registries
*.npmjs.org
pypi.org
files.pythonhosted.org
crates.io
static.crates.io

# mise / language runtimes
mise.jdx.dev
nodejs.org
*.nodejs.org

# OS packages
deb.debian.org
security.debian.org
archive.ubuntu.com
security.ubuntu.com
```

- [ ] **Step 2: Add apt installs to the Dockerfile**

In `Dockerfile`, immediately after the `ARG USER_UID=1000` block and before the `RUN curl -fsSL https://mise.run ...` line, insert:

```dockerfile
# Install firewall stack and supporting tools.
# - iptables/ipset: kernel-level packet filtering
# - tinyproxy: hostname-filtering forward proxy
# - dnsutils: getent/dig for diagnostics
# - gosu: clean privilege drop in the entrypoint
# - iproute2: 'ss' for tinyproxy bind verification
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        tinyproxy \
        dnsutils \
        gosu \
        iproute2 && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 3: Verify the image still builds**

Run: `cd /workspace && docker build -t generic-devcontainer .`
Expected: build succeeds; new apt step shows packages installed.

- [ ] **Step 4: Verify dev still works unchanged**

Run: `cd /workspace && ./dev -- bash -c 'which tinyproxy && which gosu'`
Expected: `/usr/sbin/tinyproxy` and `/usr/sbin/gosu` printed; container starts and exits cleanly. `dev` behavior is otherwise unchanged.

- [ ] **Step 5: Commit**

```bash
git add allowlist.base Dockerfile
git -c commit.gpgsign=false commit -m "add firewall dependencies and base allowlist

Installs iptables, ipset, tinyproxy, dnsutils, gosu, iproute2 in the
image, and adds allowlist.base. Nothing wires them up yet — that
arrives in subsequent commits."
```

---

## Task 2: Stage allowlist and firewall-init.sh in the image

Creates the firewall init script and stages it (plus the allowlist) into the image. The `proxy` system user is also created. Still nothing calls it — but you can manually invoke it inside a container to test.

**Files:**
- Create: `firewall-init.sh`
- Modify: `Dockerfile`

- [ ] **Step 1: Create firewall-init.sh**

Create `/workspace/firewall-init.sh` (mode 755) with this content:

```bash
#!/bin/bash
# /usr/local/sbin/firewall-init.sh
#
# Configure tinyproxy and iptables to enforce a hostname allowlist.
# Runs as root at container startup.  Fail-closed: any error => non-zero exit.
set -euo pipefail

BASE=/etc/devcontainer/allowlist.base
PROJECT=/workspace/.devcontainer-allowlist
FILTER=/etc/tinyproxy/filter
CONF=/etc/tinyproxy/tinyproxy.conf

mkdir -p /etc/tinyproxy /var/log /run

# --- Merge base + project allowlist into a tinyproxy regex filter ---
{
    cat "$BASE"
    [ -f "$PROJECT" ] && cat "$PROJECT"
} | sed 's/#.*//'           \
  | tr -d ' \t'             \
  | grep -v '^$'            \
  | sort -u                 \
  | while IFS= read -r entry; do
        # *.foo.com  -> ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.foo\.com$
        # foo.com    -> ^foo\.com$
        if [[ "$entry" == \*.* ]]; then
            tail="${entry#*.}"
            escaped="${tail//./\\.}"
            printf '^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.%s$\n' "$escaped"
        else
            escaped="${entry//./\\.}"
            printf '^%s$\n' "$escaped"
        fi
    done > "$FILTER"

if [ ! -s "$FILTER" ]; then
    echo "firewall-init: refusing to start with an empty filter" >&2
    exit 1
fi

# --- Write tinyproxy config ---
cat > "$CONF" <<'EOF'
User proxy
Group proxy
Port 8888
Listen 127.0.0.1
PidFile "/run/tinyproxy.pid"
LogFile "/var/log/tinyproxy.log"
LogLevel Notice
MaxClients 100
Timeout 600

Filter "/etc/tinyproxy/filter"
FilterDefaultDeny Yes
FilterExtended Yes
FilterURLs No
EOF

touch /var/log/tinyproxy.log
chown proxy:proxy /var/log/tinyproxy.log
chmod 0755 /run

# --- Start tinyproxy (daemonizes by default) ---
if ! tinyproxy -c "$CONF"; then
    echo "firewall-init: tinyproxy failed to start" >&2
    exit 1
fi

# Wait briefly for tinyproxy to bind 127.0.0.1:8888
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ss -lnt 'sport = :8888' 2>/dev/null | grep -q ':8888'; then
        break
    fi
    sleep 0.2
done
if ! ss -lnt 'sport = :8888' 2>/dev/null | grep -q ':8888'; then
    echo "firewall-init: tinyproxy did not bind to 127.0.0.1:8888" >&2
    exit 1
fi

# --- Apply iptables rules ---
PROXY_UID="$(id -u proxy)"

# Reset OUTPUT chain (idempotent across container restarts)
iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
iptables -P INPUT ACCEPT   # docker port forwarding lives here

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" \
                  -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

echo "firewall-init: ready ($(wc -l < "$FILTER") allowlist entries, proxy uid=$PROXY_UID)"
```

- [ ] **Step 2: Add proxy user and file copies to the Dockerfile**

In `Dockerfile`, immediately before the `WORKDIR /workspace` line (which is shortly before `COPY --chmod=755 entrypoint.sh /entrypoint.sh`), insert:

```dockerfile
# --- Firewall staging ---
# Create the 'proxy' system user that owns the tinyproxy process.
# iptables -m owner uses this UID to allow only the proxy process out on 80/443.
USER root
RUN useradd --system --no-create-home --shell /usr/sbin/nologin proxy && \
    mkdir -p /etc/devcontainer

# Bake the base allowlist and the firewall init script into the image.
COPY allowlist.base /etc/devcontainer/allowlist.base
COPY --chmod=755 firewall-init.sh /usr/local/sbin/firewall-init.sh
```

- [ ] **Step 3: Build the image**

Run: `cd /workspace && docker build -t generic-devcontainer .`
Expected: build succeeds.

- [ ] **Step 4: Verify the staging is correct**

Run:
```bash
cd /workspace && ./dev -- bash -c '
  ls -l /usr/local/sbin/firewall-init.sh /etc/devcontainer/allowlist.base &&
  id proxy
'
```

Expected output includes:
- `/usr/local/sbin/firewall-init.sh` is executable
- `/etc/devcontainer/allowlist.base` exists
- `id proxy` prints something like `uid=999(proxy) gid=999(proxy) groups=999(proxy)`

- [ ] **Step 5: Manually exercise firewall-init.sh inside the container**

The vscode user still has passwordless sudo at this point (we remove it in Task 5), so we can use sudo to invoke firewall-init.sh and verify it runs cleanly. **Note:** this requires `--cap-add=NET_ADMIN`; until Task 4 wires that into `dev`, run docker manually:

Run:
```bash
docker run --rm --cap-add=NET_ADMIN -v "$(pwd):/workspace" \
    generic-devcontainer \
    bash -c 'sudo /usr/local/sbin/firewall-init.sh && \
             curl -sS -x http://127.0.0.1:8888 https://api.github.com/zen && echo'
```

Expected: prints `firewall-init: ready (...)`, then a GitHub zen quote. If you instead see "tinyproxy did not bind", check `/var/log/tinyproxy.log` inside the container.

- [ ] **Step 6: Commit**

```bash
git add firewall-init.sh Dockerfile
git -c commit.gpgsign=false commit -m "stage firewall-init.sh and proxy user in image

Adds the firewall init script and the 'proxy' system user to the image.
Nothing calls firewall-init.sh yet — the entrypoint changes land in
the next commit."
```

---

## Task 3: Restructure entrypoint to root-then-drop with gosu

Rewrites `entrypoint.sh` to run as root, perform user-context steps via `gosu vscode`, and drop privileges at the end. Drops the trailing `USER vscode` from the Dockerfile so `entrypoint.sh` actually runs as root. Still no firewall — that's Task 4.

**Files:**
- Modify: `Dockerfile`
- Modify: `entrypoint.sh`

- [ ] **Step 1: Drop the trailing USER vscode from the Dockerfile**

Find the section near the bottom of `Dockerfile`:

```dockerfile
# Stage reference copy of managed home files for entrypoint sync
USER root
RUN mkdir -p /etc/skel.devcontainer && \
    cp /home/vscode/.zshrc /etc/skel.devcontainer/.zshrc
USER vscode
```

Change it to (remove the trailing `USER vscode`):

```dockerfile
# Stage reference copy of managed home files for entrypoint sync
USER root
RUN mkdir -p /etc/skel.devcontainer && \
    cp /home/vscode/.zshrc /etc/skel.devcontainer/.zshrc
```

The image now leaves `USER root` set; entrypoint runs as root and drops privileges itself.

- [ ] **Step 2: Rewrite entrypoint.sh**

Replace the contents of `/workspace/entrypoint.sh` with:

```bash
#!/bin/bash
set -u

# entrypoint.sh runs as root. It runs user-context tasks via gosu vscode,
# then exec's gosu vscode for the actual command. The firewall hook (Task 4)
# slots in at the top of this file.

# Run user-context startup tasks as vscode (preserves file ownership under
# /home/vscode and /mise; ensures 'git config --global' lands in
# /home/vscode/.gitconfig).
gosu vscode bash <<'INNER'
set -u

# Ensure mise shell activation is present in .zshrc (idempotent).
if [[ -f /home/vscode/.zshrc ]] && ! grep -q 'mise activate zsh' /home/vscode/.zshrc; then
    # shellcheck disable=SC2016
    echo 'eval "$(mise activate zsh)"' >> /home/vscode/.zshrc
fi

# Try to install mise-managed tools if a project mise.toml exists.
if [[ -f /workspace/mise.toml ]] || [[ -f /workspace/.mise.toml ]]; then
    if ! mise install; then
        echo "WARNING: mise install failed, but continuing with container startup" >&2
    fi
fi

# Configure git to trust /workspace as a safe directory.
git config --global --add safe.directory /workspace
INNER

# Drop privileges to vscode for the actual command.
exec gosu vscode "$@"
```

- [ ] **Step 3: Rebuild the image**

Run: `cd /workspace && ./dev --build -- whoami`
Expected: image rebuilds; final output is `vscode`.

- [ ] **Step 4: Verify ownership of files written by the entrypoint**

Run:
```bash
cd /workspace && ./dev -- bash -c '
  ls -ld /home/vscode/.zshrc /home/vscode 2>/dev/null;
  ls -ld /home/vscode/.gitconfig 2>/dev/null || echo "(no .gitconfig yet — created by mise install or git config)";
  stat -c "%U %G %n" /home/vscode/.zshrc
'
```

Expected: `/home/vscode/.zshrc` is owned by `vscode vscode`. If `.gitconfig` exists it should also be `vscode vscode`. If you see `root root` on either, the gosu wrapping is broken — re-check Step 2.

- [ ] **Step 5: Verify mise still installs tools for projects**

In a project that has a `mise.toml` (e.g. `/workspace/examples/...` if present, or any project with `mise.toml` you have handy), run `dev` from that directory and confirm `mise install` runs without warnings and the listed tools are usable.

If no example project is available, this step can be confirmed by observing the existing baked-in tools still work:
```bash
cd /workspace && ./dev -- bash -c 'eza --version && rg --version | head -1'
```
Expected: both report a version.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile entrypoint.sh
git -c commit.gpgsign=false commit -m "run entrypoint as root, drop privileges via gosu

Removes the trailing USER vscode in the Dockerfile so entrypoint.sh
runs as root, and rewrites entrypoint.sh to perform user-context
startup (zshrc sync, mise install, git config) under gosu vscode
and to exec gosu vscode for the final command. Required by the
firewall hook in the next commit, which needs root for iptables."
```

---

## Task 4: Wire firewall-init into the entrypoint and grant NET_ADMIN

Calls `firewall-init.sh` from `entrypoint.sh` (gated on `DEVCONTAINER_MAINTENANCE`), exports proxy env vars, and adds `--cap-add=NET_ADMIN` to every `dev` invocation. After this task, the firewall is ON for normal `dev` runs. Sudo is still available to vscode (removed in Task 5), so the agent could in principle disable iptables — that lockdown comes next.

**Files:**
- Modify: `entrypoint.sh`
- Modify: `dev`

- [ ] **Step 1: Add firewall hook to entrypoint.sh**

In `/workspace/entrypoint.sh`, insert this block at the top, immediately after `set -u`:

```bash
# --- Firewall (skipped in maintenance mode) ---
if [ -z "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    if ! /usr/local/sbin/firewall-init.sh; then
        echo "FATAL: firewall-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    # Export for the rest of this entrypoint (so gosu-launched mise install
    # uses the proxy) and persist for interactive shells via /etc/profile.d.
    export HTTPS_PROXY=http://127.0.0.1:8888
    export HTTP_PROXY=http://127.0.0.1:8888
    export NO_PROXY=localhost,127.0.0.1
    cat > /etc/profile.d/proxy.sh <<'EOF'
export HTTPS_PROXY=http://127.0.0.1:8888
export HTTP_PROXY=http://127.0.0.1:8888
export NO_PROXY=localhost,127.0.0.1
EOF
    chmod 644 /etc/profile.d/proxy.sh
fi
```

The full file should now look like:

```bash
#!/bin/bash
set -u

# --- Firewall (skipped in maintenance mode) ---
if [ -z "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    if ! /usr/local/sbin/firewall-init.sh; then
        echo "FATAL: firewall-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    export HTTPS_PROXY=http://127.0.0.1:8888
    export HTTP_PROXY=http://127.0.0.1:8888
    export NO_PROXY=localhost,127.0.0.1
    cat > /etc/profile.d/proxy.sh <<'EOF'
export HTTPS_PROXY=http://127.0.0.1:8888
export HTTP_PROXY=http://127.0.0.1:8888
export NO_PROXY=localhost,127.0.0.1
EOF
    chmod 644 /etc/profile.d/proxy.sh
fi

# entrypoint.sh runs as root. Run user-context startup tasks as vscode.
gosu vscode bash <<'INNER'
set -u
if [[ -f /home/vscode/.zshrc ]] && ! grep -q 'mise activate zsh' /home/vscode/.zshrc; then
    # shellcheck disable=SC2016
    echo 'eval "$(mise activate zsh)"' >> /home/vscode/.zshrc
fi
if [[ -f /workspace/mise.toml ]] || [[ -f /workspace/.mise.toml ]]; then
    if ! mise install; then
        echo "WARNING: mise install failed, but continuing with container startup" >&2
    fi
fi
git config --global --add safe.directory /workspace
INNER

exec gosu vscode "$@"
```

- [ ] **Step 2: Add --cap-add=NET_ADMIN to the dev script**

In `/workspace/dev`, find the section that builds `DOCKER_CMD`:

```bash
# Build docker run command
DOCKER_CMD=(docker run -it --rm --name "$CONTAINER_NAME")

# Volume mounts
DOCKER_CMD+=(-v "$(pwd):/workspace")
```

Insert a `--cap-add` line right after the volume mounts setup begins, so the array becomes:

```bash
# Build docker run command
DOCKER_CMD=(docker run -it --rm --name "$CONTAINER_NAME")

# Capability needed by entrypoint to configure iptables (used in normal mode;
# harmless when unused in maintenance mode).
DOCKER_CMD+=(--cap-add=NET_ADMIN)

# Volume mounts
DOCKER_CMD+=(-v "$(pwd):/workspace")
```

- [ ] **Step 3: Rebuild and verify the firewall is active**

The container reuse logic in `dev` will attach to the running `dev-workspace` from earlier tasks if it's still up. Stop it first:

```bash
docker rm -f dev-workspace 2>/dev/null || true
cd /workspace && ./dev --build -- bash -c '
  echo "--- env ---";
  env | grep -i proxy;
  echo "--- iptables OUTPUT ---";
  sudo iptables -S OUTPUT;
  echo "--- proxy reachable ---";
  curl -fsS -o /dev/null -w "proxy returned HTTP %{http_code}\n" http://127.0.0.1:8888 || true;
  echo "--- allowed host via proxy ---";
  curl -fsS https://api.github.com/zen && echo;
  echo "--- blocked host via proxy ---";
  curl -sS -o /dev/null -w "blocked host returned HTTP %{http_code}\n" https://example.com || true;
  echo "--- raw socket bypass ---";
  timeout 5 curl -sS --noproxy "*" -o /dev/null -w "raw socket got HTTP %{http_code}\n" https://api.github.com || echo "raw socket blocked (expected)";
'
```

Expected:
- `HTTPS_PROXY=http://127.0.0.1:8888` etc. shown in env.
- `iptables -S OUTPUT` shows `-P OUTPUT DROP` and the ACCEPT rules from `firewall-init.sh`.
- proxy returns HTTP 400 (tinyproxy responds 400 to a bare GET; that's fine — it means it's listening).
- `api.github.com/zen` prints a quote.
- `example.com` returns HTTP 403 (tinyproxy "Filter rejected").
- raw socket attempt times out / errors → "raw socket blocked (expected)".

- [ ] **Step 4: Verify failure mode — corrupt allowlist refuses to start**

Temporarily break the allowlist to confirm fail-closed behavior:

```bash
docker rm -f dev-workspace 2>/dev/null || true
docker run --rm --cap-add=NET_ADMIN \
    -v /tmp/empty:/workspace \
    -v /dev/null:/etc/devcontainer/allowlist.base:ro \
    generic-devcontainer true 2>&1 | head -20
```

Expected: output contains `firewall-init: refusing to start with an empty filter` and `FATAL: firewall-init.sh failed; refusing to start container`. Container exits non-zero.

- [ ] **Step 5: Commit**

```bash
git add entrypoint.sh dev
git -c commit.gpgsign=false commit -m "wire firewall-init into entrypoint, grant NET_ADMIN

Calls firewall-init.sh at container start (skipped if
DEVCONTAINER_MAINTENANCE is set), exports proxy env vars for the
session, and adds --cap-add=NET_ADMIN to every dev invocation.
Firewall is now active for normal dev runs."
```

---

## Task 5: Remove vscode's passwordless sudo

Strips the sudoers fragment that the base image ships, so `vscode` has no path to root in normal mode. After this task, an agent inside the container cannot use `sudo iptables -F` to escape the firewall — that's the actual security boundary. Maintenance mode (Task 6) re-grants sudo dynamically.

**Files:**
- Modify: `Dockerfile`

- [ ] **Step 1: Inspect the base image to confirm where vscode's sudo comes from**

Run:
```bash
cd /workspace && ./dev -- bash -c '
  ls -l /etc/sudoers.d/ &&
  echo "---" &&
  for f in /etc/sudoers.d/*; do
    echo "--- $f ---";
    cat "$f" 2>/dev/null;
  done
'
```

Expected: a fragment exists (typically `/etc/sudoers.d/vscode`) with a line like `vscode ALL=(root) NOPASSWD:ALL`. Note any other files that grant vscode sudo so they can also be removed.

- [ ] **Step 2: Remove the sudoers fragment in the Dockerfile**

In `/workspace/Dockerfile`, immediately after the `RUN apt-get update && apt-get install ...` block from Task 1 (so it runs as root before the rest of the image is built), insert:

```dockerfile
# Strip vscode's passwordless sudo. vscode is the agent-facing user; if it
# can sudo, it can flush iptables and defeat the firewall. Maintenance mode
# re-creates a sudoers fragment at container runtime.
RUN rm -f /etc/sudoers.d/vscode /etc/sudoers.d/nopasswd && \
    if grep -rEl '^[[:space:]]*vscode[[:space:]]' /etc/sudoers.d/ 2>/dev/null; then \
        grep -rEl '^[[:space:]]*vscode[[:space:]]' /etc/sudoers.d/ | xargs -r rm -f; \
    fi
```

- [ ] **Step 3: Rebuild and verify sudo is gone**

```bash
docker rm -f dev-workspace 2>/dev/null || true
cd /workspace && ./dev --build -- bash -c '
  set +e;
  sudo -n true 2>&1; echo "sudo -n true exit=$?";
  sudo -n iptables -F 2>&1; echo "sudo -n iptables -F exit=$?";
  set -e;
  curl -fsS https://api.github.com/zen && echo
'
```

Expected:
- `sudo -n true` prints something like `sudo: a password is required` or `sudo: user vscode is not in the sudoers file`, and exits non-zero.
- `sudo -n iptables -F` likewise fails.
- `api.github.com/zen` still works (firewall is up; agent just cannot turn it off).

- [ ] **Step 4: Confirm iptables rules are intact after the sudo attempt**

Inside the same container or a fresh `./dev`:

```bash
cd /workspace && ./dev -- bash -c '
  curl -fsS https://api.github.com/zen >/dev/null && echo "allowed host: ok";
  curl -sS -o /dev/null -w "blocked host: %{http_code}\n" https://example.com;
'
```

Expected: `allowed host: ok` and `blocked host: 403`. The firewall is still in force.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile
git -c commit.gpgsign=false commit -m "remove vscode's passwordless sudo in normal mode

The base image grants vscode passwordless sudo via /etc/sudoers.d/.
For an agent-facing sandbox, that's an escape hatch out of the
firewall; remove it. Maintenance mode (next commit) re-grants sudo
at container startup when explicitly requested."
```

---

## Task 6: Add `--maintenance` mode to dev and entrypoint

Adds the `--maintenance` flag to `dev`. In maintenance mode, the container name is suffixed with `-maint`, the firewall init is skipped (already handled in Task 4 via `DEVCONTAINER_MAINTENANCE`), and a sudoers fragment is written at startup so the user can install system packages and debug. A conflict guard refuses to start either mode while the other mode's container is running on the same workspace.

**Files:**
- Modify: `dev`
- Modify: `entrypoint.sh`

- [ ] **Step 1: Extend dev with the `--maintenance` flag**

In `/workspace/dev`, find the flag declarations near the top:

```bash
# Flags
DRY_RUN=false
FORCE_BUILD=false
NO_PORTS=false
EXTRA_PORTS=()
CMD_ARGS=()
```

Replace with:

```bash
# Flags
DRY_RUN=false
FORCE_BUILD=false
NO_PORTS=false
MAINTENANCE=false
EXTRA_PORTS=()
CMD_ARGS=()
```

Find the `usage()` heredoc and add the new flag's help text. Replace the existing `usage()` with:

```bash
usage() {
  cat <<EOF
Usage: dev [OPTIONS] [-- COMMAND...]
       dev install

Run or attach to the generic devcontainer.

OPTIONS:
  --help          Show this help message
  --dry-run       Print docker command without executing
  --build         Force rebuild the image
  --port PORT     Add additional port forwarding (repeatable)
  --no-ports      Skip default port forwarding
  --maintenance   Start with firewall disabled and sudo enabled.
                  Container name is suffixed with -maint to avoid
                  clashing with the normal container.
  --              Pass remaining arguments as command to container

COMMANDS:
  install         Symlink this script into a writable directory on PATH

EXAMPLES:
  dev                           # Start or attach to container with default shell
  dev --build                   # Rebuild image and start container
  dev --dry-run                 # Show docker command without running
  dev --port 9000 --port 9001   # Add custom port forwarding
  dev --maintenance             # Start in maintenance mode (no firewall, sudo enabled)
  dev -- npm run dev            # Run custom command in container
  dev install                   # Install 'dev' onto your PATH

EOF
}
```

In the flag-parsing while loop, add a case for `--maintenance`. Find:

```bash
    --no-ports)
      NO_PORTS=true
      shift
      ;;
```

Insert immediately after it:

```bash
    --maintenance)
      MAINTENANCE=true
      shift
      ;;
```

- [ ] **Step 2: Replace the CONTAINER_NAME line with mode-aware naming and conflict guard**

Find this line near the top of `/workspace/dev`:

```bash
# Container name based on current directory
CONTAINER_NAME="dev-$(basename "$(pwd)")"
```

The conflict guard needs `MAINTENANCE` to already be parsed, so move the naming logic to AFTER the argument-parsing while loop. Delete the original `CONTAINER_NAME=...` line, and add this block immediately after the `while [[ $# -gt 0 ]]; do ... done` loop and before the `# Build image if needed` block:

```bash
# Container naming: normal mode uses dev-<dir>, maintenance uses dev-<dir>-maint.
# Refuse to start one mode while the other is already running for the same
# workspace — both would share /workspace and produce surprising state.
WORKSPACE_BASENAME="$(basename "$(pwd)")"
NORMAL_NAME="dev-${WORKSPACE_BASENAME}"
MAINT_NAME="dev-${WORKSPACE_BASENAME}-maint"

if [[ "$MAINTENANCE" == true ]]; then
  if docker ps -q -f name="^${NORMAL_NAME}$" | grep -q .; then
    echo "Error: normal container ${NORMAL_NAME} is running for this workspace." >&2
    echo "       Stop it first:  docker stop ${NORMAL_NAME}" >&2
    exit 1
  fi
  CONTAINER_NAME="$MAINT_NAME"
else
  if docker ps -q -f name="^${MAINT_NAME}$" | grep -q .; then
    echo "Error: maintenance container ${MAINT_NAME} is running for this workspace." >&2
    echo "       Stop it first:  docker stop ${MAINT_NAME}" >&2
    exit 1
  fi
  CONTAINER_NAME="$NORMAL_NAME"
fi
```

(The original `IMAGE_NAME="generic-devcontainer"` declaration stays where it is — only `CONTAINER_NAME` moves.)

- [ ] **Step 3: Pass DEVCONTAINER_MAINTENANCE through to the container**

In `/workspace/dev`, find the env passthrough section:

```bash
# Forward GITHUB_TOKEN if set
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  DOCKER_CMD+=(-e GITHUB_TOKEN)
fi
```

Insert after it:

```bash
# Maintenance mode: tell entrypoint.sh to skip firewall init and grant sudo.
if [[ "$MAINTENANCE" == true ]]; then
  DOCKER_CMD+=(-e DEVCONTAINER_MAINTENANCE=1)
fi
```

- [ ] **Step 4: Add maintenance-mode handling to entrypoint.sh**

In `/workspace/entrypoint.sh`, after the firewall hook (the `if [ -z "${DEVCONTAINER_MAINTENANCE:-}" ]; then ... fi` block from Task 4) and before the `gosu vscode bash <<'INNER'` block, insert:

```bash
# --- Maintenance mode: re-grant sudo for vscode and warn loudly ---
if [ -n "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    cat > /etc/sudoers.d/vscode-maint <<'EOF'
vscode ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 /etc/sudoers.d/vscode-maint
    cat > /etc/profile.d/zz-maint-banner.sh <<'EOF'
echo
echo "=========================================================="
echo "  MAINTENANCE MODE - firewall disabled, sudo enabled."
echo "  Do not run untrusted code in this container."
echo "=========================================================="
echo
EOF
    chmod 644 /etc/profile.d/zz-maint-banner.sh
fi
```

The full `entrypoint.sh` should now read:

```bash
#!/bin/bash
set -u

# --- Firewall (skipped in maintenance mode) ---
if [ -z "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    if ! /usr/local/sbin/firewall-init.sh; then
        echo "FATAL: firewall-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    export HTTPS_PROXY=http://127.0.0.1:8888
    export HTTP_PROXY=http://127.0.0.1:8888
    export NO_PROXY=localhost,127.0.0.1
    cat > /etc/profile.d/proxy.sh <<'EOF'
export HTTPS_PROXY=http://127.0.0.1:8888
export HTTP_PROXY=http://127.0.0.1:8888
export NO_PROXY=localhost,127.0.0.1
EOF
    chmod 644 /etc/profile.d/proxy.sh
fi

# --- Maintenance mode: re-grant sudo for vscode and warn loudly ---
if [ -n "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    cat > /etc/sudoers.d/vscode-maint <<'EOF'
vscode ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 /etc/sudoers.d/vscode-maint
    cat > /etc/profile.d/zz-maint-banner.sh <<'EOF'
echo
echo "=========================================================="
echo "  MAINTENANCE MODE - firewall disabled, sudo enabled."
echo "  Do not run untrusted code in this container."
echo "=========================================================="
echo
EOF
    chmod 644 /etc/profile.d/zz-maint-banner.sh
fi

# Run user-context startup tasks as vscode.
gosu vscode bash <<'INNER'
set -u
if [[ -f /home/vscode/.zshrc ]] && ! grep -q 'mise activate zsh' /home/vscode/.zshrc; then
    # shellcheck disable=SC2016
    echo 'eval "$(mise activate zsh)"' >> /home/vscode/.zshrc
fi
if [[ -f /workspace/mise.toml ]] || [[ -f /workspace/.mise.toml ]]; then
    if ! mise install; then
        echo "WARNING: mise install failed, but continuing with container startup" >&2
    fi
fi
git config --global --add safe.directory /workspace
INNER

exec gosu vscode "$@"
```

- [ ] **Step 5: Verify normal mode still locked down**

```bash
docker rm -f dev-workspace dev-workspace-maint 2>/dev/null || true
cd /workspace && ./dev --build -- bash -c '
  sudo -n true 2>&1 | head -1;
  curl -fsS https://api.github.com/zen >/dev/null && echo "allowed host: ok";
  curl -sS -o /dev/null -w "blocked host: %{http_code}\n" https://example.com;
'
```

Expected: sudo fails ("not in sudoers" / "password required"), allowed host ok, blocked host 403.

- [ ] **Step 6: Verify maintenance mode flips both knobs**

```bash
docker rm -f dev-workspace dev-workspace-maint 2>/dev/null || true
cd /workspace && ./dev --maintenance -- bash -c '
  sudo -n whoami;
  iptables -S OUTPUT 2>&1 | head -3;
  curl -fsS https://example.com -o /dev/null -w "example.com: %{http_code}\n";
  env | grep -i proxy || echo "no proxy env (expected in maintenance mode)";
'
```

Expected:
- `sudo -n whoami` prints `root`.
- `iptables -S OUTPUT` shows the default `-P OUTPUT ACCEPT` (firewall not applied).
- `example.com: 200` (or 30x — point is, not 403; nothing is filtering).
- proxy env vars absent.
- The maintenance-mode banner is printed when starting an interactive shell (`./dev --maintenance` without `--`).

- [ ] **Step 7: Verify the conflict guard**

```bash
# Start a normal container in the background.
docker rm -f dev-workspace dev-workspace-maint 2>/dev/null || true
cd /workspace && ./dev -- sleep 60 &
BG_PID=$!
sleep 3

# Try to start maintenance mode → should refuse.
./dev --maintenance -- true
echo "maintenance attempt exit: $?"

# Clean up.
docker stop dev-workspace 2>/dev/null
wait $BG_PID 2>/dev/null || true
```

Expected: maintenance attempt exits non-zero with the "normal container ... is running" error message. Reverse direction: start `--maintenance` first and confirm a normal `dev` invocation refuses to start.

- [ ] **Step 8: Commit**

```bash
git add dev entrypoint.sh
git -c commit.gpgsign=false commit -m "add --maintenance mode

dev --maintenance starts the container with the firewall disabled
and sudo enabled. The container is named dev-<dir>-maint to avoid
clashing with the normal container; a conflict guard refuses to
start either mode while the other's container is running for the
same workspace. The entrypoint writes a transient sudoers fragment
and a banner when DEVCONTAINER_MAINTENANCE is set."
```

---

## Task 7: Add the verify-firewall.sh helper

Packages the verification checklist from the spec as a runnable script. Useful for future regression checks and as documentation of expected behavior.

**Files:**
- Create: `scripts/verify-firewall.sh`

- [ ] **Step 1: Create the script**

Create `/workspace/scripts/verify-firewall.sh` (mode 755) with this content:

```bash
#!/bin/bash
# scripts/verify-firewall.sh
#
# Run inside the dev container to probe firewall posture.
# In normal mode: all 7 checks should pass.
# In maintenance mode: checks 1, 3, 4, 6, 7 are skipped; 2 and 5 should pass.
set -u

PASS=0; FAIL=0; SKIP=0
maint=${DEVCONTAINER_MAINTENANCE:-}

run_check() {
    local name="$1"; shift
    local skip_in_maint="${SKIP_IN_MAINT:-0}"
    if [ -n "$maint" ] && [ "$skip_in_maint" = "1" ]; then
        printf '  SKIP   %s (maintenance mode)\n' "$name"
        SKIP=$((SKIP+1)); return
    fi
    if "$@" >/dev/null 2>&1; then
        printf '  PASS   %s\n' "$name"
        PASS=$((PASS+1))
    else
        printf '  FAIL   %s\n' "$name"
        FAIL=$((FAIL+1))
    fi
}

# Helpers for the checks.
proxy_listening() {
    curl -s -o /dev/null -m 3 http://127.0.0.1:8888
}
allowed_host() {
    curl -fsS -o /dev/null -m 5 https://api.github.com/zen
}
blocked_host_returns_403() {
    local code
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://example.com 2>/dev/null || echo 000)
    [ "$code" = "403" ]
}
raw_socket_blocked() {
    ! curl -fsS -o /dev/null -m 5 --noproxy '*' https://api.github.com 2>/dev/null
}
dns_works() {
    getent hosts example.com
}
sudo_blocked() {
    ! sudo -n true 2>/dev/null
}
iptables_flush_blocked() {
    ! sudo -n iptables -F 2>/dev/null
}

echo "Firewall verification"
if [ -n "$maint" ]; then
    echo "  mode: MAINTENANCE"
else
    echo "  mode: NORMAL"
fi
echo

SKIP_IN_MAINT=1 run_check "1. proxy reachable on 127.0.0.1:8888" proxy_listening
                run_check "2. allowed host reachable"            allowed_host
SKIP_IN_MAINT=1 run_check "3. blocked host returns 403"          blocked_host_returns_403
SKIP_IN_MAINT=1 run_check "4. raw socket bypass blocked"         raw_socket_blocked
                run_check "5. DNS works"                         dns_works
SKIP_IN_MAINT=1 run_check "6. sudo blocked"                      sudo_blocked
SKIP_IN_MAINT=1 run_check "7. iptables flush blocked"            iptables_flush_blocked

echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /workspace/scripts/verify-firewall.sh
```

- [ ] **Step 3: Run in normal mode**

```bash
docker rm -f dev-workspace dev-workspace-maint 2>/dev/null || true
cd /workspace && ./dev -- /workspace/scripts/verify-firewall.sh
```

Expected output:

```
Firewall verification
  mode: NORMAL

  PASS   1. proxy reachable on 127.0.0.1:8888
  PASS   2. allowed host reachable
  PASS   3. blocked host returns 403
  PASS   4. raw socket bypass blocked
  PASS   5. DNS works
  PASS   6. sudo blocked
  PASS   7. iptables flush blocked

Results: 7 passed, 0 failed, 0 skipped
```

Exit code 0.

- [ ] **Step 4: Run in maintenance mode**

```bash
docker rm -f dev-workspace dev-workspace-maint 2>/dev/null || true
cd /workspace && ./dev --maintenance -- /workspace/scripts/verify-firewall.sh
```

Expected output:

```
Firewall verification
  mode: MAINTENANCE

  SKIP   1. proxy reachable on 127.0.0.1:8888 (maintenance mode)
  PASS   2. allowed host reachable
  SKIP   3. blocked host returns 403 (maintenance mode)
  SKIP   4. raw socket bypass blocked (maintenance mode)
  PASS   5. DNS works
  SKIP   6. sudo blocked (maintenance mode)
  SKIP   7. iptables flush blocked (maintenance mode)

Results: 2 passed, 0 failed, 5 skipped
```

Exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-firewall.sh
git -c commit.gpgsign=false commit -m "add scripts/verify-firewall.sh helper

Probes firewall posture from inside the container and reports
pass/fail. Skips firewall-specific checks in maintenance mode."
```

---

## Task 8: Document the firewall in README.md

Adds a section to the README describing the firewall, the allowlist files, and the maintenance flag. Without docs, project users won't know they can override the allowlist or how to reach the maintenance escape hatch.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README to find the right insertion point**

Run: `cat /workspace/README.md`

Identify the section that describes "Build and Run" or similar. The new "Firewall" section should land after build/run usage and before any deeper architecture/design notes.

- [ ] **Step 2: Add a Firewall section**

Append (or insert at the appropriate spot — judgement call based on README structure) the following section to `/workspace/README.md`:

```markdown
## Firewall

The container restricts outbound traffic to a curated allowlist of domains.
This is intended for running AI agents in a sandbox: an agent running as
`vscode` cannot exfiltrate workspace contents to arbitrary hosts.

### How it works

- `tinyproxy` runs inside the container and filters HTTPS by hostname (CONNECT).
- `iptables` defaults `OUTPUT` to DROP and only allows DNS + the `proxy` user
  reaching :80/:443. An agent process bypassing the proxy via raw sockets
  cannot match the owner rule and is dropped at the kernel.
- `vscode` has no sudo in normal mode. There is no path to disable iptables
  from inside the container.
- HTTP(S) clients in the container honour `HTTPS_PROXY` / `HTTP_PROXY` env
  vars, which are exported by the entrypoint to point at `127.0.0.1:8888`.

### Allowlists

Two layers, merged at container startup:

- **Base list** (`allowlist.base` in this repo) is baked into the image at
  `/etc/devcontainer/allowlist.base`. It includes Anthropic, GitHub, common
  package registries, mise, and OS package mirrors. Edit this file and
  rebuild the image to change the base list.
- **Project list** (`.devcontainer-allowlist` at the workspace root) is
  optional. Read at every container start; concatenated with the base list
  and deduplicated. No image rebuild needed — restart the container to pick
  up changes.

Format: one entry per line, `#` comments. A bare hostname (`github.com`)
matches that name exactly. A `*.` prefix (`*.github.com`) matches any
subdomain. List both if you need both.

### Maintenance mode

```bash
dev --maintenance
```

Starts the container with the firewall disabled and sudo enabled. Use this
for installing system packages, debugging the firewall, or fetching tools
from non-allowlisted hosts. The maintenance container has a different name
(`dev-<dir>-maint`), and the normal container is refused while it runs (and
vice versa) — they would both have `/workspace` mounted and produce
surprising state.

### Verifying the firewall

A helper script probes posture:

```bash
dev -- /workspace/scripts/verify-firewall.sh
```

In normal mode all 7 checks pass; in maintenance mode 5 are skipped.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git -c commit.gpgsign=false commit -m "document firewall and maintenance mode in README

Adds a Firewall section covering the threat model, allowlist files,
maintenance flag, and the verification helper."
```

---

## Self-review

Spec coverage:
- Architecture / iptables + tinyproxy + owner-match: Tasks 2, 4 ✓
- Base + project allowlist: Tasks 1 (base), 2 (merge logic), 4 (per-project file read at startup) ✓
- Bootstrap sequence (root then drop, gosu): Task 3 ✓
- Firewall hook in entrypoint, fail-closed: Task 4 ✓
- vscode sudo removed: Task 5 ✓
- `--maintenance` mode (env var, sudoers fragment, banner, container name suffix, conflict guard, NET_ADMIN): Task 6 (+ NET_ADMIN added in Task 4) ✓
- verify-firewall.sh: Task 7 ✓
- README updates: Task 8 ✓
- HTTPS-only model (no SSH/22): enforced by iptables rules in firewall-init.sh ✓
- DNS allowed freely (Q4 option A): iptables allows port 53 to anywhere ✓

Type/name consistency:
- `DEVCONTAINER_MAINTENANCE` env var used identically in `dev`, `entrypoint.sh`, and `verify-firewall.sh`.
- Container names: `dev-<dir>` and `dev-<dir>-maint` consistent across `dev` script and README.
- Path constants (`/etc/devcontainer/allowlist.base`, `/etc/tinyproxy/filter`, `/usr/local/sbin/firewall-init.sh`) consistent across spec, plan, and inlined code.

No unresolved placeholders or "TODO" markers in the plan. Each step has executable commands or full file contents.
