#!/bin/bash
# scripts/test/scenarios/46-version-mismatch.sh
# platform: linux
#
# Image's dev.version label differs from the running dev script's
# VERSION. Two paths:
#   1. Non-interactive (closed stdin) — default-no path: dev warns,
#      continues with the existing image, and the label is unchanged.
#   2. DEV_ASSUME_YES=1 — auto-yes the prompt: image is rebuilt and
#      its dev.version label matches the script's $VERSION afterwards.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/runtime.sh
. "$LIB/runtime.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
remember_container "dev-${WS}"

HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Read the version literal the dev script will use.
SCRIPT_VERSION=$(./dev --version | awk '{print $2}')
if [ -z "$SCRIPT_VERSION" ]; then
    log_fail "could not read dev --version"
    exit 1
fi

OLD_VERSION="0.0.0-stale"

docker rm -f "dev-${WS}" >/dev/null 2>&1

# Bake a matching UID/GID image with an intentionally-stale dev.version
# label. UID matches so the UID check passes and the version check is
# what we actually exercise.
if ! docker buildx build --network=host \
        --build-arg "USER_UID=${HOST_UID}" \
        --build-arg "USER_GID=${HOST_GID}" \
        --build-arg "DEV_VERSION=${OLD_VERSION}" \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build image with stale dev.version label"
    exit 1
fi

# --- Path 1: non-interactive default-no ---
# Closed stdin → not a TTY → dev should warn and continue (rc=0).
out=$(./dev -- true </dev/null 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    log_fail "expected dev to continue past version mismatch in non-tty; rc=$rc out: $out"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -q "$OLD_VERSION"; then
    log_fail "expected diagnostic to mention stale version '$OLD_VERSION'; got: $out"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -q "$SCRIPT_VERSION"; then
    log_fail "expected diagnostic to mention current version '$SCRIPT_VERSION'; got: $out"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_version=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.version" }}' 2>/dev/null)
if [ "$img_version" != "$OLD_VERSION" ]; then
    log_fail "image was rebuilt without consent: label=$img_version"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Stop the container started by path 1 so path 2 actually exercises the
# build path, not the attach-to-running-container short-circuit.
docker rm -f "dev-${WS}" >/dev/null 2>&1

# --- Path 2: DEV_ASSUME_YES rebuilds ---
if ! DEV_ASSUME_YES=1 ./dev -- true >/dev/null 2>&1; then
    log_fail "dev failed under DEV_ASSUME_YES with stale version label"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_version=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.version" }}' 2>/dev/null)
if [ "$img_version" != "$SCRIPT_VERSION" ]; then
    log_fail "label not updated after rebuild: got '$img_version', want '$SCRIPT_VERSION'"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "version mismatch: non-tty continues; DEV_ASSUME_YES rebuilds"
exit 0
