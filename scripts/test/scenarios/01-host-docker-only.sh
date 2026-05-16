#!/bin/bash
# scripts/test/scenarios/01-host-docker-only.sh
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

# Setup: mask podman if installed. mask_and_prepend mutates the shell's
# PATH (and registers cleanup), so it MUST be called as a plain statement,
# not via $(...) — the subshell would swallow the PATH export.
if command -v podman >/dev/null 2>&1; then
    mask_and_prepend podman
fi
trap restore_host EXIT

# Confirm docker is on PATH and podman is masked.
if ! command -v docker >/dev/null 2>&1; then
    log_skip "docker not installed on host"
    exit 0
fi
if command -v podman >/dev/null 2>&1 && podman --version >/dev/null 2>&1; then
    log_fail "podman should be masked but is reachable"
    exit 1
fi

cd "$(dirname "$0")/../../.." || exit 1
out=$(./dev --dry-run 2>&1) || { log_fail "dev --dry-run failed: $out"; exit 1; }
if expect_grep "$out" '^docker run '; then
    log_pass "docker-only host: dev uses docker"
    exit 0
fi
log_fail "expected docker run, got: $out"
exit 1
