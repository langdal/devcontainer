# `dev agent` Credential/Settings Injection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `dev agent {add,list,rm}` subcommand group that copies a curated, per-agent allowlist of credentials and settings from the host into this workspace's home volume (one-way snapshot, never a mount, never baked into an image).

**Architecture:** A new sourced module `lib/dev/agent.sh` holds the per-agent manifests and the add/list/rm handlers. The `dev` router gains an `agent` subcommand that resolves the runtime + workspace names (exactly like `reset`/`fw`) and dispatches to those handlers. Copies land in the per-workspace home volume via a short-lived helper container that runs `tar -x` **as `vscode` with the same `--userns=keep-id` args the real container uses**, so ownership is correct across Docker, rootful podman, and rootless podman without a separate `chown`.

**Tech Stack:** Bash (the `dev` script + `lib/dev/*.sh` modules), Docker/Podman CLI, `tar`, the project's own base image (`generic-devcontainer`) as the copy helper. Tests are end-to-end scenario scripts under `scripts/test/scenarios/` using `scripts/test/lib/` helpers (there is no unit-test framework and no linter/CI in this repo).

## Global Constraints

- **Shell strictness:** every module runs under `set -euo pipefail` (inherited from `dev`). Guard every `"${arr[@]}"` expansion of a possibly-empty array (`set -u` errors on empty-array expansion in bash 3.2). Capture exit codes of pipelines you don't want to abort the script (`if ! cmd; then` or `rc=0; cmd || rc=$?`).
- **No bash 4 features:** macOS ships bash 3.2. Do **not** use `mapfile`/`readarray` or associative arrays in new code; use `while IFS= read -r` loops into indexed arrays.
- **Module files are side-effect-free at source time:** `lib/dev/*.sh` define functions only. No top-level executable statements except plain assignments like `AGENT_KNOWN=(...)`.
- **Runtime word-splitting:** the established idiom is `$RUNTIME $RUNTIME_ARGS …` **unquoted** with a `# shellcheck disable=SC2086` comment on the line above. Follow it verbatim.
- **Secrets never enter an image layer.** Credentials live only in the per-workspace home *volume*.
- **Curated allowlist only.** Copy exactly the manifest paths below; never whole config dirs. Exclusions (history/session/cache/plugin-install machinery) are load-bearing for the per-workspace isolation guarantee.
- **Secret file modes forced to `0600`** after extraction: claude `.credentials.json`; opencode `auth.json`, `mcp-auth.json`, `opencode.json`; pi `auth.json`, `models.json`.
- **Symlinks dereferenced, broken ones skipped** (real installs symlink skill dirs outside `$HOME`); a broken link must warn, not abort.
- **Commit style:** Conventional Commits. This repo signs commits; in this sandbox signing has no key, so commit with `git -c commit.gpgsign=false commit …`. Never `git push`.
- **Reference spec:** `docs/superpowers/specs/2026-07-07-agent-creds-inject-design.md`.

## File Structure

- **Create `lib/dev/agent.sh`** — the whole feature's logic: `AGENT_KNOWN`, manifest data (`_agent_manifest`), source resolution (`_agent_src_abs`, `_agent_resolve`), name expansion (`_agent_is_known`, `_agent_expand`), keep-id probe (`_agent_keepid`), the three handlers (`_agent_add`, `_agent_list`, `_agent_rm`), the copy engine (`_agent_copy_into_volume`), a volume-path probe (`_agent_volume_has`), the marker/all-dest helpers, and `_agent_usage`.
- **Modify `dev`** — add `agent` to the subcommand-recognition `case`; add an `agent)` dispatch block; extend `usage()`.
- **Modify `README.md`** — new "Injecting agent credentials" section.
- **Modify `CLAUDE.md`** — add the commands to the Build and Run list and a Key Design Decisions bullet.
- **Create `scripts/test/scenarios/48-agent-inject.sh`** — end-to-end scenario.

Sourcing is automatic: `dev` sources every `lib/dev/*.sh`, so `agent.sh` is picked up with no wiring in the loop.

---

## Task 1: Module skeleton, name model, router wiring, and help

Deliverable: `dev agent`, `dev agent bogus`, and `dev agent add frobnicate` behave correctly (usage / errors) with no container interaction. This is testable on any host — it never touches a runtime because the error/usage paths return before dispatch.

**Files:**
- Create: `lib/dev/agent.sh`
- Modify: `dev` (subcommand-recognition `case` ~line 452; new `agent)` block in the `case "$subcmd"` dispatch ~line 500-620; `usage()` ~line 227-233 and the SUBCOMMANDS section)

**Interfaces:**
- Produces (consumed by later tasks): `AGENT_KNOWN` (array), `_agent_is_known <name> -> rc`, `_agent_usage`, and stub handlers `_agent_add`, `_agent_list`, `_agent_rm` (each taking the post-action argv). The router guarantees `detect_runtime`/`ensure_runtime_ready`/`_resolve_workspace_names` have run and `IMAGE_TAG="$IMAGE_NAME"` is set before any handler is called.

- [ ] **Step 1: Write the failing test**

Create `scripts/test/scenarios/48-agent-inject.sh` with just the arg-surface checks for now (later tasks append to it):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test/scenarios/48-agent-inject.sh`
Expected: FAIL lines — `dev agent bogus` currently falls through to the default start parser (treats `agent` as an unknown option or tries to start a container), so the checks don't pass.

- [ ] **Step 3: Create the module skeleton**

Create `lib/dev/agent.sh`:

```bash
# shellcheck shell=bash
# lib/dev/agent.sh — `dev agent {add,list,rm}` handlers. Copy a curated,
# per-agent allowlist of credentials + settings from the host into this
# workspace's home volume. One-way snapshot: never a host mount, never baked
# into an image. Sourced by dev; not executed directly.

# Known agent names, in display order. 'all' is a pseudo-name expanded by
# _agent_expand; it is intentionally NOT in this list.
AGENT_KNOWN=(claude opencode pi)

# _agent_is_known <name> -> 0 if name is a supported agent, else 1.
_agent_is_known() {
  local n
  for n in "${AGENT_KNOWN[@]}"; do
    [[ "$n" == "$1" ]] && return 0
  done
  return 1
}

_agent_usage() {
  cat <<'EOF'
Usage: dev agent add  <name>... | all    Copy an agent's creds+settings in
       dev agent list                    Show host / injected status
       dev agent rm   <name>... | all    Remove an agent's injected files

Agents: claude, opencode, pi

'add' is a one-way snapshot into this workspace's home volume (never a host
mount, never baked into an image). Re-run 'add' to refresh (tokens expire).
Preview with 'dev agent add <name> --dry-run'. Remove with 'dev agent rm'
or wipe the whole home volume with 'dev reset'.
EOF
}

# Stub handlers — implemented in later tasks. Each receives the argv that
# followed the action word (names and/or --dry-run).
_agent_add()  { echo "dev agent add: not yet implemented" >&2; exit 1; }
_agent_list() { echo "dev agent list: not yet implemented" >&2; exit 1; }
_agent_rm()   { echo "dev agent rm: not yet implemented" >&2; exit 1; }
```

- [ ] **Step 4: Wire the router in `dev`**

In `dev`, add `agent` to the subcommand-recognition `case` (the line currently reading `fw|reset|scaffold|update|install) subcmd="$1"; shift ;;`):

```bash
  fw|reset|scaffold|update|install|agent) subcmd="$1"; shift ;;
```

Then add an `agent)` block to the `case "$subcmd" in … esac` dispatch (place it after the `fw)` block, before the closing `esac`):

```bash
  agent)
    agent_action="${1:-}"
    case "$agent_action" in
      add|list|rm) shift ;;
      ''|-h|--help|help) _agent_usage; exit 0 ;;
      *)
        echo "Error: dev agent: expected an action (add|list|rm), got '${agent_action:-<none>}'" >&2
        echo "Run 'dev --help' for usage information" >&2
        exit 1
        ;;
    esac
    detect_runtime
    ensure_runtime_ready
    _resolve_workspace_names
    # shellcheck disable=SC2034  # IMAGE_TAG consumed by lib/dev/agent.sh helpers
    IMAGE_TAG="$IMAGE_NAME"
    case "$agent_action" in
      add)  _agent_add "$@" ;;
      list) _agent_list "$@" ;;
      rm)   _agent_rm "$@" ;;
    esac
    exit 0
    ;;
```

Note: `_agent_add` in Task 2 validates names *before* touching the runtime for the dry-run path, but the router still runs `detect_runtime` first (matches `reset`/`fw`). That is fine — `detect_runtime`/`ensure_runtime_ready` succeed on any host with a runtime installed, and the unknown-name error in Step 5's test is emitted by `_agent_expand` regardless.

- [ ] **Step 5: Extend `usage()`**

In `dev`'s `usage()` heredoc, add to the top usage lines (after the `dev fw …` line):

```bash
       dev agent {add|list|rm} [name...]
```

And add to the SUBCOMMANDS section (after the `fw drops` entry, before `reset`):

```
  agent add NAME  Copy a curated set of an agent's credentials + settings
                  (claude|opencode|pi, or 'all') from the host into this
                  workspace's home volume. One-way snapshot — never a host
                  mount, never baked into an image. Re-run to refresh.
                  --dry-run        Preview the file list without copying.
  agent list      Show, per agent, whether it is present on the host and
                  whether it has been injected into this workspace.
  agent rm NAME   Remove an agent's injected files from this workspace's
                  home volume (confirms; DEV_ASSUME_YES=1 skips the prompt).
```

- [ ] **Step 6: Run the test to verify the arg-surface checks pass**

Run: `bash scripts/test/scenarios/48-agent-inject.sh`
Expected: both `log_pass` lines print. (`dev agent add frobnicate` currently errors from the stub `_agent_add`, not from name validation — see the fix in Task 2. For now the stub exits non-zero and prints nothing containing "claude", so **this second check will still FAIL**. That is expected; it goes green in Task 2. Confirm only the first check (`dev agent bogus`) passes here.)

Adjust: to keep Task 1 self-contained and green, temporarily assert only the first check in this step by running:
Run: `"$ROOT/dev" agent bogus; echo "exit=$?"` and confirm it prints the action-list error and `exit=1`.

- [ ] **Step 7: Commit**

```bash
git add lib/dev/agent.sh dev scripts/test/scenarios/48-agent-inject.sh
git -c commit.gpgsign=false commit -m "feat(agent): add dev agent subcommand skeleton and router wiring"
```

---

## Task 2: Manifests, source resolution, name expansion, and `add --dry-run`

Deliverable: `dev agent add <name> --dry-run` prints exactly the curated files that exist on the host (with `mode 0600` on secrets) and never prints excluded paths; `dev agent add all --dry-run` covers detected agents; unknown names error. Fully testable with a fake `$HOME`, no containers.

**Files:**
- Modify: `lib/dev/agent.sh` (replace the `_agent_add` stub; add `_agent_manifest`, `_agent_src_abs`, `_agent_resolve`, `_agent_expand`)
- Modify: `scripts/test/scenarios/48-agent-inject.sh`

**Interfaces:**
- Consumes: `AGENT_KNOWN`, `_agent_is_known` (Task 1).
- Produces: `_agent_manifest <name>` → TSV lines `SRC_REL⇥DEST_REL⇥KIND⇥MODE`; `_agent_src_abs <name> <src_rel>` → absolute host path; `_agent_resolve <name>` → TSV lines `SRC_ABS⇥DEST_REL⇥KIND⇥MODE` for sources that exist; `_agent_expand <mode> <arg...>` (mode = `host`|`known`) → resolved names one per line. Task 3 consumes `_agent_resolve`; Task 3/4 consume `_agent_expand`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test/scenarios/48-agent-inject.sh` (before any container work):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test/scenarios/48-agent-inject.sh`
Expected: the four new checks FAIL (stub `_agent_add` still prints "not yet implemented").

- [ ] **Step 3: Add the manifest and resolution functions**

In `lib/dev/agent.sh`, add these functions (place them after `_agent_is_known`):

```bash
# _agent_manifest <name>: print one TSV line per manifest entry:
#   SRC_REL <TAB> DEST_REL <TAB> KIND <TAB> MODE
# SRC_REL is relative to the host $HOME; DEST_REL relative to /home/vscode.
# KIND is "file" or "dir"; MODE is "0600" for secrets, "-" otherwise.
# printf reuses the 4-field format for each group of 4 arguments.
_agent_manifest() {
  case "$1" in
    claude)
      printf '%s\t%s\t%s\t%s\n' \
        '.claude/.credentials.json' '.claude/.credentials.json' file 0600 \
        '.claude/settings.json'     '.claude/settings.json'     file -    \
        '.claude/CLAUDE.md'         '.claude/CLAUDE.md'         file -    \
        '.claude/commands'          '.claude/commands'          dir  -    \
        '.claude/agents'            '.claude/agents'            dir  -    \
        '.claude/skills'            '.claude/skills'            dir  -
      ;;
    opencode)
      printf '%s\t%s\t%s\t%s\n' \
        '.local/share/opencode/auth.json'     '.local/share/opencode/auth.json'     file 0600 \
        '.local/share/opencode/mcp-auth.json' '.local/share/opencode/mcp-auth.json' file 0600 \
        '.config/opencode/opencode.json'      '.config/opencode/opencode.json'      file 0600 \
        '.config/opencode/tui.json'           '.config/opencode/tui.json'           file -    \
        '.config/opencode/agents'             '.config/opencode/agents'             dir  -    \
        '.config/opencode/commands'           '.config/opencode/commands'           dir  -    \
        '.config/opencode/skills'             '.config/opencode/skills'             dir  -
      ;;
    pi)
      printf '%s\t%s\t%s\t%s\n' \
        '.pi/agent/auth.json'     '.pi/agent/auth.json'     file 0600 \
        '.pi/agent/settings.json' '.pi/agent/settings.json' file -    \
        '.pi/agent/models.json'   '.pi/agent/models.json'   file 0600 \
        '.pi/agent/skills'        '.pi/agent/skills'        dir  -    \
        '.pi/agent/extensions'    '.pi/agent/extensions'    dir  -
      ;;
  esac
}

# _agent_src_abs <name> <src_rel>: absolute host path for a manifest source.
# For pi, honor PI_CODING_AGENT_DIR (which relocates ~/.pi/agent) when set,
# keeping the DEST layout under the default .pi/agent/.
_agent_src_abs() {
  local name="$1" src_rel="$2"
  if [[ "$name" == pi && -n "${PI_CODING_AGENT_DIR:-}" && "$src_rel" == .pi/agent/* ]]; then
    printf '%s/%s\n' "${PI_CODING_AGENT_DIR%/}" "${src_rel#.pi/agent/}"
  else
    printf '%s/%s\n' "$HOME" "$src_rel"
  fi
}

# _agent_resolve <name>: print manifest lines whose source exists on the host,
# as TSV: SRC_ABS <TAB> DEST_REL <TAB> KIND <TAB> MODE. A top-level broken
# symlink fails the -e test and is skipped here; broken links *inside* a
# copied dir are handled at copy time.
_agent_resolve() {
  local name="$1" src_rel dest_rel kind mode src_abs
  while IFS=$'\t' read -r src_rel dest_rel kind mode; do
    [[ -n "$src_rel" ]] || continue
    src_abs="$(_agent_src_abs "$name" "$src_rel")"
    [[ -e "$src_abs" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$src_abs" "$dest_rel" "$kind" "$mode"
  done < <(_agent_manifest "$name")
}

# _agent_expand <mode> <arg...>: resolve name arguments to a deduped list,
# one per line. mode="host": 'all' -> known agents that have >=1 source on
# the host. mode="known": 'all' -> every known agent. Unknown names are fatal.
_agent_expand() {
  local mode="$1"; shift
  local a k
  local -a out=()
  for a in "$@"; do
    if [[ "$a" == all ]]; then
      for k in "${AGENT_KNOWN[@]}"; do
        if [[ "$mode" == known ]]; then
          out+=("$k")
        elif [[ -n "$(_agent_resolve "$k")" ]]; then
          out+=("$k")
        fi
      done
    elif _agent_is_known "$a"; then
      out+=("$a")
    else
      echo "Error: unknown agent '$a' (valid: ${AGENT_KNOWN[*]}, or 'all')" >&2
      exit 1
    fi
  done
  [[ ${#out[@]} -gt 0 ]] || return 0
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}
```

- [ ] **Step 4: Implement the `add --dry-run` path**

Replace the `_agent_add` stub in `lib/dev/agent.sh` with the parse + dry-run implementation (the real-copy branch calls `_agent_copy_into_volume`, added in Task 3):

```bash
# _agent_add [--dry-run] <name>... | all
_agent_add() {
  local dry=false
  local -a raw=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=true; shift ;;
      --) shift ;;
      -*) echo "Error: dev agent add: unknown option: $1" >&2; exit 1 ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  [[ ${#raw[@]} -gt 0 ]] || {
    echo "Error: dev agent add: name required (${AGENT_KNOWN[*]}, or 'all')" >&2
    exit 1
  }

  local -a targets=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && targets+=("$line")
  done < <(_agent_expand host "${raw[@]}")
  [[ ${#targets[@]} -gt 0 ]] || { echo "No matching agents found on host."; return 0; }

  local name src dest kind mode resolved
  for name in "${targets[@]}"; do
    if [[ "$dry" == true ]]; then
      resolved="$(_agent_resolve "$name")"
      if [[ -z "$resolved" ]]; then
        echo "  ${name}: no source files found on host."
        continue
      fi
      while IFS=$'\t' read -r src dest kind mode; do
        [[ -n "$src" ]] || continue
        if [[ "$mode" == 0600 ]]; then
          echo "  ${name}: would copy ${dest} (mode 0600)"
        else
          echo "  ${name}: would copy ${dest}"
        fi
      done <<< "$resolved"
    else
      _agent_copy_into_volume "$name"
    fi
  done

  if [[ "$dry" == false ]]; then
    echo "Done. Injected into ${HOME_VOLUME}. Re-run 'dev agent add' to refresh;"
    echo "'dev agent rm' or 'dev reset' to remove."
  fi
}
```

Now fix the Task 1 test's second check: with `_agent_expand` in place, `dev agent add frobnicate --dry-run` exits non-zero with an error containing `claude`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash scripts/test/scenarios/48-agent-inject.sh`
Expected: the `dev agent add frobnicate` check from Task 1 now PASSES, and all four Task 2 dry-run checks PASS. (Container-dependent checks are not added until Task 3.)

- [ ] **Step 6: Commit**

```bash
git add lib/dev/agent.sh scripts/test/scenarios/48-agent-inject.sh
git -c commit.gpgsign=false commit -m "feat(agent): add manifests, source resolution, and add --dry-run"
```

---

## Task 3: Copy engine — `add` writes into the home volume

Deliverable: `dev agent add claude` stages the resolved sources and extracts them into the workspace home volume through a keep-id helper container as `vscode`; curated files land with correct ownership, secrets are `0600`, excluded paths never appear, symlinks are dereferenced. Needs a runtime + the built base image (the test orchestrator provides both).

**Files:**
- Modify: `lib/dev/agent.sh` (add `_agent_keepid`, `_agent_copy_into_volume`)
- Modify: `scripts/test/scenarios/48-agent-inject.sh`

**Interfaces:**
- Consumes: `_agent_resolve` (Task 2); globals set by the router — `RUNTIME`, `RUNTIME_ARGS`, `HOME_VOLUME`, `IMAGE_TAG`, `HOST_UID`; and `runtime_is_rootless` + `migrate_volume_for_keepid` from `lib/dev/preflight.sh`/`lifecycle.sh`.
- Produces: `_agent_keepid` → prints `true`/`false`; `_agent_copy_into_volume <name>` → stages + extracts, echoing each copied dest.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test/scenarios/48-agent-inject.sh` (after the dry-run checks). This uses a real workspace dir so the home-volume name is deterministic:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sudo bash scripts/test/scenarios/48-agent-inject.sh` (needs runtime access; the base image must be built — run `sudo bash scripts/test/run-all.sh` once first if the image is absent, or `docker build -t generic-devcontainer .`)
Expected: the real-copy checks FAIL because `_agent_copy_into_volume` does not exist yet (`_agent_add` calls an undefined function → error).

- [ ] **Step 3: Implement the keep-id probe and copy engine**

In `lib/dev/agent.sh`, add (after `_agent_expand`):

```bash
# _agent_keepid: prints "true" when this runtime would create the workspace
# container with --userns=keep-id (rootless podman only), matching the logic
# in start_container. Otherwise "false".
_agent_keepid() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if $RUNTIME $RUNTIME_ARGS --version 2>/dev/null | grep -qi podman && runtime_is_rootless; then
    echo true
  else
    echo false
  fi
}

# _agent_copy_into_volume <name>: stage the resolved sources into a temp dir
# (dereferencing symlinks) and extract them into the workspace home volume
# through a short-lived helper container running as vscode with the same
# --userns=keep-id args the real container uses, so ownership is correct on
# Docker, rootful podman, and rootless podman alike.
_agent_copy_into_volume() {
  local name="$1" resolved
  resolved="$(_agent_resolve "$name")"
  if [[ -z "$resolved" ]]; then
    echo "  ${name}: no source files found on host — nothing to copy." >&2
    return 0
  fi

  local staging
  staging="$(mktemp -d)"
  local -a secret_dests=()
  local src dest kind mode
  while IFS=$'\t' read -r src dest kind mode; do
    [[ -n "$src" ]] || continue
    mkdir -p "$staging/$(dirname "$dest")"
    if [[ "$kind" == dir ]]; then
      mkdir -p "$staging/$dest"
      # -R recurse, -L dereference: links pointing outside the copied tree
      # become real files. Broken links make cp non-zero; warn, don't abort.
      if ! cp -RL "$src/." "$staging/$dest/" 2>/dev/null; then
        echo "  ${name}: warning: some entries under ${dest} were skipped (broken symlinks?)" >&2
      fi
    else
      if ! cp -L "$src" "$staging/$dest" 2>/dev/null; then
        echo "  ${name}: warning: skipped ${dest} (broken symlink?)" >&2
        continue
      fi
    fi
    echo "  ${name}: + ${dest}"
    [[ "$mode" == 0600 ]] && secret_dests+=("$dest")
  done <<< "$resolved"

  # Ensure the volume exists; under keep-id also make sure it is owned by the
  # host user before we write (reuses lifecycle.sh's one-time migration).
  local keepid
  keepid="$(_agent_keepid)"
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS volume create "$HOME_VOLUME" >/dev/null
  [[ "$keepid" == true ]] && migrate_volume_for_keepid "$HOME_VOLUME"

  # Remote command: extract, then tighten secret modes. Quote each dest.
  local remote='cd /home/vscode && tar -xf -'
  if [[ ${#secret_dests[@]} -gt 0 ]]; then
    remote+=' && chmod 600'
    local d
    for d in "${secret_dests[@]}"; do
      remote+=" $(printf '%q' "$d")"
    done
  fi

  local -a keepid_args=()
  [[ "$keepid" == true ]] && keepid_args=(--userns=keep-id)

  local rc=0
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  tar -C "$staging" -cf - . \
    | $RUNTIME $RUNTIME_ARGS run --rm -i \
        "${keepid_args[@]}" -u vscode \
        -v "$HOME_VOLUME":/home/vscode \
        --entrypoint sh "$IMAGE_TAG" -c "$remote" \
    || rc=$?
  rm -rf "$staging"
  return $rc
}
```

Note on `set -e`: `_agent_copy_into_volume` captures the pipeline result in `rc` (`|| rc=$?`) so a helper failure returns cleanly rather than aborting mid-loop; `_agent_add` does not check the return, matching the repo's best-effort style for per-item work — but the non-zero exit still surfaces via the printed helper stderr.

Guard for empty `keepid_args`: `"${keepid_args[@]}"` is safe under `set -u` in bash 3.2 **only** because it is always assigned (even if empty) before use. It is declared with `local -a keepid_args=()` above, so the expansion is defined. Do not remove that declaration.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sudo bash scripts/test/scenarios/48-agent-inject.sh`
Expected: all real-copy checks PASS — credentials/commands present, mode 600, symlink dereferenced, exclusions absent.

- [ ] **Step 5: Commit**

```bash
git add lib/dev/agent.sh scripts/test/scenarios/48-agent-inject.sh
git -c commit.gpgsign=false commit -m "feat(agent): copy curated files into the home volume via keep-id helper"
```

---

## Task 4: `list` and `rm`

Deliverable: `dev agent list` prints a per-agent table of host/injected status; `dev agent rm <name>` deletes an agent's injected files (confirms; `DEV_ASSUME_YES=1` skips). Needs a runtime.

**Files:**
- Modify: `lib/dev/agent.sh` (add `_agent_volume_exists`, `_agent_all_dests`, `_agent_volume_present_dests`, replace `_agent_list` and `_agent_rm` stubs)
- Modify: `scripts/test/scenarios/48-agent-inject.sh`

**Interfaces:**
- Consumes: `_agent_manifest`, `_agent_resolve`, `_agent_expand` (Task 2); `RUNTIME`, `RUNTIME_ARGS`, `HOME_VOLUME`, `IMAGE_TAG` (router); `_agent_keepid` (Task 3, for `rm`'s helper ownership parity — reads don't need it).
- Produces: `_agent_list`, `_agent_rm` final implementations.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test/scenarios/48-agent-inject.sh` (after the Task 3 copy, which leaves claude injected in `$VOL`):

```bash
# ---------- list ----------
listout="$( cd "$WORK" && HOME="$FAKE_HOME" "$DEV" agent list 2>&1 )"
echo "$listout" | grep -E "claude.*yes.*yes" >/dev/null \
    && log_pass "list shows claude present on host and injected" \
    || log_fail "list output unexpected: $listout"

# ---------- rm ----------
( cd "$WORK" && HOME="$FAKE_HOME" DEV_ASSUME_YES=1 "$DEV" agent rm claude ) \
    || log_fail "dev agent rm claude exited non-zero"

if vol_has ".claude/.credentials.json"; then
    log_fail "rm did not remove .credentials.json"
else
    log_pass "rm removed claude's injected files"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sudo bash scripts/test/scenarios/48-agent-inject.sh`
Expected: the `list` and `rm` checks FAIL (stubs print "not yet implemented" and exit non-zero).

- [ ] **Step 3: Implement volume probes and the two handlers**

In `lib/dev/agent.sh`, add (after `_agent_copy_into_volume`):

```bash
# _agent_volume_exists: 0 if the workspace home volume exists.
_agent_volume_exists() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS volume inspect "$HOME_VOLUME" >/dev/null 2>&1
}

# _agent_all_dests <name>: print every manifest DEST_REL for the agent
# (independent of whether the source exists on the host).
_agent_all_dests() {
  local src_rel dest_rel kind mode
  while IFS=$'\t' read -r src_rel dest_rel kind mode; do
    [[ -n "$dest_rel" ]] && printf '%s\n' "$dest_rel"
  done < <(_agent_manifest "$1")
}

# _agent_volume_present_dests: read candidate dest paths on stdin (one per
# line) and print those that exist in the home volume. One helper container
# for the whole set. Prints nothing if the volume does not exist.
_agent_volume_present_dests() {
  _agent_volume_exists || return 0
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS run --rm -i -u vscode \
    -v "$HOME_VOLUME":/home/vscode --entrypoint sh "$IMAGE_TAG" -c \
    'cd /home/vscode && while IFS= read -r p; do [ -e "$p" ] && printf "%s\n" "$p"; done'
}

# _agent_list: per-agent table of host-present? / injected-here?
_agent_list() {
  [[ $# -eq 0 ]] || { echo "Error: dev agent list takes no arguments: $*" >&2; exit 1; }

  # One helper call to learn which manifest dests currently exist in the volume.
  local present=""
  if _agent_volume_exists; then
    local a
    local all=""
    for a in "${AGENT_KNOWN[@]}"; do
      all+="$(_agent_all_dests "$a")"$'\n'
    done
    present="$(printf '%s' "$all" | _agent_volume_present_dests)"
  fi

  printf '%-10s  %-8s  %-11s\n' AGENT ON-HOST INJECTED-HERE
  local name host_yn inj_yn dest
  for name in "${AGENT_KNOWN[@]}"; do
    if [[ -n "$(_agent_resolve "$name")" ]]; then host_yn=yes; else host_yn=no; fi
    inj_yn=no
    while IFS= read -r dest; do
      [[ -n "$dest" ]] || continue
      if printf '%s\n' "$present" | grep -Fxq "$dest"; then inj_yn=yes; break; fi
    done < <(_agent_all_dests "$name")
    printf '%-10s  %-8s  %-11s\n' "$name" "$host_yn" "$inj_yn"
  done
}

# _agent_rm <name>... | all: delete an agent's injected files from the volume.
_agent_rm() {
  local -a raw=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift ;;
      -*) echo "Error: dev agent rm: unknown option: $1" >&2; exit 1 ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  [[ ${#raw[@]} -gt 0 ]] || {
    echo "Error: dev agent rm: name required (${AGENT_KNOWN[*]}, or 'all')" >&2
    exit 1
  }

  if ! _agent_volume_exists; then
    echo "No home volume (${HOME_VOLUME}) for this workspace — nothing to remove."
    return 0
  fi

  local -a targets=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && targets+=("$line")
  done < <(_agent_expand known "${raw[@]}")

  local name dest reply
  local -a dests
  for name in "${targets[@]}"; do
    dests=()
    while IFS= read -r dest; do
      [[ -n "$dest" ]] && dests+=("$dest")
    done < <(_agent_all_dests "$name")

    if [[ "${DEV_ASSUME_YES:-}" != "1" ]]; then
      echo "About to remove ${name} files from ${HOME_VOLUME}:"
      printf '  %s\n' "${dests[@]}"
      read -r -p "Remove them? [y/N] " reply
      case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Skipped ${name}."; continue ;;
      esac
    fi

    # Build the remote rm; quote each dest path.
    local remote='cd /home/vscode && rm -rf'
    for dest in "${dests[@]}"; do
      remote+=" $(printf '%q' "$dest")"
    done
    # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
    $RUNTIME $RUNTIME_ARGS run --rm -u vscode \
      -v "$HOME_VOLUME":/home/vscode --entrypoint sh "$IMAGE_TAG" -c "$remote"
    echo "Removed ${name} files from ${HOME_VOLUME}."
  done
}
```

Note: `rm`'s helper runs as `vscode` without `--userns=keep-id`. Deleting files the vscode-uid owns works under Docker/rootful podman (vscode uid == host uid) and under rootless podman without keep-id the volume files are owned by the invoking user which maps to container root — so also removable. Keep-id is only needed to *create* files with host-user ownership; `rm` of an owned tree does not require it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sudo bash scripts/test/scenarios/48-agent-inject.sh`
Expected: `list` shows `claude   yes   yes`, and after `rm` the credential file is gone. All prior checks still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/dev/agent.sh scripts/test/scenarios/48-agent-inject.sh
git -c commit.gpgsign=false commit -m "feat(agent): implement dev agent list and rm"
```

---

## Task 5: Documentation

Deliverable: README and CLAUDE.md document the feature. No code changes.

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:** none.

- [ ] **Step 1: Add the README section**

In `README.md`, add a new section (place it near the "Pushing from inside a container" / credentials discussion). Use this content:

```markdown
## Injecting agent credentials

`dev agent` copies a **curated** set of an AI coding agent's credentials and
settings from your host into this workspace's home volume, so the agent is
logged in and configured inside the sandbox without re-running its login flow.

```bash
dev agent add claude            # copy claude's creds+settings into this workspace
dev agent add claude opencode   # several at once
dev agent add all               # every agent detected on the host
dev agent add claude --dry-run  # preview the exact file list, copy nothing
dev agent list                  # per-agent: present on host? injected here?
dev agent rm claude             # remove claude's injected files (confirms)
```

Supported agents: `claude`, `opencode`, `pi`.

**It is a one-way snapshot, not a mount.** Files are *copied* into the
per-workspace home volume (`devcontainer-home-<dir>`). The host's live
credential files are never bind-mounted, nothing is baked into an image, and
changes inside the container are never mirrored back to the host. Credentials
rotate, so re-run `dev agent add <name>` to refresh the snapshot.

**What is copied (curated allowlist):** each agent's auth file(s), its
settings/config, and its user-level customizations (global instructions,
commands, agents, skills). **What is deliberately excluded:** conversation,
project, and session history; caches; and plugin-install machinery — so
injecting an agent does not drag one project's history into another's
sandbox. Files holding secrets (auth tokens, and any config with inline
provider API keys) are forced to mode `0600` in the volume.

**Teardown:** `dev agent rm <name>` removes just that agent's files;
`dev reset` prompts to remove the whole home volume.

**Local (127.0.0.1) providers:** if your agent config points at a
host-side server (e.g. a local LLM at `http://127.0.0.1:PORT`), that address
means the container itself inside the sandbox. Start with
`dev --host-port PORT` and edit the in-volume config to use
`host.docker.internal:PORT` instead.
```

- [ ] **Step 2: Update CLAUDE.md**

In `CLAUDE.md`, under "## Build and Run", add after the `./dev reset` block:

```markdown
# Inject a curated snapshot of an AI agent's host credentials + settings
# into this workspace's home volume (claude/opencode/pi). One-way copy,
# not a mount; re-run to refresh. `list` shows status; `rm` removes.
./dev agent add claude
./dev agent list
./dev agent rm claude
```

And add a bullet to "## Key Design Decisions":

```markdown
- **Opt-in agent credential injection** via `./dev agent add <name>`
  (`claude`/`opencode`/`pi`). Copies a curated allowlist of each agent's
  auth + settings + customizations from the host into the per-workspace home
  volume — a one-way snapshot, never a host mount and never baked into an
  image (secrets would leak into shared/cacheable layers). Excludes every
  tool's conversation/project/session history to preserve per-workspace home
  isolation. Secret files are forced to `0600`. Copy runs through a
  short-lived helper container executing `tar -x` as `vscode` under the same
  `--userns=keep-id` mapping as the real container, so ownership is correct
  across Docker, rootful podman, and rootless podman. Refresh by re-running
  `add`; remove with `dev agent rm` or `dev reset`. See README.md.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git -c commit.gpgsign=false commit -m "docs(agent): document dev agent credential injection"
```

---

## Self-Review

**Spec coverage:**
- Command surface (`add`/`list`/`rm`/`all`, `--dry-run`, `DEV_ASSUME_YES`) → Tasks 1, 2, 4. ✓
- claude/opencode/pi manifests incl. `models.json`, `mcp-auth.json`, secret modes → Task 2 (`_agent_manifest`), Task 3 (chmod). ✓
- `PI_CODING_AGENT_DIR` source override → Task 2 (`_agent_src_abs`). ✓
- Copy mechanism (staging, `tar -h`/deref via `cp -L`, keep-id helper as vscode, volume create, keep-id migration) → Task 3. ✓
- Symlink dereference + broken-link tolerance → Task 3 (`cp -RL`/`cp -L` with warn-not-abort) + test. ✓
- Exclusions never copied → enforced by allowlist manifest; asserted in Tasks 2 & 3 tests. ✓
- `list` host/injected columns, `rm` confirm + assume-yes → Task 4. ✓
- Runs whether or not a container is running; creates volume if missing → Task 3 (`volume create`; helper mounts the volume directly, independent of any running container). ✓
- Secret 0600 including `opencode.json`/`models.json` → Task 3 chmod list from MODE field. ✓
- Docs (README, CLAUDE.md, `dev --help`) → Task 5 + Task 1 Step 5. ✓
- Test scenario → built across Tasks 1–4. ✓
- Localhost-provider README note → Task 5. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows complete function bodies. ✓

**Type/name consistency:** `_agent_manifest`, `_agent_src_abs`, `_agent_resolve`, `_agent_expand`, `_agent_is_known`, `_agent_keepid`, `_agent_copy_into_volume`, `_agent_volume_exists`, `_agent_all_dests`, `_agent_volume_present_dests`, `_agent_add`, `_agent_list`, `_agent_rm`, `_agent_usage`, `AGENT_KNOWN` — used consistently across tasks. Router sets `IMAGE_TAG="$IMAGE_NAME"` and calls handlers with post-action argv, matching each handler's parser. TSV field order `SRC⇥DEST⇥KIND⇥MODE` is identical in `_agent_manifest`/`_agent_resolve`/consumers. ✓

**Note on TDD in this repo:** there is no unit-test framework; the automated test is the end-to-end scenario. Task 1–2 checks run without a runtime (arg surface + fake-`$HOME` dry-run); Task 3–4 checks need a runtime and the built base image (`sudo bash scripts/test/run-all.sh` builds it, or `docker build -t generic-devcontainer .`). The full matrix run picks up `48-agent-inject.sh` automatically.
