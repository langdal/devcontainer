#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/msb.sh"

export BOX_DRY_RUN=1
out="$(msb_provision mcr.microsoft.com/devcontainers/base:ubuntu /tmp/proj)"
assert_contains "$out" "msb run" "provision runs a sandbox"
assert_contains "$out" "--mount-named box-mise:/mise" "provision mounts mise volume"
assert_contains "$out" "--mount-dir /tmp/proj:/workspace" "provision mounts workspace"
assert_contains "$out" "--net-default-egress allow" "provision has open egress"
assert_contains "$out" "mise install" "provision installs mise tools"

finish
