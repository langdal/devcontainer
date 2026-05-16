#!/usr/bin/env bash
# Unit: arg parsing
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Source launcher in test mode (guard suppresses main).
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

# No args -> usage on stderr, exit non-zero.
if out=$(parse_args 2>&1); then
    echo "expected parse_args with no args to fail"; exit 1
fi
echo "$out" | grep -q 'Usage:' || { echo "expected Usage in error output"; exit 1; }

# 'fedora' alone -> DISTRO=fedora, CMD default unset.
parse_args fedora
[ "${DISTRO:-}" = "fedora" ] || { echo "DISTRO=$DISTRO"; exit 1; }
[ "${CMD:-}" = "" ] || { echo "CMD should be empty, got: $CMD"; exit 1; }
[ "${SHELL_MODE:-0}" = "0" ] || { echo "SHELL_MODE should be 0"; exit 1; }

# --cmd "..." -> CMD set.
parse_args fedora --cmd "echo hello"
[ "$CMD" = "echo hello" ] || { echo "CMD=$CMD"; exit 1; }

# --shell -> SHELL_MODE=1.
parse_args fedora --shell
[ "$SHELL_MODE" = "1" ] || { echo "SHELL_MODE=$SHELL_MODE"; exit 1; }

# Unknown flag -> fail.
if parse_args fedora --bogus 2>/dev/null; then
    echo "expected --bogus to fail"; exit 1
fi

echo "ok"
