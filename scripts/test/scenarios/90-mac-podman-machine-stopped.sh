#!/bin/bash
# scripts/test/scenarios/90-mac-podman-machine-stopped.sh
# platform: darwin
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/restore.sh"
require_platform darwin
trap restore_host EXIT

cd "$(dirname "$0")/../../.."

# Stop podman machine if running. Capture state for restoration.
RESUME=0
if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q '^true$'; then
    podman machine stop >/dev/null 2>&1
    RESUME=1
fi

cleanup() {
    if [ "$RESUME" -eq 1 ]; then
        podman machine start >/dev/null 2>&1
    fi
    restore_host
}
trap cleanup EXIT

if out=$(./dev --dind -- true 2>&1); then
    log_fail "expected dev --dind to fail with podman machine stopped; got: $out"
    exit 1
fi
if expect_grep "$out" "podman machine"; then
    log_pass "podman machine stopped: dev errors with hint"
    exit 0
fi
log_fail "expected error mentioning 'podman machine'; got: $out"
exit 1
