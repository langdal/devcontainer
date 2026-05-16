#!/bin/bash
# scripts/test/scenarios/23-cache-persists-restart.sh
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

# Step A: pull alpine in --dind.
./dev --dind -- docker pull alpine:3.20 >/dev/null || { log_fail "initial pull failed"; exit 1; }

# Step B: stop + start the same container (NOT --rm). 'dev' uses --rm by
# default, so we instead exit, recreate via dev, and check the volume retained
# the image. The named volume devcontainer-dind is the persistence boundary.
docker rm -f "$D" 2>/dev/null
out=$(./dev --dind -- docker images alpine --format '{{.Repository}}:{{.Tag}}' 2>&1)
if expect_grep "$out" '^alpine:3.20$'; then
    log_pass "image cache survives container destroy+recreate"
    exit 0
fi
log_fail "expected alpine:3.20 in cache after recreate; got: $out"
exit 1
