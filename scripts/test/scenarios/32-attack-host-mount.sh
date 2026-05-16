#!/bin/bash
# scripts/test/scenarios/32-attack-host-mount.sh
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

./dev --dind -- docker pull alpine:3.20 >/dev/null 2>&1 || true

# Drop a sentinel into /etc/test-host-sentinel on the HOST (sudo) so we can
# tell whether a -v / mount inside the nested container reaches the host.
HOST_SENTINEL="/etc/test-host-sentinel-$$"
sudo sh -c "echo HOST > $HOST_SENTINEL"
# Cleanup of the host sentinel is folded into the EXIT trap below.
trap 'sudo rm -f '"$HOST_SENTINEL"'; restore_host' EXIT

# Drop a different sentinel into the dev container's /etc.
./dev --dind -- bash -c 'echo CONTAINER | sudo tee /etc/test-host-sentinel-DEV >/dev/null 2>&1 || true'

# From a nested container, mount / and read /etc/test-host-sentinel-*.
# The mount points at the dev container's filesystem, NOT the host's,
# so the HOST sentinel must NOT be visible.
out=$(./dev --dind -- docker run --rm -v /:/host alpine:3.20 \
    ls /host/etc 2>&1 | grep test-host-sentinel || echo "")
host_visible=$(echo "$out" | grep -c "test-host-sentinel-$$" || true)

if [ "$host_visible" -eq 0 ]; then
    log_pass "nested -v /:/host did not expose host filesystem"
    exit 0
fi
log_fail "host sentinel visible inside nested -v /:/host: $out"
exit 1
