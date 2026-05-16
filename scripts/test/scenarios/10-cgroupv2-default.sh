#!/bin/bash
# scripts/test/scenarios/10-cgroupv2-default.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

# Sanity: cgroup v2 in use (single unified hierarchy at /sys/fs/cgroup).
if ! grep -q 'cgroup2' /proc/mounts; then
    log_skip "host is not on cgroup v2"
    exit 0
fi

cd "$(dirname "$0")/../../.." || exit 1
docker rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null

if ! ./dev --dind -- docker version >/dev/null 2>&1; then
    log_fail "dev --dind on cgroup v2 failed; check dockerd-rootless.log"
    exit 1
fi
docker rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null
log_pass "cgroup v2 + rootless dockerd works"
exit 0
