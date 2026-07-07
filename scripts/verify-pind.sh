#!/bin/bash
# scripts/verify-pind.sh
#
# Heavier --pind checks. Run from inside the dev container in --pind mode.
# Each check echoes PASS/FAIL on a single line and exits the script
# non-zero if any check fails.
#
# Unlike verify-dind.sh, there is no real `docker` CLI in the pind image —
# only rootless podman plus the podman-docker shim (/usr/bin/docker) and a
# docker-compose symlink to the compose CLI plugin. Probes that would
# normally use `docker -H "$DOCKER_HOST" ...` instead talk to the Docker-API
# compat socket directly via curl, since that's the actual interface
# testcontainers / docker-compose rely on.
#
# Designed to be invoked by host-side scenario scripts via:
#     ./dev --pind -- /workspace/scripts/verify-pind.sh
set -u

PASS=0; FAIL=0
fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }

if [ -z "${DEVCONTAINER_PIND:-}" ]; then
    echo "verify-pind.sh: DEVCONTAINER_PIND not set; this script is meant for --pind containers" >&2
    exit 2
fi

# P1: podman pull + run through the proxy allowlist.
echo "P1. podman run alpine (proxy egress works)..."
if podman run --rm alpine:3.20 true; then
    pass "P1 podman run alpine"
else
    fail "P1 podman run alpine"
fi

# P2: Docker-API compat socket reachable — this is the actual interface
# testcontainers / docker-compose speak. There is no real `docker` CLI, so
# hit the unix socket directly with curl rather than `docker -H`.
echo "P2. compat socket reachable via curl..."
sock="${DOCKER_HOST#unix://}"
if [ -z "${sock}" ] || [ "${sock}" = "${DOCKER_HOST:-}" ]; then
    sock="/home/vscode/.pind-run/podman.sock"
fi
if [ -S "$sock" ] && ver_out=$(curl -s --unix-socket "$sock" http://d/version 2>&1) \
        && echo "$ver_out" | grep -q '"ApiVersion"'; then
    pass "P2 compat socket ($sock) reachable"
else
    fail "P2 compat socket ($sock) not reachable"
    echo "$ver_out" >&2
fi

# P3: docker shim resolves and reports podman as the engine.
echo "P3. docker shim (podman-docker)..."
if docker_out=$(docker version 2>&1) && echo "$docker_out" | grep -qi podman; then
    pass "P3 docker shim reports podman"
else
    fail "P3 docker shim"
    echo "$docker_out" >&2
fi

# P4: docker compose / docker-compose resolves via the plugin symlink.
echo "P4. docker compose plugin..."
if docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1; then
    pass "P4 docker compose available"
else
    fail "P4 docker compose available"
fi

# P5: postgres testcontainers-style smoke: start postgres, wait for
# readiness, then remove.
echo "P5. postgres testcontainers-style smoke..."
cid=$(podman run -d -e POSTGRES_PASSWORD=pw docker.io/library/postgres:16-alpine)
ok=0
if [ -n "$cid" ]; then
    for _ in $(seq 1 30); do
        if podman exec "$cid" pg_isready -U postgres >/dev/null 2>&1; then ok=1; break; fi
        sleep 1
    done
    podman rm -f "$cid" >/dev/null 2>&1
fi
if [ "$ok" = 1 ]; then pass "P5 postgres smoke"; else fail "P5 postgres smoke"; fi

# P6: self-build of this repo's Dockerfile base target with podman build.
#
# Two nested-rootless-podman quirks require non-default flags here (neither
# is specific to this repo's Dockerfile; both are inherent to running
# `podman build` unprivileged inside an already-unprivileged --pind
# container):
#
#  1. Proxy: buildah's automatic proxy passthrough (`--http-proxy`, on by
#     default) only copies whatever case of *_PROXY already exists in the
#     invoking shell's environment. pind-init.sh's /etc/profile.d/pind.sh
#     only exports the uppercase HTTP_PROXY/HTTPS_PROXY (for podman's own
#     pulls via Go's net/http, which reads either case for HTTPS_PROXY but
#     deliberately ignores uppercase HTTP_PROXY — the historic "httpoxy"
#     CVE mitigation). apt-get and other non-Go tools inside RUN steps only
#     honour lowercase http_proxy/https_proxy, so pass those explicitly as
#     --build-arg. --network=host is required alongside this: with the
#     default rootless network, RUN steps get their own slirp4netns netns
#     where 127.0.0.1 is not tinyproxy; --network=host shares the pind
#     container's own netns (and its own loopback:8888 tinyproxy) with the
#     build's RUN steps.
#
#  2. UID collision: rootless podman's default user-namespace mapping sends
#     namespace-root (0) to the real invoking UID (vscode, 1000) and
#     namespace 1..65535 to the subuid range. This repo's own Dockerfile
#     (like most devcontainer base images) also uses UID 1000 for its
#     `vscode` user. Pulled-image files literally owned by UID 1000 (raw,
#     from the upstream tar layer) therefore land on namespace-UID 0 inside
#     any nested build/run container — i.e. "USER vscode" (uid 1000 in the
#     built image) doesn't own its own home directory, because 1000 is
#     *also* the real UID doing the rootless mapping. This is a coincidence
#     of the invoking user matching the image's baked-in UID, not a bug in
#     the Dockerfile. Building the self-image with non-1000 USER_UID/GID
#     build-args sidesteps the collision entirely.
echo "P6. podman build of /workspace (base target)..."
if podman build --no-cache --network=host \
        --build-arg http_proxy=http://127.0.0.1:8888 \
        --build-arg https_proxy=http://127.0.0.1:8888 \
        --build-arg USER_UID=1001 --build-arg USER_GID=1001 \
        --target base -t pind-selfbuild /workspace >/dev/null 2>&1; then
    pass "P6 self-build of base target"
else
    fail "P6 self-build of base target"
fi
podman rmi -f pind-selfbuild >/dev/null 2>&1 || true

# Cleanup: drop images pulled/built by the probes above so the persistent
# pind volume doesn't accumulate them across runs. Best-effort (a cleanup
# failure must not fail the probe); done last so an earlier retry within
# this same run still has the image cached. alpine (P1) is intentionally
# left in place since it's small and reused across probes/runs.
podman rmi -f docker.io/library/postgres:16-alpine >/dev/null 2>&1 || true

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
