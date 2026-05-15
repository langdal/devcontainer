#!/bin/bash
# scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh
# platform: linux
#
# Image built for a different UID/GID than the host: a non-interactive
# `dev` invocation must refuse to attach and exit non-zero with a
# diagnostic referencing the host's UID/GID and a `dev --build` hint.
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

# Bypass dev to bake labels of 4242:4242 directly.
docker rm -f "dev-${WS}" >/dev/null 2>&1
if ! docker buildx build --network=host \
        --build-arg USER_UID=4242 --build-arg USER_GID=4242 \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build mismatched image"
    exit 1
fi

# Closed stdin → non-interactive. dev should exit non-zero.
out=$(./dev -- true </dev/null 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    log_fail "expected dev to refuse attach with mismatched labels; got rc=0 output: $out"
    # Restore image before exit so subsequent scenarios are clean.
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -qE "${HOST_UID}|UID"; then
    log_fail "expected diagnostic mentioning host UID; got: $out"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -q "dev --build"; then
    log_fail "expected '--build' hint in diagnostic; got: $out"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Image must still have the 4242 labels (no auto-rebuild).
img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "4242" ]; then
    log_fail "image was rebuilt without consent: labels=$img_uid"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Restore image to host UID/GID for subsequent scenarios.
./dev --build -- true >/dev/null 2>&1 || true

log_pass "non-interactive mismatch refuses attach with diagnostic"
exit 0
