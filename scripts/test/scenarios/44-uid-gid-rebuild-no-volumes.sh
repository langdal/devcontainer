#!/bin/bash
# scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh
# platform: linux
#
# cleanup_for_rebuild must skip absent volumes silently. Otherwise a
# user who manually wiped their volumes hits a `volume rm: no such
# volume` and fails the rebuild flow.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
remember_container "dev-${WS}"

HOST_UID=$(id -u)

docker rm -f "dev-${WS}" >/dev/null 2>&1
if ! docker buildx build --network=host \
        --build-arg USER_UID=4242 --build-arg USER_GID=4242 \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build mismatched image"
    exit 1
fi

# Make sure the named volumes really do not exist.
docker volume rm devcontainer-mise devcontainer-home >/dev/null 2>&1 || true

if ! DEV_ASSUME_YES=1 ./dev -- true >/dev/null 2>&1; then
    log_fail "dev failed when no volumes existed before rebuild"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "labels not updated after rebuild: $img_uid"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# `dev` re-creates the volumes on container start.
if ! docker volume inspect devcontainer-home >/dev/null 2>&1; then
    log_fail "devcontainer-home was not re-created on container start"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "cleanup_for_rebuild handles absent volumes"
exit 0
