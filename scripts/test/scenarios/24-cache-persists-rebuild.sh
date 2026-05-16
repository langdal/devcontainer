#!/bin/bash
# scripts/test/scenarios/24-cache-persists-rebuild.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
D="dev-${WS}-dind"
remember_container "$D"
docker rm -f "$D" 2>/dev/null

# Step A: pull alpine.
./dev --dind -- docker pull alpine:3.20 >/dev/null || { log_fail "initial pull failed"; exit 1; }
docker rm -f "$D" 2>/dev/null

# Step B: rebuild the :dind image (--build).
./dev --dind --build -- docker version >/dev/null || { log_fail "rebuild start failed"; exit 1; }
docker rm -f "$D" 2>/dev/null

# Step C: confirm alpine still cached.
out=$(./dev --dind -- docker images alpine --format '{{.Repository}}:{{.Tag}}' 2>&1)
if expect_grep "$out" '^alpine:3.20$'; then
    log_pass "image cache survives --build rebuild"
    exit 0
fi
log_fail "expected alpine:3.20 in cache after --build; got: $out"
exit 1
