#!/bin/bash
# scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh
# platform: linux
# privilege: user
#
# cleanup_for_rebuild must skip absent volumes silently. Otherwise a
# user who manually wiped their volumes hits a `volume rm: no such
# volume` and fails the rebuild flow.
#
# The home volume is per-workspace by default (devcontainer-home-<dir>);
# this scenario is about the generic rebuild/re-create behavior, not
# naming, so it opts into DEV_SHARED_HOME=1 to keep exercising the literal
# devcontainer-home volume with the least churn.
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
export DEV_SHARED_HOME=1

"$RUNTIME" rm -f "dev-${WS}" >/dev/null 2>&1
build_image_with_uid_gid 4242 4242 || exit 1

# Make sure the named volumes really do not exist.
"$RUNTIME" volume rm devcontainer-mise devcontainer-home >/dev/null 2>&1 || true

if ! DEV_ASSUME_YES=1 ./dev exec -- true >/dev/null 2>&1; then
    log_fail "dev failed when no volumes existed before rebuild"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "labels not updated after rebuild: $img_uid"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# `dev` re-creates the volumes on container start.
if ! "$RUNTIME" volume inspect devcontainer-home >/dev/null 2>&1; then
    log_fail "devcontainer-home was not re-created on container start"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "cleanup_for_rebuild handles absent volumes"
exit 0
