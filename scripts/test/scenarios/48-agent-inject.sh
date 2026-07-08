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

if echo "$dry" | grep -Eq "projects|history\.jsonl"; then
    log_fail "dry-run leaked an excluded host path: $dry"
else
    log_pass "dry-run excludes projects/ / history.jsonl"
fi

# The onboarding flag is synthesized (only hasCompletedOnboarding), never
# copied from the host's ~/.claude.json — the dry-run should announce it.
if echo "$dry" | grep -q "hasCompletedOnboarding"; then
    log_pass "dry-run announces the ~/.claude.json onboarding flag"
else
    log_fail "dry-run did not mention the onboarding flag: $dry"
fi

# ---------- macOS Keychain fallback for Claude credentials (mocked) ----------
# On macOS Claude Code stores its OAuth token in the login Keychain, not in
# ~/.claude/.credentials.json, so the manifest's file source is absent there.
# _agent_resolve must fall back to the Keychain and emit a sentinel that the
# copy path materializes. Exercise both on this Linux host by sourcing agent.sh
# with `uname`/`security` shimmed on PATH and a HOME lacking the creds file.
kc_shim="$(mktemp -d)"
cat > "$kc_shim/uname" <<'EOF'
#!/bin/sh
[ "$1" = "-s" ] && { echo Darwin; exit 0; }
exec /usr/bin/uname "$@"
EOF
cat > "$kc_shim/security" <<'EOF'
#!/bin/sh
# Mock only the `find-generic-password ... -w` read path used by agent.sh.
printf '%s\n' '{"claudeAiOauth":{"accessToken":"tok-from-keychain"}}'
EOF
chmod +x "$kc_shim/uname" "$kc_shim/security"
kc_home="$(mktemp -d)"
mkdir -p "$kc_home/.claude"          # note: no .credentials.json on disk
kc_stage="$(mktemp -d)"

# Resolve under the shims: credentials line should appear with the sentinel SRC.
kc_resolved="$(
  PATH="$kc_shim:$PATH" HOME="$kc_home" bash -c '
    set -u
    . "'"$ROOT"'/lib/dev/agent.sh"
    _agent_resolve claude
    printf "%s\n" "$AGENT_KEYCHAIN_CLAUDE_SRC"   # last line = the sentinel value
  '
)"
kc_sentinel="$(printf '%s\n' "$kc_resolved" | tail -n1)"
kc_creds_line="$(printf '%s\n' "$kc_resolved" | grep -F '.claude/.credentials.json' || true)"
if printf '%s' "$kc_creds_line" | grep -qF "$kc_sentinel"; then
    log_pass "keychain fallback: resolve emits credentials from Keychain sentinel when file absent"
else
    log_fail "keychain fallback: resolve did not emit the Keychain sentinel: $kc_resolved"
fi
if printf '%s' "$kc_creds_line" | grep -q '0600'; then
    log_pass "keychain fallback: credentials line marked 0600"
else
    log_fail "keychain fallback: credentials line not 0600: $kc_creds_line"
fi

# A real credentials file on disk must win over the Keychain (no sentinel).
printf '{}\n' > "$kc_home/.claude/.credentials.json"
kc_resolved_file="$(
  PATH="$kc_shim:$PATH" HOME="$kc_home" bash -c '
    set -u
    . "'"$ROOT"'/lib/dev/agent.sh"
    _agent_resolve claude
  '
)"
if printf '%s' "$kc_resolved_file" | grep -q 'keychain:'; then
    log_fail "keychain fallback: sentinel emitted even though the file exists: $kc_resolved_file"
else
    log_pass "keychain fallback: real credentials file wins over the Keychain"
fi
rm -f "$kc_home/.claude/.credentials.json"

# Materialize: the sentinel line is rewritten to a real staged file holding the
# Keychain payload; other lines pass through untouched.
kc_mat="$(
  PATH="$kc_shim:$PATH" bash -c '
    set -u
    . "'"$ROOT"'/lib/dev/agent.sh"
    printf "%s\t%s\t%s\t%s\n" "$AGENT_KEYCHAIN_CLAUDE_SRC" .claude/.credentials.json file 0600 \
      | _agent_materialize_keychain "'"$kc_stage"'"
  '
)"
kc_mat_src="$(printf '%s' "$kc_mat" | cut -f1)"
if [ -f "$kc_mat_src" ] && grep -q 'tok-from-keychain' "$kc_mat_src"; then
    log_pass "keychain fallback: materialize writes the Keychain payload to a real staged file"
else
    log_fail "keychain fallback: materialized src missing/empty ($kc_mat_src): $kc_mat"
fi
rm -rf "$kc_shim" "$kc_home" "$kc_stage"

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

# Host-side project/history state must still never leak into the volume.
if vol_has ".claude/projects" || vol_has ".claude/history.jsonl"; then
    log_fail "an excluded host path leaked into the volume"
else
    log_pass "excluded host paths absent from the volume"
fi

# ~/.claude.json is synthesized in the volume with ONLY the onboarding flag so
# Claude Code skips its login wizard in a fresh workspace. It must exist, be
# valid JSON with hasCompletedOnboarding=true, and must NOT carry the host
# file's content (the host had a bare "x" that must never be copied).
if vol_has ".claude.json"; then
    log_pass "onboarding file ~/.claude.json created in the volume"
else
    log_fail "onboarding file ~/.claude.json missing from the volume (login wizard would reappear)"
fi
onboard="$("$RUNTIME" run --rm -u vscode -v "$VOL":/home/vscode --entrypoint sh \
    generic-devcontainer -c 'cat /home/vscode/.claude.json 2>/dev/null')"
if echo "$onboard" | grep -q '"hasCompletedOnboarding": true'; then
    log_pass "onboarding file has hasCompletedOnboarding=true"
else
    log_fail "onboarding file missing hasCompletedOnboarding=true: $onboard"
fi
if echo "$onboard" | grep -qx "x"; then
    log_fail "host ~/.claude.json content leaked into the volume: $onboard"
else
    log_pass "synthesized ~/.claude.json does not carry host content"
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

# ---------- token auth method (--auth token) ----------
# Instead of snapshotting .credentials.json, inject a long-lived
# `claude setup-token` token that entrypoint.sh exports as
# CLAUDE_CODE_OAUTH_TOKEN (checked by Claude before the credentials file, so
# refresh-token rotation elsewhere can't log the container out).

TOKEN_DEST=".claude/.devcontainer-oauth-token"
FAKE_TOKEN="sk-ant-oat01-SCENARIO48TESTTOKEN"

# dry-run: token method previews the token dest and drops the creds snapshot.
dry_tok="$(HOME="$FAKE_HOME" "$DEV" agent add claude --auth token --dry-run 2>&1)"
if echo "$dry_tok" | grep -q "$TOKEN_DEST"; then
    log_pass "token dry-run previews $TOKEN_DEST"
else
    log_fail "token dry-run missing $TOKEN_DEST: $dry_tok"
fi
if echo "$dry_tok" | grep -q "would copy .claude/.credentials.json"; then
    log_fail "token dry-run still previews the credentials snapshot: $dry_tok"
else
    log_pass "token dry-run drops the credentials snapshot"
fi

# Arg surface: bad --auth value, --auth without claude, malformed token.
if HOME="$FAKE_HOME" "$DEV" agent add claude --auth bogus --dry-run >/dev/null 2>&1; then
    log_fail "--auth bogus should exit non-zero"
else
    log_pass "--auth bogus exits non-zero"
fi
if HOME="$FAKE_HOME" "$DEV" agent add opencode --auth token </dev/null >/dev/null 2>&1; then
    log_fail "--auth token without claude targeted should exit non-zero"
else
    log_pass "--auth token without claude targeted exits non-zero"
fi
if printf 'not-a-token\n' | ( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent add claude --auth token ) >/dev/null 2>&1; then
    log_fail "malformed token should exit non-zero"
else
    log_pass "malformed token is rejected non-zero"
fi

# Real inject: non-tty --auth token reads the token from stdin.
if printf '%s\n' "$FAKE_TOKEN" | ( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent add claude --auth token ); then
    log_pass "dev agent add claude --auth token (stdin) exited zero"
else
    log_fail "dev agent add claude --auth token (stdin) exited non-zero"
fi
if vol_has "$TOKEN_DEST"; then
    log_pass "token file landed in the volume"
else
    log_fail "token file missing from volume"
fi
if [ "$(vol_mode "$TOKEN_DEST")" = "600" ]; then
    log_pass "token file is mode 600 in the volume"
else
    log_fail "token file mode is $(vol_mode "$TOKEN_DEST"), want 600"
fi
if vol_has ".claude/.credentials.json"; then
    log_fail "token method still copied .credentials.json into the volume"
else
    log_pass "token method skipped the credentials snapshot"
fi

# entrypoint.sh must export the token as CLAUDE_CODE_OAUTH_TOKEN for every
# container process (needs the real entrypoint, hence NET_ADMIN for its
# firewall init).
env_tok="$("$RUNTIME" run --rm --cap-add=NET_ADMIN -v "$VOL":/home/vscode \
    generic-devcontainer sh -c 'printf %s "$CLAUDE_CODE_OAUTH_TOKEN"' 2>/dev/null | tail -n1)"
if [ "$env_tok" = "$FAKE_TOKEN" ]; then
    log_pass "entrypoint exports CLAUDE_CODE_OAUTH_TOKEN from the injected file"
else
    log_fail "CLAUDE_CODE_OAUTH_TOKEN not exported (got '$env_tok')"
fi

# list counts the token as injected; rm removes it again.
listout3="$( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent list 2>&1 )"
if echo "$listout3" | grep -E "claude.*yes.*yes" >/dev/null; then
    log_pass "list shows claude injected via token method"
else
    log_fail "list does not count the token as injected: $listout3"
fi
( cd "$WORK" && HOME="$FAKE_HOME" DEV_ASSUME_YES=1 "$DEV" agent rm claude ) \
    || log_fail "dev agent rm claude (token) exited non-zero"
if vol_has "$TOKEN_DEST"; then
    log_fail "rm did not remove the injected token file"
else
    log_pass "rm removed the injected token file"
fi
