#!/bin/bash
# scripts/test/scenarios/33-attack-nested-egress.sh
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

./dev --dind -- docker pull alpine:3.20 >/dev/null 2>&1 || true

out=$(./dev --dind -- docker run --rm alpine:3.20 \
    wget -T3 -q -O- https://example.com 2>&1 || echo BLOCKED)
if expect_grep "$out" "BLOCKED"; then
    log_pass "nested container blocked from reaching example.com"
    exit 0
fi
log_fail "nested container reached example.com (firewall is broken); got: $out"
exit 1
