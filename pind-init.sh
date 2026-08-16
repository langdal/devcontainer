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
# `mkdir -p` above created the ~/.local and ~/.local/share parents as root
# (this runs as root). Hand them back to vscode — non-recursively, so the
# nested-engine storage subdir keeps its own ownership — so vscode-owned
# tooling can create siblings there. Without this, `dev agent add opencode`
# (which injects ~/.local/share/opencode into the home volume as vscode)
# fails with "Cannot mkdir: Permission denied" on the root-owned parent.
chown vscode:vscode /home/vscode/.local /home/vscode/.local/share

# 3. storage.conf: rootless overlay via fuse-overlayfs.
cat > "$CFG_DIR/storage.conf" <<EOF
[storage]
driver = "overlay"
runroot = "$RUN_DIR/containers"
graphroot = "$DATA_DIR/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF

# 4. containers.conf: pin slirp4netns via default_rootless_network_cmd (NOT
#    podman 5.x's pasta default, whose host-loopback mapping does not expose
#    10.0.2.2) and, in closed mode only, inject the proxy env into every
#    nested container so `podman build` RUN steps and `podman run` workloads
#    reach tinyproxy. This is the podman analogue of dind's
#    ~/.docker/config.json proxies block. network_cmd_options enables
#    slirp4netns's allow_host_loopback (default false) — without it, nested
#    containers get "Network unreachable" for 10.0.2.2 and have no proxied
#    egress at all. The only loopback service exposed is tinyproxy, which
#    still enforces the allowlist, and direct (non-proxy) egress is still
#    dropped by this container's iptables — same posture as dind.
#    In open mode there is no tinyproxy listening (firewall-init.sh only
#    starts it when closed), so the [containers] env block is proxy-only and
#    is skipped entirely — nested containers get no proxy env and connect
#    directly instead of failing against a dead 10.0.2.2:8888.
cat > "$CFG_DIR/containers.conf" <<EOF
[network]
default_rootless_network_cmd = "slirp4netns"

[engine]
network_cmd_options = ["allow_host_loopback=true"]
EOF
if [ "${DEVCONTAINER_EGRESS:-closed}" = closed ]; then
    cat >> "$CFG_DIR/containers.conf" <<EOF

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
fi
chown -R vscode:vscode "$CFG_DIR"

# 5. Export DOCKER_HOST/XDG_RUNTIME_DIR for interactive (login) shells, and,
#    in closed mode, the engine's own-pull proxy (127.0.0.1, main netns). In
#    open mode there is no tinyproxy listening, so these exports are skipped
#    (a login shell should connect directly, not against a dead proxy).
cat > /etc/profile.d/pind.sh <<EOF
export DOCKER_HOST=unix://${SOCK}
export XDG_RUNTIME_DIR=${RUN_DIR}
EOF
if [ "${DEVCONTAINER_EGRESS:-closed}" = closed ]; then
    cat >> /etc/profile.d/pind.sh <<EOF
export HTTPS_PROXY=http://127.0.0.1:8888
export HTTP_PROXY=http://127.0.0.1:8888
export NO_PROXY=localhost,127.0.0.1
EOF
fi
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
#    HTTPS_PROXY here is for podman's own pulls (main netns => 127.0.0.1) —
#    only meaningful in closed mode; in open mode there is no tinyproxy
#    listening, so leave the service to pull directly.
PIND_PROXY_ENV=()
if [ "${DEVCONTAINER_EGRESS:-closed}" = closed ]; then
    # shellcheck disable=SC2054  # commas are part of the NO_PROXY value, not element separators
    PIND_PROXY_ENV=(
        HTTPS_PROXY=http://127.0.0.1:8888
        HTTP_PROXY=http://127.0.0.1:8888
        NO_PROXY=localhost,127.0.0.1
    )
fi
gosu vscode env \
    XDG_RUNTIME_DIR="$RUN_DIR" \
    HOME=/home/vscode \
    "${PIND_PROXY_ENV[@]}" \
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
