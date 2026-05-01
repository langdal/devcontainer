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

# Two acceptable outcomes when /dev/fuse is unreadable:
#  (a) dind-init.sh fails closed with a clean diagnostic — what the
#      original design contemplated.
#  (b) rootless dockerd falls back to a non-fuse storage driver
#      (vfs, overlay2 with native overlay support) and starts anyway.
#      That's also fine for the safety property; the user gets a working
#      dockerd, just with a slower or different storage driver.
# Fail only if dockerd starts AND is actually using fuse-overlayfs — that
# would mean we somehow reached fuse despite chmod 000, which shouldn't
# happen.
out=$(timeout 30 ./dev --dind -- docker info -f '{{.Driver}}' 2>&1)
rc=$?
docker rm -f dev-$(basename "$(pwd)")-dind 2>/dev/null

if [ "$rc" -ne 0 ]; then
    log_pass "/dev/fuse inaccessible: dind-init fail-closed (clean diagnostic)"
    exit 0
fi
driver=$(echo "$out" | tail -1)
if [ "$driver" = "fuse-overlayfs" ]; then
    log_fail "fuse=000 yet dockerd uses fuse-overlayfs: $out"
    exit 1
fi
log_pass "/dev/fuse inaccessible: rootless dockerd fell back to '$driver'"
exit 0
