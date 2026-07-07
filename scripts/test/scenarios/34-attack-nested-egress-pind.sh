#!/bin/bash
# scripts/test/scenarios/34-attack-nested-egress-pind.sh
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
P="dev-${WS}-pind"
remember_container "$P"
"$RUNTIME" rm -f "$P" 2>/dev/null

./dev --pind -- podman pull alpine:3.20 >/dev/null 2>&1 || true

out=$(./dev --pind -- podman run --rm alpine:3.20 \
    wget -T3 -q -O- https://example.com 2>&1 || echo BLOCKED)
if expect_grep "$out" "BLOCKED"; then
    log_pass "nested podman container blocked from reaching example.com"
    exit 0
fi
log_fail "nested podman container reached example.com (firewall is broken); got: $out"
exit 1
