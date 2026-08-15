#!/usr/bin/env bash
# Unit: the scenario privilege tag and its guard. Mirrors the platform tag
# that already exists — a scenario declares what it needs, the orchestrator
# decides what to run, and neither guesses.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# shellcheck source=scripts/test/lib/assert.sh
. "$ROOT/scripts/test/lib/assert.sh"

command -v scenario_privilege >/dev/null 2>&1 || fail "scenario_privilege not defined"
command -v require_privilege  >/dev/null 2>&1 || fail "require_privilege not defined"

# scenario_privilege reads the calling FILE's front-matter, so exercise it
# through real scenario files rather than by calling it here.
mk() { printf '#!/bin/bash\n# %s\n%s\nset -u\n. "%s/scripts/test/lib/assert.sh"\n%s\n' \
        "$1" "$2" "$ROOT" "$3" > "$WORK/$1"; }

# Single quotes below are intentional: these bodies are written into a
# generated script and must expand later, when that script runs, not now.
# shellcheck disable=SC2016
mk s-root.sh  '# privilege: root' 'echo "PRIV=$(scenario_privilege)"'
# shellcheck disable=SC2016
mk s-user.sh  '# privilege: user' 'echo "PRIV=$(scenario_privilege)"'
# shellcheck disable=SC2016
mk s-none.sh  ''                  'echo "PRIV=$(scenario_privilege)"'

[ "$(bash "$WORK/s-root.sh" | sed -n 's/^PRIV=//p')" = root ] || fail "root tag not read"
[ "$(bash "$WORK/s-user.sh" | sed -n 's/^PRIV=//p')" = user ] || fail "user tag not read"
[ "$(bash "$WORK/s-none.sh" | sed -n 's/^PRIV=//p')" = any ]  || fail "missing tag should default to any"

# require_privilege skips (exit 0 with a SKIP line) rather than failing when
# the run cannot satisfy the tag. A hard failure would make an unprivileged
# cell look broken instead of correctly narrower.
mk g-root.sh '# privilege: root' 'require_privilege root; echo RAN'
out=$(DEV_TEST_PRIVILEGE=user bash "$WORK/g-root.sh"); rc=$?
[ "$rc" -eq 0 ] || fail "require_privilege must exit 0 when skipping, got $rc"
echo "$out" | grep -q '^\[SKIP\]' || fail "expected a SKIP line, got: $out"
echo "$out" | grep -q 'RAN' && fail "scenario body ran despite an unmet privilege tag"

# ...and does nothing when the run CAN satisfy it.
out=$(DEV_TEST_PRIVILEGE=root bash "$WORK/g-root.sh")
echo "$out" | grep -q 'RAN' || fail "root scenario did not run in a root-capable run: $out"

# `any` runs everywhere; an unset DEV_TEST_PRIVILEGE means "run everything",
# so the existing sudo-based invocation keeps working untouched.
mk g-any.sh '# privilege: user' 'require_privilege user; echo RAN'
out=$(bash "$WORK/g-any.sh")
echo "$out" | grep -q 'RAN' || fail "unset DEV_TEST_PRIVILEGE must run everything: $out"

echo "PASS: scenario privilege tag and guard"
