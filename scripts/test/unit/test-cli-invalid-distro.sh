#!/usr/bin/env bash
# CLI smoke: invalid distro should produce a load_distro_conf error before
# any VM-related work.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Subshell so the launcher can `exit` without killing the test runner.
out=$(bash "$ROOT/scripts/test/run-in-vm.sh" nonexistent-distro 2>&1)
rc=$?
[ "$rc" -ne 0 ] || { echo "expected non-zero exit"; exit 1; }
echo "$out" | grep -q 'Conf not found' \
    || { echo "expected 'Conf not found' diagnostic, got: $out"; exit 1; }

echo "ok"
