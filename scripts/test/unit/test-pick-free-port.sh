#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

# Returns a number in 10000..65000.
p=$(pick_free_port)
[[ "$p" =~ ^[0-9]+$ ]] || { echo "not numeric: $p"; exit 1; }
{ [ "$p" -ge 10000 ] && [ "$p" -le 65000 ]; } || { echo "out of range: $p"; exit 1; }

# Two consecutive calls should each return a free port (may be the same
# port if the prior one wasn't bound — that's fine).
p2=$(pick_free_port)
[[ "$p2" =~ ^[0-9]+$ ]] || exit 1

echo "ok"
