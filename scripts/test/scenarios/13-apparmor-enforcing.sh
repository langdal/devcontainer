#!/bin/bash
# scripts/test/scenarios/13-apparmor-enforcing.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"
require_platform linux

if ! command -v aa-status >/dev/null 2>&1; then
    log_skip "AppArmor not installed on host"
    exit 0
fi
if ! sudo aa-status --enabled >/dev/null 2>&1; then
    log_skip "AppArmor not enabled (kernel may not support it)"
    exit 0
fi

cd "$(dirname "$0")/../../.."
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null

# We pass --security-opt apparmor=unconfined; this should work in enforcing mode.
if ! ./dev --dind -- docker version >/dev/null 2>&1; then
    log_fail "AppArmor enforcing host: --dind failed"
    exit 1
fi
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null
log_pass "AppArmor enforcing + apparmor=unconfined opt works"
exit 0
