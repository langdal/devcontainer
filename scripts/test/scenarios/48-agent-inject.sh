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
    if echo "$out" | grep -q "add|list|rm"; then
        log_pass "dev agent bogus errors with the valid action list"
    else
        log_fail "dev agent bogus error text missing action list: $out"
    fi
fi

# Unknown agent name errors and lists valid agents.
if out="$("$DEV" agent add frobnicate --dry-run 2>&1)"; then
    log_fail "dev agent add frobnicate should exit non-zero"
else
    if echo "$out" | grep -q "claude"; then
        log_pass "dev agent add <bad-name> lists valid agents"
    else
        log_fail "dev agent add <bad-name> error missing agent list: $out"
    fi
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

if echo "$dry" | grep -q ".claude/.credentials.json"; then
    log_pass "dry-run includes .credentials.json"
else
    log_fail "dry-run missing .credentials.json: $dry"
fi

if echo "$dry" | grep -q "mode 0600"; then
    log_pass "dry-run marks the credential file 0600"
else
    log_fail "dry-run did not mark a 0600 secret: $dry"
fi

if echo "$dry" | grep -q ".claude/commands"; then
    log_pass "dry-run includes commands/ dir"
else
    log_fail "dry-run missing commands/: $dry"
fi

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

# Broken symlink inside a copied dir must be skipped (warn), not abort the copy.
ln -s /nonexistent/nope "$FAKE_HOME/.claude/commands/broken.md"

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

if vol_has ".claude/.credentials.json"; then
    log_pass "credentials.json landed in the volume"
else
    log_fail "credentials.json missing from volume"
fi
if vol_has ".claude/commands/x.md"; then
    log_pass "commands/x.md landed in the volume"
else
    log_fail "commands/x.md missing from volume"
fi
if [ "$(vol_mode .claude/.credentials.json)" = "600" ]; then
    log_pass "credentials.json is mode 600 in the volume"
else
    log_fail "credentials.json mode is $(vol_mode .claude/.credentials.json), want 600"
fi

# Broken symlink inside commands/ must not abort the dir copy: the sibling
# good file lands, and the broken link itself is skipped (not copied as a
# dangling symlink).
if vol_has ".claude/commands/x.md"; then
    log_pass "broken symlink did not abort commands/ dir copy (sibling x.md present)"
else
    log_fail "commands/x.md missing — broken symlink may have aborted the dir copy"
fi
if vol_has ".claude/commands/broken.md"; then
    log_fail "broken symlink was copied into the volume (should have been skipped)"
else
    log_pass "broken symlink was skipped, not copied into the volume"
fi

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
if echo "$listout" | grep -E "claude.*yes.*yes" >/dev/null; then
    log_pass "list shows claude present on host and injected"
else
    log_fail "list output unexpected: $listout"
fi

# ---------- rm ----------

# Unknown name must exit non-zero and remove nothing (regression: process-sub
# swallowed exit — dev agent rm claude bogus used to exit 0 and no-op).
if ( cd "$WORK" && HOME="$FAKE_HOME" DEV_ASSUME_YES=1 "$DEV" agent rm bogus ) >/dev/null 2>&1; then
    log_fail "dev agent rm bogus should exit non-zero"
else
    log_pass "dev agent rm bogus exits non-zero (no silent no-op)"
fi
# ...and claude is still injected (nothing was removed by the failed call)
if vol_has ".claude/.credentials.json"; then
    log_pass "failed rm left claude files intact"
else
    log_fail "failed rm removed files it should not have"
fi

( cd "$WORK" && HOME="$FAKE_HOME" DEV_ASSUME_YES=1 "$DEV" agent rm claude ) \
    || log_fail "dev agent rm claude exited non-zero"

if vol_has ".claude/.credentials.json"; then
    log_fail "rm did not remove .credentials.json"
else
    log_pass "rm removed claude's injected files"
fi
if vol_has ".claude/commands/x.md"; then
    log_fail "rm did not remove commands/x.md"
else
    log_pass "rm removed commands/x.md (non-secret dest)"
fi

listout2="$( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent list 2>&1 )"
if echo "$listout2" | grep -E "claude.*yes.*yes" >/dev/null; then
    log_fail "list still shows claude injected after rm: $listout2"
else
    log_pass "list shows claude no longer injected after rm"
fi
