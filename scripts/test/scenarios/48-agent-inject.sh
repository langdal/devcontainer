#!/bin/bash
# scripts/test/scenarios/48-agent-inject.sh
# platform: linux
#
# `dev agent add|list|rm` copies a curated, per-agent allowlist of
# credentials + settings from the host into the per-workspace home volume
# (one-way snapshot; excludes cross-project history; secrets forced 0600).
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEV="${ROOT}/dev"

# ---------- arg surface (no runtime needed) ----------

# Unknown action errors non-zero and names the valid actions.
if out="$("$DEV" agent bogus 2>&1)"; then
    log_fail "dev agent bogus should exit non-zero"
else
    echo "$out" | grep -q "add|list|rm" \
        && log_pass "dev agent bogus errors with the valid action list" \
        || log_fail "dev agent bogus error text missing action list: $out"
fi

# Unknown agent name errors and lists valid agents.
if out="$("$DEV" agent add frobnicate --dry-run 2>&1)"; then
    log_fail "dev agent add frobnicate should exit non-zero"
else
    echo "$out" | grep -q "claude" \
        && log_pass "dev agent add <bad-name> lists valid agents" \
        || log_fail "dev agent add <bad-name> error missing agent list: $out"
fi
