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

# ---------- real copy into the home volume (needs runtime + base image) ----------

WORK="$(mktemp -d)/proj-agent48"
mkdir -p "$WORK"
VOL="devcontainer-home-proj-agent48"
remember_volume "$VOL"
remember_container "dev-proj-agent48"
"$RUNTIME" rm -f dev-proj-agent48 >/dev/null 2>&1 || true
"$RUNTIME" volume rm "$VOL" >/dev/null 2>&1 || true

# Add a symlink pointing outside the tree to exercise dereferencing.
mkdir -p "$FAKE_HOME/.claude/skills"
printf 'external\n' > "$FAKE_HOME/outside-skill.md"
ln -s "$FAKE_HOME/outside-skill.md" "$FAKE_HOME/.claude/skills/linked.md"

( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent add claude ) \
    || { log_fail "dev agent add claude (real) exited non-zero"; }

# Helper: test a path inside the volume as vscode.
vol_has() {
    "$RUNTIME" run --rm -u vscode -v "$VOL":/home/vscode \
        --entrypoint sh generic-devcontainer -c "test -e /home/vscode/$1"
}
vol_mode() {
    "$RUNTIME" run --rm -u vscode -v "$VOL":/home/vscode \
        --entrypoint sh generic-devcontainer -c "stat -c %a /home/vscode/$1"
}

vol_has ".claude/.credentials.json" \
    && log_pass "credentials.json landed in the volume" \
    || log_fail "credentials.json missing from volume"
vol_has ".claude/commands/x.md" \
    && log_pass "commands/x.md landed in the volume" \
    || log_fail "commands/x.md missing from volume"
[ "$(vol_mode .claude/.credentials.json)" = "600" ] \
    && log_pass "credentials.json is mode 600 in the volume" \
    || log_fail "credentials.json mode is $(vol_mode .claude/.credentials.json), want 600"

# Symlink was dereferenced to a real file with real content.
if "$RUNTIME" run --rm -u vscode -v "$VOL":/home/vscode --entrypoint sh \
      generic-devcontainer -c 'test -f /home/vscode/.claude/skills/linked.md && ! test -L /home/vscode/.claude/skills/linked.md'; then
    log_pass "symlinked skill was dereferenced to a real file"
else
    log_fail "symlinked skill not dereferenced (missing or still a symlink)"
fi

# Exclusions never made it in.
if vol_has ".claude.json" || vol_has ".claude/projects" || vol_has ".claude/history.jsonl"; then
    log_fail "an excluded path leaked into the volume"
else
    log_pass "excluded paths absent from the volume"
fi

# ---------- list ----------
listout="$( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent list 2>&1 )"
echo "$listout" | grep -E "claude.*yes.*yes" >/dev/null \
    && log_pass "list shows claude present on host and injected" \
    || log_fail "list output unexpected: $listout"

# ---------- rm ----------

# Unknown name must exit non-zero and remove nothing (regression: process-sub
# swallowed exit — dev agent rm claude bogus used to exit 0 and no-op).
if ( cd "$WORK" && HOME="$FAKE_HOME" DEV_ASSUME_YES=1 "$DEV" agent rm bogus ) >/dev/null 2>&1; then
    log_fail "dev agent rm bogus should exit non-zero"
else
    log_pass "dev agent rm bogus exits non-zero (no silent no-op)"
fi
# ...and claude is still injected (nothing was removed by the failed call)
vol_has ".claude/.credentials.json" \
    && log_pass "failed rm left claude files intact" \
    || log_fail "failed rm removed files it should not have"

( cd "$WORK" && HOME="$FAKE_HOME" DEV_ASSUME_YES=1 "$DEV" agent rm claude ) \
    || log_fail "dev agent rm claude exited non-zero"

if vol_has ".claude/.credentials.json"; then
    log_fail "rm did not remove .credentials.json"
else
    log_pass "rm removed claude's injected files"
fi
vol_has ".claude/commands/x.md" \
    && log_fail "rm did not remove commands/x.md" \
    || log_pass "rm removed commands/x.md (non-secret dest)"

listout2="$( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent list 2>&1 )"
if echo "$listout2" | grep -E "claude.*yes.*yes" >/dev/null; then
    log_fail "list still shows claude injected after rm: $listout2"
else
    log_pass "list shows claude no longer injected after rm"
fi
