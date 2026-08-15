#!/bin/bash
# scripts/test/scenarios/43-uid-gid-running-container.sh
# platform: linux
# privilege: user
#
# A running container backed by a mismatched image must be removed by
# the rebuild path. After DEV_ASSUME_YES=1 ./dev exec …, the image tag must
# point at a different image ID and the labels must match host.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/runtime.sh
. "$LIB/runtime.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux

# TODO(devcontainer-ci): quarantined on Debian 13 (trixie). Originally
# filed as "root cause unknown" because the build step's stderr was
# swallowed. 2026-07-03: the sibling scenarios (41/42/44) hit the same
# "could not build mismatched image" failure in CI, traced to this
# scenario's raw `docker buildx build` not forwarding GITHUB_TOKEN as a
# BuildKit secret (unlike dev's own runtime_build()) — mise install then
# hits GitHub's API anonymously and can hit the 60/hr limit, which is
# shared across the whole CI runner IP pool. Now fixed via
# build_image_with_uid_gid() in lib/runtime.sh. Leaving the skip in place
# until a green Debian run confirms this was the whole story — remove it
# then.
if [ -r /etc/os-release ] && grep -q '^ID=debian$' /etc/os-release; then
    log_skip "quarantined on Debian (flaky; see TODO in scenario)"
    exit 0
fi

trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
CN="dev-${WS}"
remember_container "$CN"

HOST_UID=$(id -u)

"$RUNTIME" rm -f "$CN" >/dev/null 2>&1
build_image_with_uid_gid 4242 4242 || exit 1
OLD_IMAGE_ID=$("$RUNTIME" images -q generic-devcontainer)

# Long-running stale container. Two things keep this deterministic:
#  - --entrypoint sleep: the normal entrypoint runs firewall-init.sh, which
#    needs NET_ADMIN (dev grants it at runtime; a bare `docker run` does not).
#    Without it the entrypoint fails and the container exits within ~1s, so
#    the rebuild would be removing an already-dead container instead of the
#    running one this scenario asserts. Running sleep directly keeps it up.
#  - no --rm: with --rm, a container exit triggers Docker's auto-removal,
#    which can race dev's `rm -f` and intermittently report "failed to
#    remove container". Without it, dev's `rm -f` is the sole remover — no
#    race. Cleanup is still guaranteed by remember_container + restore trap.
docker run -d --name "$CN" --entrypoint sleep generic-devcontainer 3600 >/dev/null

if ! DEV_ASSUME_YES=1 ./dev exec -- true >/dev/null 2>&1; then
    log_fail "dev failed during rebuild path"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

NEW_IMAGE_ID=$("$RUNTIME" images -q generic-devcontainer)
if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
    log_fail "image was not rebuilt (id unchanged: $OLD_IMAGE_ID)"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "labels still mismatched after rebuild: $img_uid"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Stale container must be gone (it was removed before rebuild).
if "$RUNTIME" ps --format '{{.Names}}' | grep -qx "$CN"; then
    log_fail "stale container $CN is still running"
    "$RUNTIME" rm -f "$CN" >/dev/null 2>&1
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "rebuild path removes stale container and re-tags image"
exit 0
