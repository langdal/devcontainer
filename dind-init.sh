#!/bin/bash
# /usr/local/sbin/dind-init.sh
#
# Launch rootless dockerd inside the dev container. Runs as root from
# entrypoint.sh, drops to vscode for the actual dockerd start.
# Fail-closed: any error => non-zero exit; entrypoint aborts the container.
set -euo pipefail

RUN_DIR=/home/vscode/.dind-run
DATA_DIR=/home/vscode/.local/share/docker
SOCK="${RUN_DIR}/docker.sock"
LOG=/var/log/dockerd-rootless.log

# 1. Ensure subuid/subgid range for vscode (no-op when Dockerfile already set it,
#    matters when --build-arg USER_UID rewrote the user post-image-build).
if ! grep -q '^vscode:' /etc/subuid; then
    echo "vscode:100000:65536" >> /etc/subuid
fi
if ! grep -q '^vscode:' /etc/subgid; then
    echo "vscode:100000:65536" >> /etc/subgid
fi

# 2. Ensure the dockerd data dir exists and is owned by vscode.
#    The named volume comes up empty on first mount.
mkdir -p "$DATA_DIR"
chown -R vscode:vscode "$DATA_DIR"

# 3. Export DOCKER_HOST/XDG_RUNTIME_DIR for interactive shells.
cat > /etc/profile.d/dind.sh <<EOF
export DOCKER_HOST=unix://${SOCK}
export XDG_RUNTIME_DIR=${RUN_DIR}
EOF
chmod 644 /etc/profile.d/dind.sh

# 4. Pre-create the run dir owned by vscode (dockerd-rootless will mkdir
#    inside it but we want the parent perms locked down).
mkdir -p "$RUN_DIR"
chown vscode:vscode "$RUN_DIR"
chmod 0700 "$RUN_DIR"

touch "$LOG"
chown vscode:vscode "$LOG"

# 5. Start dockerd-rootless as vscode in the background.
#    --iptables=false: the container's iptables OUTPUT chain is owned by
#                       firewall-init.sh; don't fight it.
#    HTTPS_PROXY / HTTP_PROXY: registry pulls flow through tinyproxy, which
#                       is the only outbound path for 80/443.
gosu vscode env \
    XDG_RUNTIME_DIR="$RUN_DIR" \
    HOME=/home/vscode \
    HTTPS_PROXY=http://127.0.0.1:8888 \
    HTTP_PROXY=http://127.0.0.1:8888 \
    NO_PROXY=localhost,127.0.0.1 \
    PATH=/usr/local/bin:/usr/bin:/bin \
    nohup /usr/local/bin/dockerd-rootless.sh \
        --iptables=false \
        > "$LOG" 2>&1 &

# 6. Wait up to 15s for the socket to appear.
for _ in $(seq 1 30); do
    if [ -S "$SOCK" ]; then
        echo "dind-init: dockerd-rootless socket ready at $SOCK"
        exit 0
    fi
    sleep 0.5
done

echo "FATAL: dockerd-rootless did not produce a socket at $SOCK within 15s" >&2
echo "--- last 50 lines of $LOG ---" >&2
tail -50 "$LOG" >&2 || true
exit 1
