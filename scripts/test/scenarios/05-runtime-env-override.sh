#!/bin/bash
# scripts/test/scenarios/05-runtime-env-override.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/runtime.sh
. "$LIB/runtime.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

if ! command -v docker >/dev/null 2>&1; then
    log_skip "docker not installed; cannot test override"
    exit 0
fi
apt_install_remember podman || { log_skip "could not install podman"; exit 0; }
remember_pkg_install podman

cd "$(dirname "$0")/../../.." || exit 1

# 1. With both installed, DEV_RUNTIME=podman should force podman.
out=$(DEV_RUNTIME=podman ./dev --dry-run 2>&1) || { log_fail "DEV_RUNTIME=podman failed: $out"; exit 1; }
if ! expect_grep "$out" '^podman run '; then
    log_fail "DEV_RUNTIME=podman did not pick podman; got: $out"; exit 1
fi

# 2. Bogus DEV_RUNTIME should fail with a clean message.
if out=$(DEV_RUNTIME=does-not-exist ./dev --dry-run 2>&1); then
    log_fail "DEV_RUNTIME=does-not-exist should have failed but exited 0"; exit 1
fi
if ! expect_grep "$out" "not found on PATH"; then
    log_fail "expected 'not found on PATH' diagnostic; got: $out"; exit 1
fi

log_pass "DEV_RUNTIME override behaves correctly"
exit 0
