#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/allowlist.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' '# a comment' 'github.com' '*.npmjs.org' '' '  pypi.org ' > "$tmp/base"
printf '%s\n' 'github.com' 'extra.example.com' > "$tmp/project"

out="$(allowlist_merge "$tmp/base" "$tmp/project")"
expected=$'*.npmjs.org\nextra.example.com\ngithub.com\npypi.org'
assert_eq "$expected" "$out" "merge strips comments/space, dedups, sorts"

# Missing files are skipped, not fatal.
out2="$(allowlist_merge "$tmp/base" "$tmp/does-not-exist")"
assert_eq $'*.npmjs.org\ngithub.com\npypi.org' "$out2" "missing file skipped"

finish
