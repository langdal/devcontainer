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
# shellcheck source=lib/dev/checks-catalog.sh
. "$ROOT/lib/dev/checks-catalog.sh"
RUNTIME=docker; RUNTIME_ARGS=""

# Registry ids use hyphens; shell functions use underscores. Pin the probe's
# input so this asserts the MAPPING and not the test host's runtime.
DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' run_check not-docker-desktop
[ "$CHECK_STATE" = pass ] || fail "run_check did not map hyphens to underscores (got $CHECK_STATE)"

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

# --- userns-sysctl: the host control that blocked 10 scenarios on 2026-08-15 ---
DEV_FAKE_SYSFS_VALUE=0 run_check userns-sysctl; [ "$CHECK_STATE" = pass ] || fail "sysctl 0 is fine"
DEV_FAKE_SYSFS_VALUE=1 run_check userns-sysctl; [ "$CHECK_STATE" = fail ] || fail "sysctl 1 must fail"
_chk_userns_sysctl_fix | grep -q 'apparmor_restrict_unprivileged_userns=0' \
    || fail "userns fix lost its sysctl command"

# --- subid-grant: 165535 is the image contract, not a round number ---
# _chk_subid_grant short-circuits to 'na' on a rootful runtime, so pin
# rootlessness here — otherwise this case is decided by whatever runtime the
# machine running the tests happens to have.
runtime_is_rootless() { return 0; }
# shellcheck disable=SC2329  # invoked indirectly via subid_total override below
_subid_stub() { echo 200000; }
subid_total() { _subid_stub; }
DIND_MIN_SUBIDS=165535 run_check subid-grant; [ "$CHECK_STATE" = pass ] || fail "200000 ids is enough"
_subid_stub() { echo 65536; }
DIND_MIN_SUBIDS=165535 run_check subid-grant; [ "$CHECK_STATE" = fail ] || fail "65536 ids is too few"
_chk_subid_grant_fix | grep -q 'usermod --add-subuids' || fail "subid fix lost usermod"

# --- fuse-device ---
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_fuse_device
_have_dev_fuse() { return 0; }; run_check fuse-device; [ "$CHECK_STATE" = pass ] || fail "fuse present"
_have_dev_fuse() { return 1; }; run_check fuse-device; [ "$CHECK_STATE" = fail ] || fail "fuse missing"

# --- cgroup2 ---
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_cgroup2
_cgroup_version() { echo 2; }; run_check cgroup2; [ "$CHECK_STATE" = pass ] || fail "cgroup v2"
_cgroup_version() { echo 1; }; run_check cgroup2; [ "$CHECK_STATE" = fail ] || fail "cgroup v1 must fail"

echo "PASS: phase-0 and blocking probes"
