#!/bin/bash
# scripts/test/scenarios/03-host-podman-with-shim.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

# Ensure podman is present; install podman-docker (the shim) if missing.
apt_install_remember podman || { log_skip "could not install podman"; exit 0; }
apt_install_remember podman-docker || { log_skip "could not install podman-docker"; exit 0; }
remember_pkg_install podman
remember_pkg_install podman-docker

# Confirm both 'docker' (shim) and 'podman' resolve.
if ! command -v docker >/dev/null 2>&1; then
    log_fail "podman-docker installed but 'docker' not on PATH"; exit 1
fi
if ! command -v podman >/dev/null 2>&1; then
    log_fail "podman missing"; exit 1
fi

cd "$(dirname "$0")/../../.."
out=$(./dev --dry-run 2>&1) || { log_fail "dev --dry-run failed: $out"; exit 1; }
# detect_runtime prefers docker — even when docker is the podman shim. That's
# correct: dev does not (and should not) try to inspect what 'docker' really is.
if expect_grep "$out" '^docker run '; then
    log_pass "podman with docker shim: dev uses 'docker' (shim resolves to podman)"
    exit 0
fi
log_fail "expected docker run, got: $out"
exit 1
