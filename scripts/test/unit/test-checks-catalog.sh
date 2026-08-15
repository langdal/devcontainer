#!/usr/bin/env bash
# Unit: every probe in the check catalogue, against stubbed conditions.
# No real runtime, no real /proc, no real platform — that is the point: the
# macOS probes are verified here from Linux, and the Linux ones from macOS.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
# shellcheck source=lib/dev/checks.sh
. "$ROOT/lib/dev/checks.sh"
RUNTIME=docker; RUNTIME_ARGS=""

# Registry ids use hyphens; shell functions use underscores.
run_check not-docker-desktop
[ "$CHECK_STATE" != "na" ] || fail "run_check did not map hyphens to underscores"

# --- platform-supported ---
DEV_FAKE_OS=Linux  run_check platform-supported; [ "$CHECK_STATE" = pass ] || fail "Linux unsupported?"
DEV_FAKE_OS=Darwin run_check platform-supported; [ "$CHECK_STATE" = pass ] || fail "Darwin unsupported?"
DEV_FAKE_OS=SunOS  run_check platform-supported; [ "$CHECK_STATE" = fail ] || fail "SunOS should fail"

# --- runtime-present ---
DEV_FAKE_CMDS="docker" run_check runtime-present; [ "$CHECK_STATE" = pass ] || fail "docker present"
DEV_FAKE_CMDS="podman" run_check runtime-present; [ "$CHECK_STATE" = pass ] || fail "podman present"
DEV_FAKE_CMDS="git"    run_check runtime-present; [ "$CHECK_STATE" = fail ] || fail "no runtime should fail"

# --- buildx: the 2026-08-15 false-green ---
DEV_FAKE_CMDS="docker docker-buildx" run_check buildx
[ "$CHECK_STATE" = pass ] || fail "buildx present should pass"
DEV_FAKE_CMDS="docker" run_check buildx
[ "$CHECK_STATE" = fail ] || fail "missing buildx must FAIL — this is the check that would have saved a whole session"
_chk_buildx_fix | grep -qi 'docker-buildx' || fail "buildx fix does not name the package"

# --- not-docker-desktop ---
DEV_FAKE_RUNTIME_VERSION='Docker version 27.0.0, build abc' run_check not-docker-desktop
[ "$CHECK_STATE" = fail ] || fail "Docker Desktop must fail on macOS"
DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' run_check not-docker-desktop
[ "$CHECK_STATE" = pass ] || fail "podman is not Docker Desktop"

# --- podman-machine ---
DEV_FAKE_MACHINE_RUNNING=true  run_check podman-machine; [ "$CHECK_STATE" = pass ] || fail "running machine"
DEV_FAKE_MACHINE_RUNNING=false run_check podman-machine; [ "$CHECK_STATE" = fail ] || fail "stopped machine"
_chk_podman_machine_fix | grep -q 'podman machine start' || fail "machine fix lost its command"

# --- workspace-not-root ---
HOST_UID=1000 run_check workspace-not-root; [ "$CHECK_STATE" = pass ] || fail "uid 1000 is fine"
HOST_UID=0    run_check workspace-not-root; [ "$CHECK_STATE" = fail ] || fail "root must fail"

echo "PASS: phase-0 and blocking probes"
