#!/bin/bash
# scripts/test/scenarios/14-selinux-enforcing.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"
require_platform linux

if ! command -v getenforce >/dev/null 2>&1; then
    log_skip "SELinux not installed (no getenforce binary)"
    exit 0
fi
if [ "$(getenforce)" != "Enforcing" ]; then
    log_skip "SELinux not in Enforcing mode"
    exit 0
fi

cd "$(dirname "$0")/../../.."
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null

if ! ./dev --dind -- docker version >/dev/null 2>&1; then
    log_fail "SELinux enforcing host: --dind failed (may need --security-opt label=disable)"
    exit 1
fi
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null
log_pass "SELinux enforcing host works"
exit 0
