#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/secrets.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' '# secrets' 'GITHUB_TOKEN api.github.com' '' 'ANTHROPIC_API_KEY  api.anthropic.com' > "$tmp/s"

out="$(secrets_parse "$tmp/s")"
expected=$'GITHUB_TOKEN@api.github.com\nANTHROPIC_API_KEY@api.anthropic.com'
assert_eq "$expected" "$out" "parse ENV host -> ENV@host"

assert_eq "" "$(secrets_parse "$tmp/missing")" "missing file -> empty"

finish
