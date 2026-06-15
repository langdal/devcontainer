#!/usr/bin/env bash
# Runs every tests/unit/*.sh and aggregates results.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$HERE"/unit/*.sh; do
  echo "== $(basename "$t")"
  if ! bash "$t"; then
    fail=1
  fi
done
if [[ $fail -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit $fail
