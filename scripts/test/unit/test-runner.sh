#!/usr/bin/env bash
# scripts/test/unit/test-runner.sh — walks test-*.sh, prints summary.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0; FAILED=()
for t in "$DIR"/test-*.sh; do
    [ "$(basename "$t")" = "test-runner.sh" ] && continue
    name=$(basename "$t" .sh)
    if bash "$t" >/tmp/unit-out 2>&1; then
        echo "PASS $name"
        PASS=$((PASS+1))
    else
        echo "FAIL $name"
        sed 's/^/  /' /tmp/unit-out
        FAILED+=("$name")
        FAIL=$((FAIL+1))
    fi
done
echo
echo "Unit summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
