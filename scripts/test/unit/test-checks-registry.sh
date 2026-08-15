#!/usr/bin/env bash
# Unit: the check registry's indirections, applicability filter and runner.
# Nothing here contacts a real runtime, filesystem or platform: every probe
# goes through an indirection this file overrides. That is what lets the
# macOS checks be exercised from Linux and vice versa.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
RUNTIME=""; RUNTIME_ARGS=""

# --- indirections ---------------------------------------------------------
command -v _have_cmd      >/dev/null 2>&1 || fail "_have_cmd not defined"
command -v _runtime_version >/dev/null 2>&1 || fail "_runtime_version not defined"
command -v _read_sysfs    >/dev/null 2>&1 || fail "_read_sysfs not defined"

# _host_os honours DEV_FAKE_OS (added 2026-08-15).
[ "$(DEV_FAKE_OS=Darwin _host_os)" = "Darwin" ] || fail "_host_os ignored DEV_FAKE_OS"

# _have_cmd finds a real builtin-backed binary and rejects a nonsense one.
_have_cmd sh          || fail "_have_cmd could not find sh"
_have_cmd zzz-no-such && fail "_have_cmd found a nonexistent command"

# DEV_FAKE_CMDS is a space-separated allowlist; when set it REPLACES the real
# lookup entirely, so a test host's actual binaries cannot leak into a case.
DEV_FAKE_CMDS="docker podman" _have_cmd docker || fail "DEV_FAKE_CMDS did not grant docker"
DEV_FAKE_CMDS="podman" _have_cmd docker        && fail "DEV_FAKE_CMDS leaked a real docker"
DEV_FAKE_CMDS="podman" _have_cmd sh            && fail "DEV_FAKE_CMDS leaked a real sh"

# _runtime_version is overridable without a runtime present.
[ "$(DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' _runtime_version)" = "podman version 5.7.0" ] \
    || fail "_runtime_version ignored DEV_FAKE_RUNTIME_VERSION"

# _read_sysfs reads a real file, returns empty for a missing one, and is
# overridable by path so /proc entries can be faked on macOS.
tmp=$(mktemp); echo 1 > "$tmp"
[ "$(_read_sysfs "$tmp")" = "1" ] || fail "_read_sysfs could not read a real file"
[ -z "$(_read_sysfs /no/such/path/at/all)" ] || fail "_read_sysfs invented content"
[ "$(DEV_FAKE_SYSFS_VALUE=0 _read_sysfs "$tmp")" = "0" ] || fail "_read_sysfs ignored override"
rm -f "$tmp"

# --- registry -------------------------------------------------------------
# shellcheck source=lib/dev/checks.sh
. "$ROOT/lib/dev/checks.sh"

# Field extraction is 1-indexed and tolerates a title containing spaces.
e="buildx|1|linux,darwin:docker|block|docker buildx present"
[ "$(check_field "$e" 1)" = "buildx" ]                || fail "field 1"
[ "$(check_field "$e" 2)" = "1" ]                     || fail "field 2"
[ "$(check_field "$e" 4)" = "block" ]                 || fail "field 4"
[ "$(check_field "$e" 5)" = "docker buildx present" ] || fail "field 5 lost its spaces"

# Applicability: platform list, runtime list, and '*' wildcards.
check_applies "linux,darwin:docker" Linux  docker || fail "linux:docker should apply on Linux+docker"
check_applies "linux,darwin:docker" Darwin docker || fail "darwin listed but rejected"
check_applies "linux,darwin:docker" Linux  podman && fail "docker-only check applied to podman"
check_applies "linux:*"             Linux  podman || fail "runtime wildcard rejected"
check_applies "linux:*"             Darwin podman && fail "linux-only check applied on Darwin"
check_applies "*:*"                 Darwin podman || fail "full wildcard rejected"
check_applies "darwin:podman"       Linux  podman && fail "darwin-only check applied on Linux"

# A probe's three states map onto CHECK_STATE, and an unknown id is 'na'
# rather than a silent pass.
_chk_fixture_pass() { return 0; }
_chk_fixture_fail() { return 1; }
_chk_fixture_na()   { return 2; }
run_check fixture_pass; [ "$CHECK_STATE" = pass ] || fail "0 should be pass, got $CHECK_STATE"
run_check fixture_fail; [ "$CHECK_STATE" = fail ] || fail "1 should be fail, got $CHECK_STATE"
run_check fixture_na;   [ "$CHECK_STATE" = na ]   || fail "2 should be na, got $CHECK_STATE"
run_check no_such_check
[ "$CHECK_STATE" = na ] || fail "missing probe must be na, never pass — got $CHECK_STATE"

# Selection filters by phase, applicability and severity. Phase 0 exists so
# 'is there a runtime at all' can be answered before $RUNTIME is known.
sel=$(checks_select 0 all Linux docker)
echo "$sel" | grep -q '^platform-supported$' || fail "phase 0 lost platform-supported"
echo "$sel" | grep -q '^buildx$'             && fail "phase 1 check leaked into phase 0"

# Bare (not nested): block-if-nested is advisory, so it is NOT in 'blocking'.
NESTED=false
sel=$(checks_select 1 blocking Linux docker)
echo "$sel" | grep -q '^buildx$'        || fail "blocking filter dropped buildx"
echo "$sel" | grep -q '^userns-sysctl$' && fail "block-if-nested must not block when bare"
echo "$sel" | grep -q '^engine-cli-match$' && fail "advisory must never be in blocking"

# Nested: block-if-nested is promoted.
NESTED=true
sel=$(checks_select 1 blocking Linux podman)
echo "$sel" | grep -q '^userns-sysctl$' || fail "block-if-nested not promoted under --dind"

echo "PASS: check registry indirections"
