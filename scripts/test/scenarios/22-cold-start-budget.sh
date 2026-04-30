#!/bin/bash
# scripts/test/scenarios/22-cold-start-budget.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
D="dev-${WS}-dind"
remember_container "$D"
docker rm -f "$D" 2>/dev/null

start=$(date +%s)
if ! ./dev --dind -- docker version >/dev/null 2>&1; then
    log_fail "dev --dind -- docker version did not succeed"
    exit 1
fi
end=$(date +%s)
elapsed=$((end - start))

if [ "$elapsed" -gt 30 ]; then
    log_fail "cold start took ${elapsed}s (> 30s budget)"
    exit 1
fi
if [ "$elapsed" -gt 10 ]; then
    log_pass "cold start ${elapsed}s (over Linux 10s target but within 30s budget)"
else
    log_pass "cold start ${elapsed}s (within Linux 10s target)"
fi
exit 0
