#!/bin/bash
# scripts/test/scenarios/40-uid-gid-default-build.sh
# platform: linux
#
# `dev --build` bakes the invoking user's UID/GID into the image labels
# and into the in-container vscode user.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
remember_container "dev-${WS}"

HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Wipe image + volumes so we exercise the cold-start build path.
docker rm -f "dev-${WS}" >/dev/null 2>&1
docker rmi -f generic-devcontainer >/dev/null 2>&1
docker volume rm devcontainer-mise devcontainer-home >/dev/null 2>&1

if ! ./dev --build -- true >/dev/null 2>&1; then
    log_fail "dev --build failed"
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
img_gid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.gid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ] || [ "$img_gid" != "$HOST_GID" ]; then
    log_fail "labels are ${img_uid}:${img_gid}, want ${HOST_UID}:${HOST_GID}"
    exit 1
fi

# entrypoint.sh prints firewall-init's progress to stdout before exec'ing
# the command; pluck out just the numeric `id` line.
in_uid=$(./dev -- id -u vscode 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)
in_gid=$(./dev -- id -g vscode 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)
if [ "$in_uid" != "$HOST_UID" ] || [ "$in_gid" != "$HOST_GID" ]; then
    log_fail "in-container vscode is ${in_uid}:${in_gid}, want ${HOST_UID}:${HOST_GID}"
    exit 1
fi

# Idempotency: a second invocation with matching labels must not
# trigger a rebuild prompt. (No DEV_ASSUME_YES, no closed stdin —
# if a prompt fired, the closed-stdin probe would error out.)
if ! ./dev -- true </dev/null >/dev/null 2>&1; then
    log_fail "second dev invocation with matching labels failed"
    exit 1
fi

log_pass "dev --build bakes host UID/GID and is idempotent"
exit 0
