#!/usr/bin/env bash
# Verifies detect_accel returns one of the three known accelerators.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "skip: qemu-system-x86_64 not installed"
    exit 0
fi

a=$(detect_accel)
case "$a" in
    kvm|hvf|tcg) ;;
    *) echo "unexpected accel: $a"; exit 1 ;;
esac

echo "ok"
