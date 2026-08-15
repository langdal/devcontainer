#!/usr/bin/env bash
# Unit: ensure_runtime_ready gates only operations that touch the engine.
# On macOS with no running podman machine, `dev status`, `dev up --dry-run`
# and `dev doctor` must still work — they read state or print a command, and
# a machine that is down is exactly what the user needs told.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
RUNTIME=podman; RUNTIME_ARGS=""

command -v require_engine >/dev/null 2>&1 || fail "require_engine not defined"

# Darwin + machine down + engine NOT needed => proceed silently.
out=$(DEV_FAKE_OS=Darwin DEV_FAKE_MACHINE_RUNNING=false NEEDS_ENGINE=false \
        bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                 ensure_runtime_ready; echo PROCEEDED' 2>&1) \
  || fail "ensure_runtime_ready exited when the engine was not needed: $out"
[ "$out" = "PROCEEDED" ] || fail "expected silent proceed, got: $out"

# Darwin + machine down + engine needed => refuse with remediation.
if out=$(DEV_FAKE_OS=Darwin DEV_FAKE_MACHINE_RUNNING=false NEEDS_ENGINE=true \
           bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                    ensure_runtime_ready; echo PROCEEDED' 2>&1); then
    fail "ensure_runtime_ready proceeded with the engine needed and machine down"
fi
echo "$out" | grep -q 'podman machine start' \
    || fail "refusal lost its remediation: $out"

# Darwin + machine up + engine needed => proceed.
out=$(DEV_FAKE_OS=Darwin DEV_FAKE_MACHINE_RUNNING=true NEEDS_ENGINE=true \
        bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                 ensure_runtime_ready; echo PROCEEDED' 2>&1) \
  || fail "ensure_runtime_ready refused a running machine: $out"

# Linux never consults the machine at all.
out=$(DEV_FAKE_OS=Linux DEV_FAKE_MACHINE_RUNNING=false NEEDS_ENGINE=true \
        bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                 ensure_runtime_ready; echo PROCEEDED' 2>&1) \
  || fail "Linux consulted podman machine: $out"

echo "PASS: ensure_runtime_ready gates only engine-touching operations"
