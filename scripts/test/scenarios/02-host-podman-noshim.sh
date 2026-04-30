#!/bin/bash
# scripts/test/scenarios/02-host-podman-noshim.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

# Install podman if missing; remember to remove it on exit if we did.
if ! command -v podman >/dev/null 2>&1; then
    if ! sudo apt-get update -qq >/dev/null 2>&1 || \
       ! sudo apt-get install -y --no-install-recommends podman >/dev/null 2>&1; then
        log_skip "could not install podman"
        exit 0
    fi
    remember_pkg_install podman
fi

# Mask docker (no shim).
mask_dir=$(mask_and_prepend docker)
remember_path_overlay "$mask_dir"

if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
    log_fail "docker should be masked but is reachable"
    exit 1
fi

cd "$(dirname "$0")/../../.."
out=$(./dev --dry-run 2>&1) || { log_fail "dev --dry-run failed: $out"; exit 1; }
if expect_grep "$out" '^podman run '; then
    log_pass "podman-only host: dev uses podman"
    exit 0
fi
log_fail "expected podman run, got: $out"
exit 1
