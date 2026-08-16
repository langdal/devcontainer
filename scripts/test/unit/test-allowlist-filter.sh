#!/bin/bash
# scripts/test/unit/test-allowlist-filter.sh
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# allowlist_to_filter reads entries on stdin, writes ERE lines on stdout,
# and exits non-zero if any entry is malformed.
. "$ROOT/scripts/test/lib/allowlist-filter-harness.sh"  # sources the fn out of firewall-init.sh

fail() { echo "FAIL: $1"; exit 1; }

# Valid entries produce anchored, dot-escaped EREs.
out=$(printf 'github.com\n*.example.com\n' | allowlist_to_filter) || fail "valid entries rejected"
echo "$out" | grep -qx '\^github\\\.com\$' || fail "bare host not anchored/escaped: $out"
echo "$out" | grep -q 'example\\\.com\$'   || fail "wildcard not handled: $out"

# The C1 injection: a regex metacharacter must be REFUSED, not passed through.
if printf 'x|\n' | allowlist_to_filter >/dev/null 2>&1; then
    fail "entry 'x|' was accepted — regex injection still open"
fi
# A crafted allow-all must not slip through.
out=$(printf 'x|\ngithub.com\n' | allowlist_to_filter 2>/dev/null || true)
echo "evil.example.com" | grep -Eq "${out:-^\$NOMATCH\$}" && fail "allow-all leaked"

echo "ok"
