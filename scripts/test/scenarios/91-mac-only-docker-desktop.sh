#!/bin/bash
# scripts/test/scenarios/91-mac-only-docker-desktop.sh
# platform: darwin
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/runtime.sh
. "$LIB/runtime.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform darwin
trap restore_host EXIT

# Mask podman so only docker (Docker Desktop) is visible. mask_and_prepend
# mutates PATH; call as a plain statement (not via $(...)).
mask_and_prepend podman

cd "$(dirname "$0")/../../.." || exit 1

if out=$(./dev --dind -- true 2>&1); then
    log_fail "expected dev to refuse Docker Desktop on macOS; got: $out"
    exit 1
fi
if expect_grep "$out" "Docker Desktop is not supported"; then
    log_pass "Docker Desktop only on macOS produces clean error"
    exit 0
fi
log_fail "expected 'Docker Desktop is not supported' message; got: $out"
exit 1
