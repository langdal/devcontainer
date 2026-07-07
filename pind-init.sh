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
