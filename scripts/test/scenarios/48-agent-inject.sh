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

# ---------- manifest / dry-run resolution (fake HOME, no runtime writes) ----------

FAKE_HOME="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() { rm -rf "$FAKE_HOME"; }
trap 'cleanup_extra; restore_host' EXIT

# Curated files that SHOULD be picked up.
mkdir -p "$FAKE_HOME/.claude/commands"
printf '{}\n'        > "$FAKE_HOME/.claude/.credentials.json"
printf '{}\n'        > "$FAKE_HOME/.claude/settings.json"
printf '# hi\n'      > "$FAKE_HOME/.claude/CLAUDE.md"
printf 'cmd\n'       > "$FAKE_HOME/.claude/commands/x.md"
# Excluded files that must NEVER appear.
printf 'x\n'         > "$FAKE_HOME/.claude.json"
mkdir -p "$FAKE_HOME/.claude/projects/secret-proj"
printf 'log\n'       > "$FAKE_HOME/.claude/history.jsonl"

dry="$(HOME="$FAKE_HOME" "$DEV" agent add claude --dry-run 2>&1)"

echo "$dry" | grep -q ".claude/.credentials.json" \
    && log_pass "dry-run includes .credentials.json" \
    || log_fail "dry-run missing .credentials.json: $dry"

echo "$dry" | grep -q "mode 0600" \
    && log_pass "dry-run marks the credential file 0600" \
    || log_fail "dry-run did not mark a 0600 secret: $dry"

echo "$dry" | grep -q ".claude/commands" \
    && log_pass "dry-run includes commands/ dir" \
    || log_fail "dry-run missing commands/: $dry"

if echo "$dry" | grep -Eq "\.claude\.json|projects|history\.jsonl"; then
    log_fail "dry-run leaked an excluded path: $dry"
else
    log_pass "dry-run excludes .claude.json / projects/ / history.jsonl"
fi
