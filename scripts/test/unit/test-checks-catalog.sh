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
# shellcheck source=lib/dev/checks-catalog-nested.sh
. "$ROOT/lib/dev/checks-catalog-nested.sh"
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
# Pin the OS. This probe is platform-aware, so leaving it unpinned asserts the
# TEST HOST's platform rather than the mapping -- these three cases encode
# Linux semantics and failed on every Mac that ran them.
DEV_FAKE_OS=Linux DEV_FAKE_CMDS="docker" run_check runtime-present; [ "$CHECK_STATE" = pass ] || fail "docker present"
DEV_FAKE_OS=Linux DEV_FAKE_CMDS="podman" run_check runtime-present; [ "$CHECK_STATE" = pass ] || fail "podman present"
DEV_FAKE_OS=Linux DEV_FAKE_CMDS="git"    run_check runtime-present; [ "$CHECK_STATE" = fail ] || fail "no runtime should fail"
# Darwin takes podman ONLY -- Docker Desktop is unsupported. A Mac carrying
# just docker has to fail here, where the report explains itself, rather than
# at detect_runtime's refusal, which ends the report before it prints a reason.
# This is the branch the unpinned cases above were shadowing.
DEV_FAKE_OS=Darwin DEV_FAKE_CMDS="podman" run_check runtime-present
[ "$CHECK_STATE" = pass ] || fail "podman on Darwin should pass"
DEV_FAKE_OS=Darwin DEV_FAKE_CMDS="docker" run_check runtime-present
[ "$CHECK_STATE" = fail ] || fail "docker-only Darwin must fail (Docker Desktop is unsupported)"

# --- buildx: the 2026-08-15 false-green ---
DEV_FAKE_CMDS="docker docker-buildx" run_check buildx
[ "$CHECK_STATE" = pass ] || fail "buildx present should pass"
DEV_FAKE_CMDS="docker" run_check buildx
[ "$CHECK_STATE" = fail ] || fail "missing buildx must FAIL — this is the check that would have saved a whole session"
_chk_buildx_fix | grep -qi 'docker-buildx' || fail "buildx fix does not name the package"

# --- buildx: the 2026-08-15 false-negative ---
# Debian/Ubuntu's docker-buildx package (and Docker Desktop) installs the
# plugin under docker's cli-plugins dir, never as a standalone docker-buildx
# or buildx binary on PATH. A host in exactly that (extremely common) shape
# must still pass: this is the bug that inverted the full test matrix the
# day this check was wired into `dev up`.
DEV_FAKE_CMDS="docker" DEV_FAKE_BUILDX=true run_check buildx
[ "$CHECK_STATE" = pass ] || fail "buildx installed as a CLI plugin (no standalone binary) must still pass"

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
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_subid_grant
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

# --- engine-cli-match: the 2026-08-15 DOCKER_HOST bug ---
RUNTIME=docker
DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' run_check engine-cli-match
[ "$CHECK_STATE" = pass ] || fail "podman CLI + podman engine agree"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_engine_cli_match
_engine_server_name() { echo "Podman Engine"; }
DEV_FAKE_RUNTIME_VERSION='Docker version 29.1.3' run_check engine-cli-match
[ "$CHECK_STATE" = fail ] || fail "docker CLI on a podman socket must be flagged"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_engine_cli_match
_engine_server_name() { echo "Engine"; }
DEV_FAKE_RUNTIME_VERSION='Docker version 29.1.3' run_check engine-cli-match
[ "$CHECK_STATE" = pass ] || fail "docker CLI + dockerd agree"
_engine_server_name() { echo ""; }
DEV_FAKE_RUNTIME_VERSION='Docker version 29.1.3' run_check engine-cli-match
[ "$CHECK_STATE" = na ] || fail "engine unreachable must be na, not a false pass"

# ENGINE_CLI_SWITCHED (set by _prefer_podman_cli_for_podman_engine once it
# has already rewritten $RUNTIME to podman) must win regardless of what the
# CLI/engine now report — that is the whole reason the flag exists: by the
# time this probe runs post-switch, the CLI IS podman, so without the flag
# the checks above would find nothing to disagree about and wrongly pass.
ENGINE_CLI_SWITCHED=true
DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' run_check engine-cli-match
[ "$CHECK_STATE" = fail ] || fail "ENGINE_CLI_SWITCHED=true must fail even though the CLI now reports podman"
unset ENGINE_CLI_SWITCHED

# --- disk-space / memory: thresholds from docs/ci-testing.md ---
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_disk_space
_free_disk_gb() { echo 10; }; run_check disk-space; [ "$CHECK_STATE" = pass ] || fail "10 GB is enough"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_disk_space
_free_disk_gb() { echo 1; };  run_check disk-space; [ "$CHECK_STATE" = fail ] || fail "1 GB is not"
_free_disk_gb() { echo ""; }; run_check disk-space; [ "$CHECK_STATE" = na ]   || fail "undeterminable free space must be na, not fail"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_memory
_total_mem_gb() { echo 16; }; run_check memory;     [ "$CHECK_STATE" = pass ] || fail "16 GB is enough"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_memory
_total_mem_gb() { echo 4; };  run_check memory;     [ "$CHECK_STATE" = fail ] || fail "4 GB is not"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_memory
_total_mem_gb() { echo ""; }; run_check memory;     [ "$CHECK_STATE" = na ]   || fail "undeterminable memory must be na, not fail"
_total_mem_gb() { echo garbage; }; run_check memory; [ "$CHECK_STATE" = na ]  || fail "garbage memory reading must be na, not fail"

# --- github-token-scopes: a scoped token is power handed to the agent ---
GITHUB_TOKEN="" run_check github-token-scopes
[ "$CHECK_STATE" = na ] || fail "no token means not-applicable, not pass"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_github_token_scopes
_token_scopes() { echo "repo, workflow"; }
GITHUB_TOKEN=x run_check github-token-scopes; [ "$CHECK_STATE" = fail ] || fail "scoped token must warn"
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_github_token_scopes
_token_scopes() { echo ""; return 0; }
GITHUB_TOKEN=x run_check github-token-scopes; [ "$CHECK_STATE" = pass ] || fail "scopeless-and-verified token is fine"
# curl/transport failure (offline host, proxy interception, timeout) must
# read as na, never as a false pass: an unverified token is not a safe one.
_token_scopes() { return 1; }
GITHUB_TOKEN=x run_check github-token-scopes; [ "$CHECK_STATE" = na ] || fail "transport failure must be na, not pass"

# A fine-grained PAT is scoped by construction, so there is nothing to probe
# and no network call to make. That short-circuit lived only in approval.sh's
# copy before the two were unified; this exercises the REAL _token_scopes to
# prove the unified one kept it. Run it in a child shell so re-sourcing the
# catalogue does not shadow the stubs this file installed above.
pat_state=$(bash -c '
  set -u
  . "'"$ROOT"'/lib/dev/runtime.sh"
  . "'"$ROOT"'/lib/dev/checks.sh"
  . "'"$ROOT"'/lib/dev/checks-catalog.sh"
  RUNTIME=docker; RUNTIME_ARGS=""
  GITHUB_TOKEN=github_pat_11ABCDEFG_notarealtoken run_check github-token-scopes
  echo "$CHECK_STATE"')
[ "$pat_state" = na ] \
    || fail "fine-grained PAT needs no probe — expected na, got $pat_state"

# --- selinux ---
# shellcheck disable=SC2329  # invoked indirectly via run_check -> _chk_selinux_enforcing
_selinux_mode() { echo Enforcing; }; run_check selinux-enforcing; [ "$CHECK_STATE" = fail ] || fail "enforcing"
_selinux_mode() { echo ""; };        run_check selinux-enforcing; [ "$CHECK_STATE" = na ]   || fail "absent = na"

echo "PASS: phase-0 and blocking probes"
