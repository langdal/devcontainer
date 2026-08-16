#!/bin/bash
# scripts/test/scenarios/34-attack-nested-egress-pind.sh
# platform: linux
# privilege: user
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

./dev exec --pind -- podman pull alpine:3.20 >/dev/null 2>&1 || true

out=$(./dev exec --pind -- podman run --rm alpine:3.20 \
    sh -c 'wget -T3 -q -O- https://example.com 2>&1 || echo NESTED_BLOCKED') \
    || { log_fail "outer exec failed (image/pind/podman?): $out"; exit 1; }
if expect_grep "$out" "NESTED_BLOCKED"; then
    log_pass "nested podman container blocked from reaching example.com"
    exit 0
fi
log_fail "nested podman container reached example.com (firewall is broken); got: $out"
exit 1
