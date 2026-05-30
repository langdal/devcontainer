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

# 1. Allocate subuid/subgid range for vscode. Done at runtime (not in the
#    Dockerfile) because --build-arg USER_UID rewrites the user after the
#    base image is built. The range is conventional and container-local.
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

# RUN_DIR lives under /home/vscode, which is a named volume — so any state
# the previous container left here (PID files, sockets, rootlesskit state
# dir, embedded containerd state) will look "live" to the new dockerd and
# make it refuse to start. The runtime dir is supposed to be ephemeral;
# wipe everything under it on every container boot.
find "$RUN_DIR" -mindepth 1 -delete 2>/dev/null || true

# 4b. Teach the docker *client* to route nested workloads through tinyproxy.
#     The daemon's own HTTPS_PROXY (step 5) only covers image pulls. Build
#     RUN steps and `docker run` containers are started by the CLI, which
#     injects these proxy settings as build-args / container env from
#     ~/.docker/config.json "proxies". Without this, apt/pip/git inside a
#     `docker build` attempt direct connections and the firewall drops them.
#     Merge (not clobber) so any `docker login` creds on the home volume
#     survive. 10.0.2.2:8888 is the slirp gateway -> container loopback ->
#     tinyproxy, reachable from nested containers once NAT is on (step 5).
DOCKER_CFG_DIR=/home/vscode/.docker
DOCKER_CFG="${DOCKER_CFG_DIR}/config.json"
mkdir -p "$DOCKER_CFG_DIR"
[ -s "$DOCKER_CFG" ] || echo '{}' > "$DOCKER_CFG"
tmp_cfg="$(mktemp)"
if jq '.proxies.default = {
        "httpProxy":  "http://10.0.2.2:8888",
        "httpsProxy": "http://10.0.2.2:8888",
        "noProxy":    "localhost,127.0.0.1,::1"
    }' "$DOCKER_CFG" > "$tmp_cfg" 2>/dev/null; then
    cat "$tmp_cfg" > "$DOCKER_CFG"
else
    echo "dind-init: WARNING: could not merge proxy into $DOCKER_CFG (jq failed); nested builds may not reach the network" >&2
fi
rm -f "$tmp_cfg"
chown -R vscode:vscode "$DOCKER_CFG_DIR"

touch "$LOG"
chown vscode:vscode "$LOG"

# 5. Start dockerd-rootless as vscode in the background.
#    (no --iptables=false): rootless dockerd manages iptables inside its own
#                       RootlessKit network namespace, which is wholly
#                       separate from the container's main-ns OUTPUT chain
#                       that firewall-init.sh owns — they cannot conflict.
#                       The NAT/masquerade docker sets up there is what lets
#                       nested containers and `docker build` RUN steps route
#                       out to the proxy at 10.0.2.2; with it disabled they
#                       can reach nothing (only the daemon's own pulls work),
#                       which silently breaks `docker build`. Managing iptables
#                       requires the iptables binary on PATH — it lives in
#                       /usr/sbin, hence /usr/sbin:/sbin below (their absence is
#                       why the daemon previously had to run --iptables=false).
#    DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false: dockerd-rootless
#                       runs in its own slirp4netns, where 127.0.0.1 points
#                       at the rootless ns's loopback, NOT the container's.
#                       tinyproxy lives on the container's loopback. Letting
#                       slirp4netns expose host-loopback makes 10.0.2.2 in
#                       the rootless ns reach the container's 127.0.0.1, so
#                       we set HTTPS_PROXY=http://10.0.2.2:8888 here.
#    HTTPS_PROXY / HTTP_PROXY: registry pulls flow through tinyproxy, which
#                       is the only outbound path for 80/443.
gosu vscode env \
    XDG_RUNTIME_DIR="$RUN_DIR" \
    HOME=/home/vscode \
    DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false \
    HTTPS_PROXY=http://10.0.2.2:8888 \
    HTTP_PROXY=http://10.0.2.2:8888 \
    NO_PROXY=localhost,127.0.0.1 \
    PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    nohup /usr/local/bin/dockerd-rootless.sh \
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
