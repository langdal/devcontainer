#!/bin/bash
# scripts/test/scenarios/46-version-mismatch.sh
# platform: linux
# privilege: user
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

# The ids dev will expect, NOT `id -u`/`id -g`: under rootless podman it bakes
# 1000 and maps the host user onto it (lib/dev/ids.sh). Building the fixture for
# the invoking uid instead made the UID check fire first and short-circuit the
# version check this scenario exists to exercise — on any host whose uid is not
# 1000, which is why it went red on CI (runner uid 1001) and green locally.
read -r EXP_UID EXP_GID _ <<< "$(expected_image_ids)"

# Read the $VERSION literal the dev script bakes into image labels and
# names in the version-mismatch prompt. NOT `dev --version`: that prefers
# `git describe` (e.g. v1.3.0-41-gc88f3a7-dirty) which diverges from the
# literal on any commit past the latest tag, whereas the mismatch prompt
# and the dev.version label both use the stable literal (see
# resolve_dev_version's note in dev). Asserting against the literal keeps
# this scenario correct on a full git checkout, not just tag-less copies.
SCRIPT_VERSION=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' dev | head -1)
if [ -z "$SCRIPT_VERSION" ]; then
    log_fail "could not read \$VERSION literal from dev script"
    exit 1
fi

OLD_VERSION="0.0.0-stale"

"$RUNTIME" rm -f "dev-${WS}" >/dev/null 2>&1

# Bake an image whose UID/GID labels MATCH what dev expects, with an
# intentionally-stale dev.version label, so the UID check passes and the version
# check is what we actually exercise.
build_scenario_image "could not build image with stale dev.version label" \
    --build-arg "USER_UID=${EXP_UID}" \
    --build-arg "USER_GID=${EXP_GID}" \
    --build-arg "DEV_VERSION=${OLD_VERSION}" \
    -t generic-devcontainer || exit 1

# --- Path 1: non-interactive default-no ---
# Closed stdin → not a TTY → dev should warn and continue (rc=0).
out=$(./dev exec -- true </dev/null 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    log_fail "expected dev to continue past version mismatch in non-tty; rc=$rc out: $out"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -q "$OLD_VERSION"; then
    log_fail "expected diagnostic to mention stale version '$OLD_VERSION'; got: $out"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -q "$SCRIPT_VERSION"; then
    log_fail "expected diagnostic to mention current version '$SCRIPT_VERSION'; got: $out"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_version=$("$RUNTIME" image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.version" }}' 2>/dev/null)
if [ "$img_version" != "$OLD_VERSION" ]; then
    log_fail "image was rebuilt without consent: label=$img_version"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Stop the container started by path 1 so path 2 actually exercises the
# build path, not the attach-to-running-container short-circuit.
"$RUNTIME" rm -f "dev-${WS}" >/dev/null 2>&1

# --- Path 2: DEV_ASSUME_YES rebuilds ---
if ! DEV_ASSUME_YES=1 ./dev exec -- true >/dev/null 2>&1; then
    log_fail "dev failed under DEV_ASSUME_YES with stale version label"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_version=$("$RUNTIME" image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.version" }}' 2>/dev/null)
if [ "$img_version" != "$SCRIPT_VERSION" ]; then
    log_fail "label not updated after rebuild: got '$img_version', want '$SCRIPT_VERSION'"
    ./dev exec --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "version mismatch: non-tty continues; DEV_ASSUME_YES rebuilds"
exit 0
