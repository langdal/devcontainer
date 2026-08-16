#!/bin/bash
# scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh
# platform: linux
# privilege: user
#
# DEV_ASSUME_YES bypasses the prompt; the script then removes the named
# volumes and rebuilds the image. The marker file we plant in
# devcontainer-home before invocation must be gone afterwards.
#
# The home volume is per-workspace by default (devcontainer-home-<dir>);
# this scenario is about the generic rebuild/wipe behavior, not naming, so
# it opts into DEV_SHARED_HOME=1 to keep exercising the literal
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

# Build mismatched image directly.
"$RUNTIME" rm -f "dev-${WS}" >/dev/null 2>&1
build_image_with_uid_gid 4242 4242 || exit 1

# Plant a marker in devcontainer-home that the rebuild path must wipe.
"$RUNTIME" volume create devcontainer-home >/dev/null
"$RUNTIME" run --rm -v devcontainer-home:/h busybox \
    sh -c 'echo old > /h/marker' >/dev/null 2>&1

# DEV_ASSUME_YES=1 bypasses the prompt. The command runs inside the
# rebuilt container; the marker should be gone (volume was removed and
# repopulated from the image's empty /home/vscode).
out=$(DEV_ASSUME_YES=1 ./dev exec -- test -e /home/vscode/marker 2>&1)
rc=$?
# `test -e` returns 1 when missing → expected outcome here.
if [ "$rc" -eq 0 ]; then
    log_fail "marker still present after rebuild — volume not wiped (out: $out)"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Image labels now match host.
img_uid=$("$RUNTIME" image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "image not rebuilt to host UID; labels=$img_uid"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "DEV_ASSUME_YES rebuilds image and wipes named volumes"
exit 0
