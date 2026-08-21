#!/bin/bash
# scripts/test/scenarios/40-uid-gid-default-build.sh
# platform: linux
# privilege: user
#
# `dev exec --build` builds the image for the uid/gid dev resolved for this
# host, stamps them onto the labels and onto the in-container vscode user, and
# is idempotent afterwards.
#
# Those ids are NOT always the invoking user's. Under rootless podman 4.3+ dev
# keeps vscode at 1000 and maps the host user onto it with keep-id:uid=, because
# a host uid outside the user's /etc/subuid grant cannot be baked at all
# (lib/dev/ids.sh). This scenario used to assert the labels equalled `id -u`,
# which held only on a host whose uid happened to BE 1000 — green on a dev
# laptop, red on CI, whose runner is uid 1001. The labels are now checked
# against expected_image_ids (lib/runtime.sh, read from lib/dev/ids.sh itself),
# and the property that actually matters is asserted directly below: whatever
# the numbers are, a file the container writes into /workspace must come out
# owned by the invoking user on the host.
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
read -r EXP_UID EXP_GID _ <<< "$(expected_image_ids)"
if [ -z "$EXP_UID" ] || [ -z "$EXP_GID" ]; then
    log_fail "expected_image_ids returned nothing; cannot tell what the image should be built for"
    exit 1
fi

PROBE=".uid-gid-probe-$$"
# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() {
    rm -f "$PROBE"
}
# Re-trap now that there is something extra to clean up; restore_host was
# already armed above so nothing is unguarded in between.
trap 'cleanup_extra; restore_host' EXIT

# Wipe image + volumes so we exercise the cold-start build path. This
# scenario exercises the DEFAULT (no DEV_SHARED_HOME) code path, so the home
# volume dev actually creates is the per-workspace devcontainer-home-<dir>,
# not the legacy shared devcontainer-home.
"$RUNTIME" rm -f "dev-${WS}" >/dev/null 2>&1
"$RUNTIME" rmi -f generic-devcontainer >/dev/null 2>&1
"$RUNTIME" volume rm devcontainer-mise "devcontainer-home-${WS}" >/dev/null 2>&1

if ! ./dev exec --build -- true >/dev/null 2>&1; then
    log_fail "dev exec --build failed"
    exit 1
fi

img_uid=$("$RUNTIME" image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
img_gid=$("$RUNTIME" image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.gid" }}' 2>/dev/null)
if [ "$img_uid" != "$EXP_UID" ] || [ "$img_gid" != "$EXP_GID" ]; then
    log_fail "labels are ${img_uid}:${img_gid}, want ${EXP_UID}:${EXP_GID}"
    exit 1
fi

# Startup diagnostics go to stderr (kept off the payload stdout), but pluck
# out just the numeric `id` line anyway so this stays robust regardless.
in_uid=$(./dev exec -- id -u vscode 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)
in_gid=$(./dev exec -- id -g vscode 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)
if [ "$in_uid" != "$EXP_UID" ] || [ "$in_gid" != "$EXP_GID" ]; then
    log_fail "in-container vscode is ${in_uid}:${in_gid}, want ${EXP_UID}:${EXP_GID}"
    exit 1
fi

# The invariant the whole uid/gid dance exists for, and the one assertion here
# that is independent of which mapping strategy dev picked: a file the container
# creates in the bind-mounted workspace is owned by the invoking user on the
# host. If this fails, the project directory is effectively read-only to the
# agent (or root-owned droppings appear in it) no matter what the labels say.
rm -f "$PROBE"
if ! ./dev exec -- sh -c "printf probe > /workspace/$PROBE" >/dev/null 2>&1; then
    log_fail "container could not write into the bind-mounted workspace"
    exit 1
fi
probe_uid=$(stat -c %u "$PROBE" 2>/dev/null)
probe_gid=$(stat -c %g "$PROBE" 2>/dev/null)
if [ "$probe_uid" != "$HOST_UID" ] || [ "$probe_gid" != "$HOST_GID" ]; then
    log_fail "workspace file written in-container is owned by ${probe_uid}:${probe_gid} on the host, want ${HOST_UID}:${HOST_GID}"
    exit 1
fi
rm -f "$PROBE"

# Idempotency: a second invocation with matching labels must not
# trigger a rebuild prompt. (No DEV_ASSUME_YES, no closed stdin —
# if a prompt fired, the closed-stdin probe would error out.)
if ! ./dev exec -- true </dev/null >/dev/null 2>&1; then
    log_fail "second dev invocation with matching labels failed"
    exit 1
fi

log_pass "dev exec --build stamps the resolved UID/GID, keeps /workspace host-owned, and is idempotent"
exit 0
