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

echo "PASS: check registry indirections"
