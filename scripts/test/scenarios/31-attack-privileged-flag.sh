#!/bin/bash
# scripts/test/scenarios/31-attack-privileged-flag.sh
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

# Make sure alpine is cached so this test focuses on --privileged behaviour
# rather than registry traffic.
./dev --dind -- docker pull alpine:3.20 >/dev/null 2>&1 || true

# Rootless dockerd cannot grant --privileged in any meaningful sense; even if
# the run "succeeds", the container does not actually have host privilege.
# We assert the safer thing: we cannot mount a real cgroup tree on /sys/fs/cgroup
# inside a --privileged nested container. (This is how real privileged escapes
# are typically attempted.)
out=$(./dev --dind -- docker run --rm --privileged alpine:3.20 \
    sh -c 'mount -t cgroup2 cgroup2 /tmp/c 2>&1; ls /tmp/c 2>&1' 2>&1)
# Either the run fails outright, or the mount fails. Both are acceptable.
if expect_grep "$out" "Operation not permitted" || \
   expect_grep "$out" "permission denied" || \
   expect_grep "$out" "cgroup_root" || \
   expect_grep "$out" "Error response from daemon"; then
    log_pass "privileged escape attempt denied (rootless dockerd)"
    exit 0
fi
log_fail "expected privileged escape to be denied; got: $out"
exit 1
