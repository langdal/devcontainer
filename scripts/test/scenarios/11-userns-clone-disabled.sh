#!/bin/bash
# scripts/test/scenarios/11-userns-clone-disabled.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/restore.sh"
require_platform linux

# Some kernels do not expose this sysctl (it's a Debian/Ubuntu thing).
if ! sysctl -n kernel.unprivileged_userns_clone >/dev/null 2>&1; then
    log_skip "kernel.unprivileged_userns_clone not present on this kernel"
    exit 0
fi

snapshot_sysctl kernel.unprivileged_userns_clone
trap restore_host EXIT

sudo sysctl -w kernel.unprivileged_userns_clone=0 >/dev/null

cd "$(dirname "$0")/../../.."
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null

# We expect dev --dind to either fail to start or to start but have dockerd
# fail. Either way, 'docker version' inside should not succeed within 30s.
if timeout 30 ./dev --dind -- docker version >/dev/null 2>&1; then
    log_fail "expected --dind to fail with userns_clone=0 but it succeeded"
    docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null
    exit 1
fi
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null
log_pass "userns_clone=0 produces a clean failure (no hang)"
exit 0
