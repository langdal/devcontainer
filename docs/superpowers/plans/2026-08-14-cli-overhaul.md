# dev CLI Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace dev's flag-based CLI with compose-style verbs (clean break), delete scaffold and deprecated aliases, and restructure into a ≤150-line dispatcher plus focused lib modules with a reviewer-facing SECURITY.md.

**Architecture:** Four sequential PRs on branch `production-prep`. PR1 adds a verb router whose verbs translate into the existing start-path variables (shim approach — old spellings keep working). PR2 migrates every caller (scenario suite, unit test, docs) to verbs. PR3 deletes the legacy surface. PR4 extracts the monolithic bottom half of `dev` into per-verb modules and adds the security documentation.

**Tech Stack:** bash (macOS 3.2-compatible: no associative arrays, no `${var,,}`, guard empty arrays with `${arr[@]+"${arr[@]}"}`), shellcheck + hadolint via mise, e2e scenario suite under `scripts/test/`.

**Spec:** `docs/superpowers/specs/2026-08-14-cli-overhaul-design.md`

## Global Constraints

- Repo commit rules (CLAUDE.md): conventional commits; if GPG signing fails, use `git -c commit.gpgsign=false commit`; **NEVER `git push`**.
- Commit identity on this host: `git -c user.name="Jakob Langdal" -c user.email=jakob@langdal.dk`.
- Every commit body ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01462uCpiASfutUJxpbc8WCH`
- `shellcheck -x dev lib/dev/*.sh scripts/test/scenarios/50-cli-verbs.sh` must pass before every commit (shellcheck is in the repo-root mise.toml: run `mise x shellcheck -- shellcheck ...`).
- Runtime on this host is rootless podman 5.7 (`DEV_RUNTIME=podman`); the host `docker` CLI is broken (points at podman with API mismatch) — never use it.
- Scenario scripts are self-contained: `bash scripts/test/scenarios/NN-name.sh`; pass/fail is a `log_pass`/`log_fail` line. The heavyweight full matrix (`sudo bash scripts/test/run-all.sh`) is run ONLY at the end of PR4.
- Do not modify `Dockerfile`, `entrypoint.sh`, `firewall-init.sh`, `firewall-disable.sh`, `allowlist.*` except where a task explicitly says so (PR4 threat-model headers are comment-only).
- Do not touch `docs/superpowers/specs/*` or `docs/superpowers/plans/*` from before 2026-08-14 (historical records; stale references to scaffold in them are fine).
- The security-core reviewability rule: `dev fw` must only ever exec the in-container scripts; no firewall logic in the CLI.

## New surface (target after PR3) — reference for every task

```
dev up [--dind|--pind|--maint] [--open] [--build] [--dry-run]
       [--port P]... [--host-port P]... [--default-ports]
dev shell
dev exec [same flags as up] -- CMD [ARGS...]
dev down
dev status
dev fw off|on|log|drops
dev agent add|list|rm ...      (unchanged)
dev dotfile add|rm ...         (unchanged)
dev reset | dev update | dev install   (unchanged)
```

Semantics: `up` = create-or-start + attach interactive zsh, rejects `--`.
`exec` = create-or-start if needed, then run CMD (deliberate divergence from
docker exec). `shell` = attach only, error if nothing running. `--open` =
start with firewall torn down (replaces `fw disable` cold-start). `--maint`
replaces `--maintenance`. `fw off|on` replace `fw disable|enable` and act on
a RUNNING container only. Bare `dev` prints usage → exit 0; unknown
verb/flag → usage hint to stderr, exit 2.

---

## PR1 — verb router + shims (old spellings still work)

### Task 1: CLI surface contract test (new scenario 50)

**Files:**
- Create: `scripts/test/scenarios/50-cli-verbs.sh`

**Interfaces:**
- Produces: the executable contract every later task keeps green. PR3's task 8 EDITS this file (marked below).

- [ ] **Step 1: Write the scenario (it must FAIL now — the verbs don't exist yet)**

```bash
#!/bin/bash
# scripts/test/scenarios/50-cli-verbs.sh
# platform: linux
# CLI surface contract for the compose-style verb grammar. Container-free:
# every check uses --dry-run, usage output, or error paths only.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
require_platform linux

cd "$(dirname "$0")/../../.." || exit 1

fail=0
chk() { # description, expected-exit, grep-pattern, cmd...
    local desc="$1" want_rc="$2" pat="$3"; shift 3
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        log_fail "$desc: expected exit $want_rc, got $rc — output: $out"; fail=1; return
    fi
    if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
        log_fail "$desc: output missing '$pat' — got: $out"; fail=1
    fi
}

# Usage lists the verb surface.
chk "usage lists up"        0 'dev up'      ./dev --help
chk "usage lists exec"      0 'dev exec'    ./dev --help
chk "usage lists status"    0 'dev status'  ./dev --help
chk "usage lists fw off"    0 'off'         ./dev --help

# up: verb parses, --dry-run prints the run command without executing.
chk "up --dry-run works"    0 'Would\|docker\|podman' ./dev up --dry-run
# up rejects a command payload.
chk "up rejects --"         2 "use 'dev exec'" ./dev up --dry-run -- true
# exec requires --.
chk "exec without -- errors" 2 'requires' ./dev exec --dry-run
# exec --dry-run with a command parses through the verb path.
chk "exec --dry-run works"  0 'Would\|docker\|podman' ./dev exec --dry-run -- true
# --maint spelling accepted (translated to maintenance mode).
chk "up --maint accepted"   0 '' ./dev up --maint --dry-run
# Mode mutual exclusion still enforced through the verb path.
chk "up --dind --pind mutex" 1 'mutually exclusive' ./dev up --dind --pind --dry-run

# fw: new action names exist; action list names off/on.
chk "fw bad action lists off|on" 1 'off' ./dev fw bogus

# shell/status/down are container-free when nothing is running.
# (Scenario harness guarantees no dev-<ws> containers; be defensive anyway.)
WS=$(basename "$(pwd)")
"$RUNTIME" rm -f "dev-${WS}" "dev-${WS}-maint" "dev-${WS}-dind" "dev-${WS}-pind" 2>/dev/null
chk "shell errors when nothing running" 1 "dev up" ./dev shell
chk "status reports nothing running"    0 'Nothing running' ./dev status
chk "down reports nothing running"      0 'Nothing running' ./dev down

# Unknown verb is a hard error.
chk "unknown verb exits 2" 2 '' ./dev frobnicate

[ "$fail" -eq 0 ] || exit 1
log_pass "verb grammar surface: up/exec/shell/down/status/fw parse and error contracts hold"
exit 0
```

Note: `assert.sh` provides `log_pass`/`log_fail`/`expect_grep`/`require_platform`,
and the harness exports `RUNTIME`. If running the scenario standalone (outside
run-all) leaves `RUNTIME` unset, default it near the top:
`RUNTIME=${RUNTIME:-podman}`. Check `scripts/test/lib/assert.sh` for the
exact helper names before finalizing.

- [ ] **Step 2: Run it — must fail on the first `up` check**

Run: `bash scripts/test/scenarios/50-cli-verbs.sh`
Expected: `log_fail` lines (e.g. "up --dry-run works: expected exit 0, got 1" — today `dev up` is an unknown option error), overall exit 1.

- [ ] **Step 3: Commit the red test**

```bash
git add scripts/test/scenarios/50-cli-verbs.sh
git commit -m "test(cli): add verb-grammar surface contract (red)"
```

### Task 2: verb router + up/exec shims in `dev`

**Files:**
- Modify: `dev` — router case at lines ~472-487, subcommand case at ~567, defaults block at ~202-218, usage() at ~227-345.

**Interfaces:**
- Consumes: existing globals `MAINTENANCE/DIND/PIND/DRY_RUN/FW_DISABLED_START/CMD_ARGS` and the legacy start parser (lines ~758-836), which stays unchanged in PR1.
- Produces: verbs `up`/`exec` that translate to legacy-parser arguments; global `SHELL_ONLY=false` default (consumed by Task 3); router recognizes `up|shell|exec|down|status`.

- [ ] **Step 1: Add `SHELL_ONLY=false` to the defaults block** (next to `FORCE=false`, with a shellcheck disable=SC2034 comment noting it is consumed by start_container in lib/dev/lifecycle.sh).

- [ ] **Step 2: Extend the router's first-token case** — change the subcommand line to:

```bash
  up|shell|exec|down|status|fw|reset|scaffold|update|install|agent|dotfile|dotfiles) subcmd="$1"; shift ;;
```

- [ ] **Step 3: Add verb arms to the `case "$subcmd"` block** (insert BEFORE the `fw)` arm; these arms do NOT `exit` — they fall through to the legacy start parser below, exactly like the existing `fw disable` fallthrough):

```bash
  up)
    # Verb shim (PR1): translate to the legacy start parser's spellings and
    # fall through to it. The real extraction into lib/dev/up.sh is PR4.
    UP_ARGS=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --maint) UP_ARGS+=(--maintenance); shift ;;
        --open)
          # shellcheck disable=SC2034  # consumed by start_container (lib/dev/lifecycle.sh)
          FW_DISABLED_START=true; shift ;;
        --)
          echo "Error: 'dev up' does not take a command; use 'dev exec -- CMD'." >&2
          exit 2 ;;
        *) UP_ARGS+=("$1"); shift ;;
      esac
    done
    set -- ${UP_ARGS[@]+"${UP_ARGS[@]}"}
    ;;
  exec)
    EXEC_ARGS=(); _saw_ddash=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --maint) EXEC_ARGS+=(--maintenance); shift ;;
        --open)  FW_DISABLED_START=true; shift ;;
        --)      _saw_ddash=true; EXEC_ARGS+=("$@"); break ;;
        *)       EXEC_ARGS+=("$1"); shift ;;
      esac
    done
    if [[ "$_saw_ddash" != true ]]; then
      echo "Error: 'dev exec' requires '-- CMD [ARGS...]'." >&2
      exit 2
    fi
    unset _saw_ddash
    set -- ${EXEC_ARGS[@]+"${EXEC_ARGS[@]}"}
    ;;
```

- [ ] **Step 4: Add a verbs section at the top of usage()** — insert after the `Usage:` block, replacing its first line:

```
Usage: dev <verb> [options]

VERBS:
  up       Build image if needed, start the container, attach a shell.
           Options: --dind | --pind | --maint (mode), --open (firewall off),
           --build, --dry-run, --port P, --host-port P, --default-ports
  shell    Attach another shell to the running container.
  exec     Run one command inside (starts the container if needed):
           dev exec [up-options] -- CMD [ARGS...]
  down     Stop this workspace's container(s).
  status   Show what is running, its mode, and firewall state.
  fw       off|on|log|drops — firewall toggle and observability.
  agent    add|list|rm — inject AI-agent credentials (claude|opencode|pi).
  dotfile  add|rm — inject an arbitrary host dotfile/dir.
  reset    Remove containers and prompt per named volume.
  update   Update this git checkout to the latest released tag.
  install  Symlink dev onto PATH.
```

Keep the existing legacy option/subcommand text below it for now (PR3 deletes it).

- [ ] **Step 5: Run the scenario — up/exec checks now pass**

Run: `bash scripts/test/scenarios/50-cli-verbs.sh`
Expected: still exits 1 (shell/status/down/fw arms missing), but the up/exec/usage checks no longer log_fail.

- [ ] **Step 6: Shellcheck + regression, commit**

Run: `mise x shellcheck -- shellcheck -x dev lib/dev/*.sh scripts/test/scenarios/50-cli-verbs.sh`
Run: `bash scripts/test/unit/test-dev-subcommands.sh` (old aliases must still work in PR1)
Expected: both clean/pass.

```bash
git add dev
git commit -m "feat(cli): add up/exec verbs as shims over the start path"
```

### Task 3: `shell` verb

**Files:**
- Modify: `dev` (subcommand case), `lib/dev/lifecycle.sh` (attach block, lines ~252-291).

**Interfaces:**
- Consumes: `SHELL_ONLY` global from Task 2; `container_running`/`container_exists` helpers in lifecycle.sh.
- Produces: `dev shell` behavior; the lifecycle guard later tasks keep intact.

- [ ] **Step 1: Add the `shell` arm** (falls through to legacy parser with empty args):

```bash
  shell)
    if [[ $# -gt 0 ]]; then
      echo "Error: 'dev shell' takes no arguments." >&2
      exit 2
    fi
    SHELL_ONLY=true
    set --
    ;;
```

- [ ] **Step 2: Add the guard in lifecycle.sh** — inside `start_container`'s reuse block, immediately after the `if [[ "$DRY_RUN" == false ]]; then` line and before the `container_exists` check:

```bash
    # `dev shell` attaches only — it must never create a container.
    if [[ "${SHELL_ONLY:-false}" == true ]] && ! container_running "$CONTAINER_NAME"; then
      echo "Error: nothing running for this workspace — 'dev up' starts one." >&2
      exit 1
    fi
```

(Verify the helper is named `container_running` in lifecycle.sh; it is used at line ~272.)

- [ ] **Step 3: Run scenario 50** — the "shell errors when nothing running" check passes.

- [ ] **Step 4: Manual positive check** (needs the image; skip if slow, scenario coverage lands in PR2):

```bash
cd "$(mktemp -d)" && DEV_RUNTIME=podman DEV_ASSUME_YES=1 timeout 120 /home/jakob/code/devcontainer/dev exec -- sleep 90 &
sleep 60 && DEV_RUNTIME=podman /home/jakob/code/devcontainer/dev shell <<< 'echo SHELL_OK; exit'
```

Expected: `SHELL_OK`.

- [ ] **Step 5: Shellcheck, commit**

```bash
git add dev lib/dev/lifecycle.sh
git commit -m "feat(cli): add shell verb (attach-only, never creates)"
```

### Task 4: `down` and `status` verbs

**Files:**
- Modify: `dev` (subcommand case), `lib/dev/lifecycle.sh` (new functions at end of file).

**Interfaces:**
- Consumes: `_resolve_workspace_names`, `detect_runtime`, `ensure_runtime_ready` (defined in `dev`), `DIND_RUNTIME_ARGS`.
- Produces: `down_workspace()` and `status_workspace()` in lifecycle.sh (PR4 moves them to their own modules under the same names).

- [ ] **Step 1: Add functions to lib/dev/lifecycle.sh** (adapt the running-check to the file's existing helpers — `container_running` takes a name and uses `$RUNTIME` without extra args; for dind/pind names mirror how `refuse_if_running` passes `$DIND_RUNTIME_ARGS`):

```bash
# Stop this workspace's container(s), whatever mode is running. Containers
# run with --rm, so stopping also removes them. Volumes are untouched
# ('dev reset' handles those).
down_workspace() {
  local stopped=false name
  for name in "$NORMAL_NAME" "$MAINT_NAME"; do
    if container_running "$name"; then
      echo "Stopping $name..."
      $RUNTIME stop "$name" >/dev/null 2>&1 || true
      stopped=true
    fi
  done
  for name in "$DIND_NAME" "$PIND_NAME"; do
    # shellcheck disable=SC2086  # intentional word-splitting of DIND_RUNTIME_ARGS
    if [[ -n "$($RUNTIME $DIND_RUNTIME_ARGS ps -q --filter "name=^${name}\$" 2>/dev/null)" ]]; then
      echo "Stopping $name..."
      # shellcheck disable=SC2086
      $RUNTIME $DIND_RUNTIME_ARGS stop "$name" >/dev/null 2>&1 || true
      stopped=true
    fi
  done
  [[ "$stopped" == true ]] || echo "Nothing running for this workspace."
}

# One line per existing container: mode, name, engine status, firewall state.
# Firewall state is inferred from the banner file that firewall-disable.sh
# writes and firewall-init.sh removes — no firewall logic re-implemented here.
status_workspace() {
  local any=false
  _status_one() {
    local name="$1" mode="$2"; shift 2
    local st fw
    # shellcheck disable=SC2086  # optional DIND_RUNTIME_ARGS word-splitting
    st=$($RUNTIME "$@" ps --filter "name=^${name}\$" --format '{{.Status}}' 2>/dev/null | head -1)
    [[ -n "$st" ]] || return 0
    any=true
    fw="firewall on"
    if [[ "$mode" == maintenance ]]; then
      fw="no firewall (maintenance)"
    elif $RUNTIME "$@" exec "$name" test -f /etc/profile.d/zz-fw-disabled-banner.sh >/dev/null 2>&1; then
      fw="firewall OFF"
    fi
    printf '%-12s %-30s %s — %s\n' "$mode" "$name" "$st" "$fw"
  }
  _status_one "$NORMAL_NAME" normal
  _status_one "$MAINT_NAME" maintenance
  if [[ -n "$DIND_RUNTIME_ARGS" ]]; then
    _status_one "$DIND_NAME" dind "$DIND_RUNTIME_ARGS"
    _status_one "$PIND_NAME" pind "$DIND_RUNTIME_ARGS"
  else
    _status_one "$DIND_NAME" dind
    _status_one "$PIND_NAME" pind
  fi
  [[ "$any" == true ]] || echo "Nothing running for this workspace. 'dev up' starts one."
}
```

- [ ] **Step 2: Add verb arms in `dev`** (these DO exit — no fallthrough):

```bash
  down)
    if [[ $# -gt 0 ]]; then
      echo "Error: 'dev down' takes no arguments." >&2; exit 2
    fi
    detect_runtime; ensure_runtime_ready; _resolve_workspace_names
    down_workspace
    exit 0
    ;;
  status)
    if [[ $# -gt 0 ]]; then
      echo "Error: 'dev status' takes no arguments." >&2; exit 2
    fi
    detect_runtime; ensure_runtime_ready; _resolve_workspace_names
    status_workspace
    exit 0
    ;;
```

- [ ] **Step 3: Run scenario 50** — status/down checks pass. Manual positive check: start a container (`dev exec -- sleep 60 &`), then `dev status` shows `normal ... firewall on`, `dev down` stops it, second `dev status` prints the nothing-running line.

- [ ] **Step 4: Shellcheck, commit**

```bash
git add dev lib/dev/lifecycle.sh
git commit -m "feat(cli): add down and status verbs"
```

### Task 5: `fw off|on` actions

**Files:**
- Modify: `dev` (fw arm, lines ~611-668), `lib/dev/fw.sh`.

**Interfaces:**
- Consumes: `fw_disable`/`fw_enable`/`fw_log`/`fw_drops` in lib/dev/fw.sh.
- Produces: actions `off`/`on` (PR1 keeps `disable`/`enable` working unchanged, including disable's cold-start fallthrough; PR3 removes them). New fw.sh function `fw_off_running_only`.

- [ ] **Step 1: In `dev`'s fw arm**, extend the action case: `log|drops|enable|on)` share the strict no-extra-args branch (map `on` → `enable` after validation: `[[ "$fw_action" == on ]] && fw_action=enable`). Add a NEW strict branch for `off` (unlike `disable`, `off` takes no trailing args and never cold-starts):

```bash
      off)
        shift
        if [[ $# -gt 0 ]]; then
          echo "Error: dev fw off does not take extra arguments: $*" >&2
          echo "       To start a fresh container with the firewall open, use 'dev up --open'." >&2
          exit 1
        fi
        ;;
```

and dispatch: `off) fw_off_running_only ;;` in the second case. Update the action-error line to name the new set first: `expected an action (off|on|log|drops), got ...`.

- [ ] **Step 2: In lib/dev/fw.sh**, add `fw_off_running_only()` — same as `fw_disable` but erroring instead of falling through when nothing is running. Read `fw_disable` first (file is 58 lines); the new function reuses its running-container branch verbatim and replaces the fallthrough branch with:

```bash
  echo "Error: nothing running for this workspace." >&2
  echo "       'dev up --open' starts a fresh container with the firewall already open." >&2
  exit 1
```

- [ ] **Step 3: Run scenario 50** (`fw bad action lists off` passes) and the full scenario file end-to-end: `bash scripts/test/scenarios/50-cli-verbs.sh` → `log_pass`, exit 0.

- [ ] **Step 4: Regression: old spellings intact**

Run: `bash scripts/test/unit/test-dev-subcommands.sh` and `bash scripts/test/scenarios/26-allowlist-approval-gate.sh`
Expected: pass (26 needs the image built; it is — `generic-devcontainer:latest` exists on this host).

- [ ] **Step 5: Shellcheck, commit — PR1 complete**

```bash
git add dev lib/dev/fw.sh
git commit -m "feat(cli): add fw off/on actions (off is running-only; up --open replaces cold-start)"
```

---

## PR2 — migrate all callers to verbs

### Task 6: migrate the scenario suite

**Files:**
- Modify: every file in `scripts/test/scenarios/` that invokes `./dev` (all listed below), `scripts/test/run-all.sh`, `scripts/test/lib/privilege.sh`.

**Interfaces:**
- Consumes: PR1 verbs. Old spellings still work, so this is a pure text migration with the suite green before AND after.

- [ ] **Step 1: Apply the spelling map.** Mechanical rules (apply with sed or manually per file; `--maintenance` also appears in prose/comments — update those too):

| old | new |
|---|---|
| `./dev -- CMD...` | `./dev exec -- CMD...` |
| `./dev --build -- CMD` | `./dev exec --build -- CMD` |
| `./dev --dind -- CMD` | `./dev exec --dind -- CMD` |
| `./dev --pind -- CMD` | `./dev exec --pind -- CMD` |
| `./dev --maintenance -- CMD` | `./dev exec --maint -- CMD` |
| `./dev --dry-run ...` (no `--`) | `./dev up --dry-run ...` |
| `./dev --dry-run --dind -- CMD` | `./dev exec --dry-run --dind -- CMD` |
| `./dev` (bare, expecting start) | `./dev up` |
| `./dev fw disable` | `./dev fw off` |
| `./dev fw enable` | `./dev fw on` |
| `./dev fw disable -- CMD` (cold-start-open) | `./dev exec --open -- CMD` |
| mode-conflict flag probes (`./dev --dind -- true` etc. in scenario 20) | `./dev exec --dind -- true` etc.; `--maintenance` probe → `--maint` |
| `"$DEV" agent list` / other subcommands | unchanged |

Files to touch (from the inventory): scenarios 01-05, 10-16, 20-29, 30-34, 40-49, 90, 91 — every scenario EXCEPT 45 (scaffold; PR3 deletes it — leave it on old spellings) — plus `scripts/test/lib/privilege.sh` and `scripts/test/run-all.sh` if they invoke `./dev` (check with `grep -n './dev' scripts/test/run-all.sh scripts/test/lib/privilege.sh`).

- [ ] **Step 2: Grep-verify no stragglers**

Run: `grep -rn '\./dev \(--\|fw disable\|fw enable\)\|\./dev --' scripts/test/scenarios/ scripts/test/lib/ scripts/test/run-all.sh | grep -v '45-create-dev-container'`
Expected: no output (comments mentioning old flags in explanatory prose are OK if reworded or clearly historical; invocations must be zero).

- [ ] **Step 3: Run the cheap scenarios locally**

Run: `for s in 20 26 50; do bash scripts/test/scenarios/${s}-*.sh || echo "FAILED: $s"; done`
Expected: three `log_pass` lines. (20 and 26 start real containers — allow several minutes.)

- [ ] **Step 4: Commit**

```bash
git add scripts/test/
git commit -m "test: migrate scenario suite to verb spellings"
```

### Task 7: migrate unit test + docs invocations

**Files:**
- Rewrite: `scripts/test/unit/test-dev-subcommands.sh`
- Modify: `README.md`, `CLAUDE.md` (invocation examples only; structural rewrite is PR4).

- [ ] **Step 1: Rewrite the unit test** to cover the verb surface instead of deprecated aliases. Read the current file first for its harness conventions (it calls a `dev` function/binary directly and greps output). New assertions, using the same style:
  1. `dev update --dry-run` output unchanged (spelling already new).
  2. `dev fw log` with no running container → same error as before.
  3. `dev exec` without `--` → exit 2, message contains `requires`.
  4. `dev up -- true` → exit 2, message contains `dev exec`.
  5. `dev status` with nothing running → contains `Nothing running`.
  Drop every `--self-update` / `--monitor` / `--create-dev-container` deprecation-warning assertion (PR3 deletes the aliases; they are intentionally untested from here on).

- [ ] **Step 2: Run it**

Run: `bash scripts/test/unit/test-dev-subcommands.sh`
Expected: pass.

- [ ] **Step 3: Update README.md and CLAUDE.md invocation examples** to the new spellings using the Task 6 map (README "Build and Run"-equivalent sections, firewall-controls block `fw disable|enable` → `fw off|on` with the `--open` note; CLAUDE.md's command block likewise). Do NOT restructure prose yet. Do NOT touch the deprecated-flags documentation paragraphs — PR3 deletes them with the code.

- [ ] **Step 4: Commit — PR2 complete**

```bash
git add scripts/test/unit/test-dev-subcommands.sh README.md CLAUDE.md
git commit -m "docs+test: move unit test and doc examples to verb spellings"
```

---

## PR3 — the clean break (major release)

### Task 8: delete deprecated aliases and the legacy bare-start path

**Files:**
- Modify: `dev` (router case ~473-487, fw arm, usage()), `lib/dev/fw.sh`, `scripts/test/scenarios/50-cli-verbs.sh`.

- [ ] **Step 1: Extend scenario 50 FIRST (red)** — add these checks:

```bash
# Clean break: legacy spellings are gone.
chk "bare dev prints usage"        0 'VERBS' ./dev
chk "legacy --dind start rejected" 2 '' ./dev --dind -- true
chk "legacy -- start rejected"     2 '' ./dev -- true
chk "fw disable removed"           1 'off'  ./dev fw disable
chk "fw enable removed"            1 'on'   ./dev fw enable
chk "--disable-firewall removed"   2 ''     ./dev --disable-firewall
```

Run: `bash scripts/test/scenarios/50-cli-verbs.sh` → fails on all six.

- [ ] **Step 2: Router changes in `dev`:**
  - Delete the seven deprecated-alias case arms and the `_deprecated()` helper.
  - Bare invocation: change `subcmd=""` handling — after the case, add:

```bash
if [[ -z "$subcmd" ]]; then
  if [[ $# -eq 0 ]]; then
    usage; exit 0
  fi
  echo "Error: unknown verb or option: '$1'" >&2
  echo "Run 'dev --help' for usage information" >&2
  exit 2
fi
```

  - This makes the legacy start parser reachable ONLY via the up/exec/shell fallthrough arms. The parser itself stays (it is now the shared flag engine for up/exec; PR4 renames it).
  - In the fw arm: remove the `disable` lenient branch and its `--maintenance` rejection loop entirely; remove `enable` from the strict branch (keep `on`); add explicit rejections so users get pointed at the new names:

```bash
      disable) echo "Error: 'fw disable' was renamed: use 'dev fw off' (running container) or 'dev up --open' (fresh)." >&2; exit 1 ;;
      enable)  echo "Error: 'fw enable' was renamed: use 'dev fw on'." >&2; exit 1 ;;
```

  - Delete the `fw_disable` fallthrough dispatch (`disable) fw_disable ;;` line and the comment block about it).
- [ ] **Step 3: lib/dev/fw.sh** — delete `fw_disable`'s no-container fallthrough branch (fold what remains into `fw_off_running_only`, delete `fw_disable`, and keep `fw_enable` as the implementation `on` dispatches to). `FW_DISABLED_START` is now set ONLY by `up --open`/`exec --open`; update its comment block in `dev` (lines ~213-218).

- [ ] **Step 4: usage()** — delete the legacy `START OPTIONS`/`SUBCOMMANDS`/`DEPRECATED FLAGS` sections; the VERBS section from Task 2 plus a short OPTIONS-per-verb block is the whole help text now. Keep `--help`/`--version` handling.

- [ ] **Step 5: Green + regression**

Run: `bash scripts/test/scenarios/50-cli-verbs.sh && bash scripts/test/unit/test-dev-subcommands.sh && bash scripts/test/scenarios/20-mode-conflict-pairs.sh`
Expected: all pass.

- [ ] **Step 6: Commit (breaking)**

```bash
git add dev lib/dev/fw.sh scripts/test/scenarios/50-cli-verbs.sh
git commit -m "feat(cli)!: remove deprecated flag aliases and legacy start spellings

BREAKING CHANGE: 'dev' (bare) now prints usage; start with 'dev up',
run commands with 'dev exec -- CMD'. 'fw disable/enable' are 'fw off/on';
cold-start-with-firewall-open is 'dev up --open'. The old --flag aliases
(--disable-firewall, --enable-firewall, --monitor, --monitor-fw, --reset,
--self-update, --create-dev-container) are removed."
```

### Task 9: delete scaffold

**Files:**
- Delete: `lib/dev/scaffold.sh`, `scripts/test/scenarios/45-create-dev-container.sh`
- Modify: `dev` (router token list, scaffold arm, usage remnants), `README.md`, `CLAUDE.md` (scaffold sections), `scripts/test/unit/test-dev-subcommands.sh` (scaffold assertions, if any survived Task 7).

- [ ] **Step 1: Delete files and references**

```bash
git rm lib/dev/scaffold.sh scripts/test/scenarios/45-create-dev-container.sh
```

In `dev`: remove `scaffold` from the router token list, delete the `scaffold)` arm, remove `FORCE=false` + the `--force` parser arm and its usage text (only scaffold consumed them), and remove `DEFAULT_PORTS`? — NO: `--default-ports` is a start option, keep it. Remove the `create_dev_container` module-load expectations if `dev` references it by name anywhere (grep).

In README.md/CLAUDE.md: delete the scaffold command from command blocks and the "Scaffold a self-contained .devcontainer/" prose/sections.

- [ ] **Step 2: Verify nothing dangles**

Run: `grep -rn 'scaffold\|create_dev_container' dev lib/ scripts/ README.md CLAUDE.md examples/ 2>/dev/null`
Expected: no output (historical docs/ and CHANGELOG.md hits are fine and excluded from this grep).

Run: `mise x shellcheck -- shellcheck -x dev lib/dev/*.sh && bash scripts/test/scenarios/50-cli-verbs.sh`
Expected: clean, pass.

- [ ] **Step 3: Commit — PR3 complete**

```bash
git add -A
git commit -m "feat(cli)!: remove scaffold subcommand

BREAKING CHANGE: 'dev scaffold' and the generated .devcontainer/ flow are
removed; use 'dev up' / editor-agnostic attach instead."
```

---

## PR4 — final layout, security docs, full matrix

### Task 10: extract runtime + verb modules from `dev`

**Files:**
- Create: `lib/dev/runtime.sh`, `lib/dev/up.sh`, `lib/dev/status.sh`
- Modify: `dev`, `lib/dev/lifecycle.sh`

Mechanical extraction — no behavior change; scenario 50 + unit test are the regression net, run after each move:

- [ ] **Step 1:** Move `detect_runtime`, `ensure_runtime_ready`, `runtime_is_rootless`, and related runtime-probe helpers from `dev` into new `lib/dev/runtime.sh` (they are defined in `dev`'s top half — locate with `grep -n '^detect_runtime\|^ensure_runtime_ready\|^runtime_is_rootless' dev`). The lib/dev/*.sh loader glob at `dev` line ~46 picks the new file up automatically. Run scenario 50; commit `refactor(cli): extract runtime detection to lib/dev/runtime.sh`.
- [ ] **Step 2:** Move the whole legacy start block (`dev` lines from the `# --- Default "start" command` comment to the final `start_container` call) into `lib/dev/up.sh` as `cmd_start "$@"` (one function wrapping the parser + preflights + name resolution + build check + `start_container`). The up/exec/shell router arms end with `cmd_start ${ARGS...}` instead of falling through. Move `_resolve_workspace_names`, `_resolve_home_volume`, `resolve_agent_storage` into `lib/dev/up.sh` only if they are not consumed by other subcommands (they ARE — reset/fw/agent use them; leave them in `dev` for Task 11 to place in container.sh). Run scenario 50 + 20; commit `refactor(cli): extract start flow to lib/dev/up.sh`.
- [ ] **Step 3:** Move `down_workspace` + `status_workspace` from lifecycle.sh into `lib/dev/status.sh`. Run scenario 50; commit `refactor(cli): move down/status into lib/dev/status.sh`.

- [ ] **Step 4: Budget check**

Run: `wc -l dev lib/dev/*.sh`
Expected: `dev` ≤ ~150 lines (router + usage + module loader + version helpers). If usage() text keeps it over, move usage() into `lib/dev/usage.sh` — acceptable and preferred over trimming help text.

### Task 11: split lifecycle.sh and agent.sh

**Files:**
- Create: `lib/dev/container.sh`, `lib/dev/volumes.sh`, `lib/dev/inject.sh`
- Modify: `lib/dev/lifecycle.sh` (shrinks; delete when empty), `lib/dev/agent.sh`, `dev`

- [ ] **Step 1:** `container.sh` takes: container name resolution (`_resolve_workspace_names` from `dev`), `container_exists`/`container_running`/`container_label`, `refuse_if_running` + the four-way guard block (move from up.sh's cmd_start into a `resolve_container_name_and_guard` function), and the create-or-start/attach logic of `start_container`. `volumes.sh` takes `_resolve_home_volume` (from `dev`), volume mounts assembly, and `migrate_volume_for_keepid`. What remains of lifecycle.sh after the moves: if under ~50 lines, fold it into container.sh and `git rm` lifecycle.sh.
- [ ] **Step 2:** `inject.sh` takes the helper-container tar-copy machinery from agent.sh (the functions shared by dotfile.sh — identify with `grep -n '_agent\|helper' lib/dev/agent.sh lib/dev/dotfile.sh` and move exactly the functions dotfile.sh also calls, plus their private helpers). agent.sh keeps resolution/UI (`_agent_add/list/rm`, allowlist tables, keychain fallback).
- [ ] **Step 3:** After each move: `mise x shellcheck -- shellcheck -x dev lib/dev/*.sh` + scenario 50 + `bash scripts/test/scenarios/48-agent-inject.sh`. Budget: every module ≤ ~250 lines (`wc -l lib/dev/*.sh`); if agent.sh still exceeds, note it in the commit body rather than force a worse split.
- [ ] **Step 4: Commit** `refactor(cli): split lifecycle into container/volumes modules, extract shared inject helpers`

### Task 12: SECURITY.md + threat-model headers

**Files:**
- Create: `SECURITY.md`
- Modify (comment-only): `Dockerfile`, `entrypoint.sh`, `firewall-init.sh`, `firewall-disable.sh`, `allowlist.base`, `allowlist.dind`

- [ ] **Step 1: Write SECURITY.md** with exactly these sections:
  1. **Threat model** — verbatim framing: the sandbox protects against an agent *finding and using the host's keys and secrets by accident, or — in misguided loyalty — searching for solutions outside the sandbox*. Containment of agent reach; NOT exfiltration-prevention (allowlisted hosts are reachable and bidirectional by design).
  2. **What enforces the boundary** — table: file → mechanism → what to verify when reviewing (Dockerfile: no sudo for vscode, dc-tinyproxy copy, proxy user; entrypoint.sh: fail-closed firewall start, seed-never-overwrite; firewall-init.sh: default-DROP v4+v6, owner rule, never reads /workspace; firewall-disable.sh: explicit opt-out surface; allowlists: the egress universe).
  3. **Reading order for a first review** — Dockerfile → entrypoint.sh → firewall-init.sh → allowlist.base/dind → lib/dev/container.sh mount/exec surface (what the CLI mounts and injects).
  4. **Deliberate non-goals** — exfiltration via allowlisted hosts; malicious base image; kernel exploits from inside; the maintenance-mode escape hatch (documented, opt-in, loudly bannered).
  5. **Known sharp edges** — host AppArmor interactions, IPv6 posture (mirrored since the fix-pack), `DEV_ASSUME_YES=1` waiving the project-allowlist review.
- [ ] **Step 2: Add threat-model headers** — 3-6 comment lines at the top of each of the six files stating what the file may and may not do (e.g. firewall-init.sh: "May: program iptables/ip6tables, write tinyproxy config/filter from BAKED and APPROVED allowlists. Must never: read allowlist material from /workspace, weaken rules based on env vars an in-container process can set."). Comment-only — `git diff` per file must show zero non-comment changes.
- [ ] **Step 3:** `mise x shellcheck -- shellcheck -x entrypoint.sh firewall-init.sh firewall-disable.sh` + `mise x hadolint -- hadolint Dockerfile` → clean. Rebuild sanity: `podman build --network=host -t generic-devcontainer /home/jakob/code/devcontainer >/dev/null && echo BUILD_OK`.
- [ ] **Step 4: Commit** `docs(security): add reviewer guide and threat-model headers to the enforcement core`

### Task 13: docs restructure + full matrix

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `scripts/lint.sh`

- [ ] **Step 1: README/CLAUDE.md restructure** — rewrite the command-reference sections around the verb grammar (VERBS table mirroring usage()); update the "12 checks"→13 references if any remain; link SECURITY.md prominently in README's firewall section; delete any remaining scaffold/deprecated-flag prose.
- [ ] **Step 2: Line-budget gate** — append to `scripts/lint.sh`:

```bash
echo "=== line budgets ==="
over=0
[ "$(wc -l < dev)" -le 170 ] || { echo "dev exceeds 170 lines"; over=1; }
for f in lib/dev/*.sh; do
    [ "$(wc -l < "$f")" -le 300 ] || { echo "$f exceeds 300 lines"; over=1; }
done
[ "$over" -eq 0 ] || exit 1
```

(Budgets are the spec's soft targets plus slack; tune the numbers to the actual post-refactor counts if a file is legitimately over — the gate exists to catch future creep, not to force artificial splits. `wc -l < file` keeps output filename-free.)

- [ ] **Step 3: Full matrix**

Run: `sudo bash scripts/test/run-all.sh` (needs passwordless sudo; logs at scripts/test/last-summary.log)
Expected: pass/skip only. Scenario 45 no longer exists; scenario 50 present. Investigate ANY fail before committing; macOS scenarios (90/91) skip on Linux.

- [ ] **Step 4: Commit — PR4 complete**

```bash
git add -A
git commit -m "docs+refactor(cli): restructure docs around verb grammar, add line-budget lint"
```

## Self-review notes (already applied)

- Spec coverage: surface (Tasks 2-5, 8), prune (Task 9), layout (Tasks 10-11), SECURITY.md (Task 12), migration+testing (Tasks 1, 6-7, 13), `install` kept (router token list, Task 2). `exec` auto-start = legacy create-or-start path, exercised by migrated scenarios (Task 6).
- Types/names consistent: `SHELL_ONLY`, `FW_DISABLED_START`, `cmd_start`, `down_workspace`/`status_workspace`, `fw_off_running_only` used identically across tasks.
- Known judgment calls for implementers: exact helper names inside lifecycle.sh/agent.sh must be confirmed by reading the file before moving code (the plan names the anchors and line ranges; the files are the source of truth).
