#!/bin/bash
# scripts/test/scenarios/04-host-both-runtimes.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

# Both docker and podman must be present.
if ! command -v docker >/dev/null 2>&1; then
    log_skip "docker not installed; skipping both-runtimes scenario"
    exit 0
fi
apt_install_remember podman || { log_skip "could not install podman"; exit 0; }
remember_pkg_install podman

cd "$(dirname "$0")/../../.."
out=$(./dev --dry-run 2>&1) || { log_fail "dev --dry-run failed: $out"; exit 1; }
if expect_grep "$out" '^docker run '; then
    log_pass "both runtimes installed: dev prefers docker"
    exit 0
fi
log_fail "expected docker run (preferred), got: $out"
exit 1
