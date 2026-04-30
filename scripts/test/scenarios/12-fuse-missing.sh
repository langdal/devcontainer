#!/bin/bash
# scripts/test/scenarios/12-fuse-missing.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/restore.sh"
require_platform linux

if [ ! -e /dev/fuse ]; then
    log_skip "/dev/fuse not present on host (already missing)"
    exit 0
fi

snapshot_file_mode /dev/fuse
trap restore_host EXIT

sudo chmod 000 /dev/fuse

cd "$(dirname "$0")/../../.."
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null

if timeout 30 ./dev --dind -- docker version >/dev/null 2>&1; then
    log_fail "expected --dind to fail with /dev/fuse 000 but it succeeded"
    docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null
    exit 1
fi
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null
log_pass "/dev/fuse inaccessible produces a clean failure"
exit 0
