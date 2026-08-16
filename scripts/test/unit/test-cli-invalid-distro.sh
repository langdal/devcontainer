#!/usr/bin/env bash
# CLI smoke: invalid distro should produce a load_distro_conf error before
# any VM-related work.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# run-in-vm.sh checks for its host tooling BEFORE it looks up the distro
# conf, so on a machine without qemu it reports the missing tools and never
# reaches the code path this test exists to check. That is not a failure of
# the code under test — it is an unmet precondition, so skip rather than go
# red. A permanently-red test teaches people to ignore the suite, and this
# one has been red on every Linux host without qemu since it was written.
# Skip only on a missing-binary check, never on an assertion result.
for _tool in qemu-system-x86_64 qemu-img; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "SKIP: $_tool not installed; run-in-vm.sh cannot reach the conf lookup"
        exit 0
    fi
done
unset _tool

# Subshell so the launcher can `exit` without killing the test runner.
out=$(bash "$ROOT/scripts/test/run-in-vm.sh" nonexistent-distro 2>&1)
rc=$?
[ "$rc" -ne 0 ] || { echo "expected non-zero exit"; exit 1; }
echo "$out" | grep -q 'Conf not found' \
    || { echo "expected 'Conf not found' diagnostic, got: $out"; exit 1; }

echo "ok"
