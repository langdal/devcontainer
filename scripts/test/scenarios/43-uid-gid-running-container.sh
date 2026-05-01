#!/bin/bash
# scripts/test/scenarios/43-uid-gid-running-container.sh
# platform: linux
#
# A running container backed by a mismatched image must be removed by
# the rebuild path. After DEV_ASSUME_YES=1 ./dev …, the image tag must
# point at a different image ID and the labels must match host.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
CN="dev-${WS}"
remember_container "$CN"

HOST_UID=$(id -u)

docker rm -f "$CN" >/dev/null 2>&1
if ! docker buildx build --network=host \
        --build-arg USER_UID=4242 --build-arg USER_GID=4242 \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build mismatched image"
    exit 1
fi
OLD_IMAGE_ID=$(docker images -q generic-devcontainer)

# Long-running stale container.
docker run -d --rm --name "$CN" generic-devcontainer sleep 3600 >/dev/null

if ! DEV_ASSUME_YES=1 ./dev -- true >/dev/null 2>&1; then
    log_fail "dev failed during rebuild path"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

NEW_IMAGE_ID=$(docker images -q generic-devcontainer)
if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
    log_fail "image was not rebuilt (id unchanged: $OLD_IMAGE_ID)"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "labels still mismatched after rebuild: $img_uid"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Stale container must be gone (it was removed before rebuild).
if docker ps --format '{{.Names}}' | grep -qx "$CN"; then
    log_fail "stale container $CN is still running"
    docker rm -f "$CN" >/dev/null 2>&1
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "rebuild path removes stale container and re-tags image"
exit 0
