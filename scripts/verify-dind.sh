#!/bin/bash
# scripts/verify-dind.sh
#
# Heavier DinD checks. Run from inside the dev container in --dind mode.
# Each check echoes PASS/FAIL on a single line and exits the script
# non-zero if any check fails.
#
# Designed to be invoked by host-side scenario scripts via:
#     ./dev --dind -- /workspace/scripts/verify-dind.sh
set -u

PASS=0; FAIL=0
fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }

if [ -z "${DEVCONTAINER_DIND:-}" ]; then
    echo "verify-dind.sh: DEVCONTAINER_DIND not set; this script is meant for --dind containers" >&2
    exit 2
fi

# D1: docker build of a smoke Dockerfile that runs apt-get update.
echo "D1. docker build (proxy works during build)..."
build_log=$(mktemp)
if docker build -t verify-dind-smoke -f /workspace/scripts/test/fixtures/Dockerfile.smoke \
        /workspace/scripts/test/fixtures/ >"$build_log" 2>&1; then
    pass "D1 docker build of fixtures/Dockerfile.smoke"
else
    fail "D1 docker build failed; log: $build_log"
    cat "$build_log" >&2
fi
rm -f "$build_log"

# D2: testcontainers smoke (postgres).
echo "D2. testcontainers-style postgres smoke..."
if /workspace/scripts/test/fixtures/pg-smoke.sh; then
    pass "D2 postgres smoke"
else
    fail "D2 postgres smoke"
fi

# D3: docker build of this repo's Dockerfile (base target only — :dind from
# inside :dind is recursive overhead with little additional signal).
echo "D3. docker build of /workspace (base target)..."
build_log=$(mktemp)
if docker build --target base -t verify-dind-self /workspace >"$build_log" 2>&1; then
    pass "D3 self build (base target)"
else
    fail "D3 self build; log:"
    tail -50 "$build_log" >&2
fi
rm -f "$build_log"

# D4 and D5 are exercised by host-side scenarios (cache-persists-restart,
# cache-persists-rebuild, dockerd-restart). They cannot be run from inside
# a single container session.

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
