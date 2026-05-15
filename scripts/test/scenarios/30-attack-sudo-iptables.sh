#!/bin/bash
# scripts/test/scenarios/30-attack-sudo-iptables.sh
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

# Inside --dind, sudo must NOT work (vscode is not in sudoers).
out=$(./dev --dind -- bash -c 'sudo -n iptables -F 2>&1 || echo BLOCKED')
if expect_grep "$out" "BLOCKED"; then
    log_pass "sudo iptables -F denied inside --dind"
    exit 0
fi
log_fail "sudo iptables -F was NOT blocked; output: $out"
exit 1
