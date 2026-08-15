# Host Preflight Registry + `dev doctor` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A colleague on an unfamiliar machine runs `dev doctor` and gets one screen naming every host problem and its fix — backed by a check registry that `dev up` shares, so the two can never disagree.

**Architecture:** Sixteen checks become entries in an ordered indexed array plus a probe function each. `dev doctor` runs every applicable check and reports; `dev up` runs the blocking subset of the same entries. `lib/dev/preflight.sh` collapses into the registry. Probes reach the outside world only through overridable indirections, so macOS checks are unit-testable from Linux.

**Tech Stack:** bash (macOS 3.2-compatible: no associative arrays, no `${var,,}`, guard empty arrays with `${arr[@]+"${arr[@]}"}`), shellcheck + hadolint + actionlint via mise, scenario suite under `scripts/test/`.

**Spec:** `docs/superpowers/specs/2026-08-15-host-preflight-matrix-design.md`

This is **increment 1 of 2**. Increment 2 (matrix expansion: privilege tagging, rootless cell, macOS cell, scenario 51, `run-all.sh` gate fix) is a separate plan and depends on this one landing.

## Global Constraints

- **Branch:** execute on `production-prep`. No worktree, no merge to `main` — the repo owner is holding the branch until org-deploy readiness and all testing happens here. Same ruling as the CLI overhaul.
- **bash 3.2 compatible.** No associative arrays, no `${var,,}`, no `readarray`. Guard empty-array expansion as `${arr[@]+"${arr[@]}"}`.
- **Line budgets enforced by `scripts/lint.sh`:** `dev` ≤ 190 lines, `lib/dev/*.sh` ≤ 300 (except `agent.sh` ≤ 550). The gate is real — it caught `up.sh` at 330 during the CLI overhaul. If `checks.sh` exceeds 300, split the probe/fix function pairs into `lib/dev/checks-catalog.sh` and leave the registry array plus runner in `checks.sh`; do not raise the budget.
- **Commits:** unsigned (`git -c commit.gpgsign=false`) — the sandbox has no signing key and the owner re-signs later. Set identity per-commit with `-c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk'`; this host has no configured git identity. **Never `git push`.**
- **Probes never call the outside world directly.** No bare `uname`, `command -v`, `$RUNTIME --version`, or `cat /proc/...` inside a `_chk_*` function. Everything goes through an indirection a test can override. This is a review gate: a probe that shells out directly is untestable and silently drops the macOS coverage this whole design depends on.
- **A probe has three outcomes, never two:** 0 pass, 1 fail, 2 not-applicable. "Could not determine" renders as not-applicable or unknown — never as pass. This is the fail-open defect fixed in `dev status` on 2026-08-15; do not reintroduce it.
- **No `--fix` flag, ever.** Every remediation mutates host security posture. Print the command; let the human run it.

## File Structure

| File | Responsibility |
|---|---|
| `lib/dev/checks.sh` (new) | `CHECKS` registry array, applicability filter, the runner, and the 16 `_chk_*`/`_chk_*_fix` pairs |
| `lib/dev/doctor.sh` (new) | `cmd_doctor` — argument parsing, report rendering, exit codes |
| `lib/dev/runtime.sh` (modify) | add `_have_cmd`, `_runtime_version`, `_read_sysfs` indirections beside the existing `_host_os`; narrow `ensure_runtime_ready` |
| `lib/dev/up.sh` (modify) | replace the two hard-coded preflight calls with the registry runner |
| `lib/dev/preflight.sh` (delete) | contents migrate into `checks.sh` |
| `dev` (modify) | `doctor)` router arm |
| `lib/dev/usage.sh` (modify) | `doctor` entry in the VERBS block |
| `scripts/test/unit/test-checks-registry.sh` (new) | applicability filter + runner semantics, fully stubbed |
| `scripts/test/unit/test-checks-catalog.sh` (new) | each of the 16 probes against stubbed conditions |
| `scripts/test/unit/test-doctor-report.sh` (new) | rendering, exit codes, `--dind` severity promotion |

**Registry entry format** — five fields, not the spec's four:

```
id|phase|applies-to|severity|title
```

The spec's example omitted `phase`; the runner needs it, because "is there a runtime at all" must be answered before `$RUNTIME` exists. Everything else matches the spec.

---

### Task 1: Probe indirections

**Files:**
- Modify: `lib/dev/runtime.sh` (add beside the existing `_host_os`, which was added 2026-08-15)
- Test: `scripts/test/unit/test-checks-registry.sh` (create; grows through Tasks 1–3)

**Interfaces:**
- Produces: `_host_os()` (exists), `_have_cmd <name>` → 0/1, `_runtime_version()` → prints `$RUNTIME --version` output or empty, `_read_sysfs <path>` → prints file contents or empty. All honour a `DEV_FAKE_*` override so tests can drive them.

- [ ] **Step 1: Write the failing test**

Create `scripts/test/unit/test-checks-registry.sh`:

```bash
#!/usr/bin/env bash
# Unit: the check registry's indirections, applicability filter and runner.
# Nothing here contacts a real runtime, filesystem or platform: every probe
# goes through an indirection this file overrides. That is what lets the
# macOS checks be exercised from Linux and vice versa.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
RUNTIME=""; RUNTIME_ARGS=""

# --- indirections ---------------------------------------------------------
command -v _have_cmd      >/dev/null 2>&1 || fail "_have_cmd not defined"
command -v _runtime_version >/dev/null 2>&1 || fail "_runtime_version not defined"
command -v _read_sysfs    >/dev/null 2>&1 || fail "_read_sysfs not defined"

# _host_os honours DEV_FAKE_OS (added 2026-08-15).
[ "$(DEV_FAKE_OS=Darwin _host_os)" = "Darwin" ] || fail "_host_os ignored DEV_FAKE_OS"

# _have_cmd finds a real builtin-backed binary and rejects a nonsense one.
_have_cmd sh          || fail "_have_cmd could not find sh"
_have_cmd zzz-no-such && fail "_have_cmd found a nonexistent command"

# DEV_FAKE_CMDS is a space-separated allowlist; when set it REPLACES the real
# lookup entirely, so a test host's actual binaries cannot leak into a case.
DEV_FAKE_CMDS="docker podman" _have_cmd docker || fail "DEV_FAKE_CMDS did not grant docker"
DEV_FAKE_CMDS="podman" _have_cmd docker        && fail "DEV_FAKE_CMDS leaked a real docker"
DEV_FAKE_CMDS="podman" _have_cmd sh            && fail "DEV_FAKE_CMDS leaked a real sh"

# _runtime_version is overridable without a runtime present.
[ "$(DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' _runtime_version)" = "podman version 5.7.0" ] \
    || fail "_runtime_version ignored DEV_FAKE_RUNTIME_VERSION"

# _read_sysfs reads a real file, returns empty for a missing one, and is
# overridable by path so /proc entries can be faked on macOS.
tmp=$(mktemp); echo 1 > "$tmp"
[ "$(_read_sysfs "$tmp")" = "1" ] || fail "_read_sysfs could not read a real file"
[ -z "$(_read_sysfs /no/such/path/at/all)" ] || fail "_read_sysfs invented content"
[ "$(DEV_FAKE_SYSFS_VALUE=0 _read_sysfs "$tmp")" = "0" ] || fail "_read_sysfs ignored override"
rm -f "$tmp"

echo "PASS: check registry indirections"
```

- [ ] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-checks-registry.sh`
Expected: `FAIL: _have_cmd not defined`

- [ ] **Step 3: Implement the indirections**

In `lib/dev/runtime.sh`, immediately after the existing `_host_os` function:

```bash
# Is a command available? DEV_FAKE_CMDS (space-separated) REPLACES the real
# lookup when set, so a unit test's host binaries cannot leak into a case.
_have_cmd() {
  if [[ -n "${DEV_FAKE_CMDS:-}" ]]; then
    case " $DEV_FAKE_CMDS " in
      *" $1 "*) return 0 ;;
      *)        return 1 ;;
    esac
  fi
  command -v "$1" >/dev/null 2>&1
}

# The selected runtime's --version banner, or empty when it cannot answer.
_runtime_version() {
  if [[ -n "${DEV_FAKE_RUNTIME_VERSION:-}" ]]; then
    echo "$DEV_FAKE_RUNTIME_VERSION"
    return 0
  fi
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME ${RUNTIME_ARGS:-} --version 2>/dev/null || true
}

# Contents of a sysfs/procfs entry, or empty when unreadable. Overridable so
# Linux-only /proc checks can be exercised from macOS.
_read_sysfs() {
  if [[ -n "${DEV_FAKE_SYSFS_VALUE:-}" ]]; then
    echo "$DEV_FAKE_SYSFS_VALUE"
    return 0
  fi
  [[ -r "$1" ]] || return 0
  cat "$1" 2>/dev/null || true
}
```

- [ ] **Step 4: Run it — must pass**

Run: `bash scripts/test/unit/test-checks-registry.sh`
Expected: `PASS: check registry indirections`

- [ ] **Step 5: Regression + commit**

```bash
mise x shellcheck -- shellcheck -x dev lib/dev/*.sh
bash scripts/test/unit/test-engine-identity.sh
bash scripts/lint.sh
git add lib/dev/runtime.sh scripts/test/unit/test-checks-registry.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "feat(cli): add overridable host probes for the check registry"
```

---

### Task 2: Narrow `ensure_runtime_ready`

**Files:**
- Modify: `lib/dev/runtime.sh` (`ensure_runtime_ready`)
- Modify: `lib/dev/up.sh` (call site), `lib/dev/status.sh` (call sites, lines 10 and 20)
- Test: `scripts/test/unit/test-runtime-ready.sh` (create)

**Interfaces:**
- Consumes: `_host_os` from Task 1's file.
- Produces: `ensure_runtime_ready()` unchanged in name, now a no-op unless the caller has set `NEEDS_ENGINE=true`. `require_engine()` — new, prints the podman-machine error and exits 1.

**Why:** confirmed twice on real macOS hardware (2026-08-15 probe runs). `dev status`, `dev up --dry-run` and four unit tests all die with "podman machine is not running" because `ensure_runtime_ready` gates unconditionally. `--dry-run` prints a command without executing it, and `dev doctor` must work on a machine where nothing is set up — otherwise the doctor cannot diagnose the very condition it exists to report.

- [ ] **Step 1: Write the failing test**

Create `scripts/test/unit/test-runtime-ready.sh`:

```bash
#!/usr/bin/env bash
# Unit: ensure_runtime_ready gates only operations that touch the engine.
# On macOS with no running podman machine, `dev status`, `dev up --dry-run`
# and `dev doctor` must still work — they read state or print a command, and
# a machine that is down is exactly what the user needs told.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
RUNTIME=podman; RUNTIME_ARGS=""

command -v require_engine >/dev/null 2>&1 || fail "require_engine not defined"

# Darwin + machine down + engine NOT needed => proceed silently.
out=$(DEV_FAKE_OS=Darwin DEV_FAKE_MACHINE_RUNNING=false NEEDS_ENGINE=false \
        bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                 ensure_runtime_ready; echo PROCEEDED' 2>&1) \
  || fail "ensure_runtime_ready exited when the engine was not needed: $out"
[ "$out" = "PROCEEDED" ] || fail "expected silent proceed, got: $out"

# Darwin + machine down + engine needed => refuse with remediation.
if out=$(DEV_FAKE_OS=Darwin DEV_FAKE_MACHINE_RUNNING=false NEEDS_ENGINE=true \
           bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                    ensure_runtime_ready; echo PROCEEDED' 2>&1); then
    fail "ensure_runtime_ready proceeded with the engine needed and machine down"
fi
echo "$out" | grep -q 'podman machine start' \
    || fail "refusal lost its remediation: $out"

# Darwin + machine up + engine needed => proceed.
out=$(DEV_FAKE_OS=Darwin DEV_FAKE_MACHINE_RUNNING=true NEEDS_ENGINE=true \
        bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                 ensure_runtime_ready; echo PROCEEDED' 2>&1) \
  || fail "ensure_runtime_ready refused a running machine: $out"

# Linux never consults the machine at all.
out=$(DEV_FAKE_OS=Linux DEV_FAKE_MACHINE_RUNNING=false NEEDS_ENGINE=true \
        bash -c '. "'"$ROOT"'/lib/dev/runtime.sh"; RUNTIME=podman; RUNTIME_ARGS=""
                 ensure_runtime_ready; echo PROCEEDED' 2>&1) \
  || fail "Linux consulted podman machine: $out"

echo "PASS: ensure_runtime_ready gates only engine-touching operations"
```

- [ ] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-runtime-ready.sh`
Expected: `FAIL: require_engine not defined`

- [ ] **Step 3: Rewrite `ensure_runtime_ready` in `lib/dev/runtime.sh`**

Replace the whole existing function with:

```bash
# Is the macOS podman machine running? Overridable for tests.
_machine_running() {
  if [[ -n "${DEV_FAKE_MACHINE_RUNNING:-}" ]]; then
    [[ "$DEV_FAKE_MACHINE_RUNNING" == true ]]
    return
  fi
  podman machine list --format '{{.Running}}' 2>/dev/null | grep -q '^true$'
}

# Refuse: this operation genuinely needs a live engine.
require_engine() {
  echo "Error: podman machine is not running." >&2
  echo "       Start it with:  podman machine start" >&2
  exit 1
}

# On macOS with podman the VM must be running — but ONLY for operations that
# actually talk to the engine. `dev status` reads what is running, `dev up
# --dry-run` prints a command without executing it, and `dev doctor` exists to
# diagnose a host where nothing is set up: gating those on a live VM makes
# them useless exactly when they are needed. Callers opt in with
# NEEDS_ENGINE=true. (Confirmed on GitHub macOS runners 2026-08-15: four unit
# tests and two verbs failed here for no good reason.)
ensure_runtime_ready() {
  [[ "${NEEDS_ENGINE:-false}" == true ]] || return 0
  [[ "$(_host_os)" == "Darwin" && "$RUNTIME" == "podman" ]] || return 0
  _machine_running || require_engine
}
```

- [ ] **Step 4: Set `NEEDS_ENGINE` at the call sites**

In `lib/dev/up.sh`, in `cmd_start`, on the line immediately before its
`ensure_runtime_ready` call:

```bash
  # The start path creates or attaches a container: it needs a live engine.
  # --dry-run only prints the command, so it does not.
  NEEDS_ENGINE=true
  [[ "$DRY_RUN" == true ]] && NEEDS_ENGINE=false
```

In `lib/dev/status.sh`, both `detect_runtime; ensure_runtime_ready; ...` lines
(currently lines 10 and 20) become:

```bash
  detect_runtime; NEEDS_ENGINE=false; ensure_runtime_ready; _resolve_workspace_names
```

`lib/dev/shell.sh` and `lib/dev/inject.sh` both attach to or write into a real
container, so leave their calls alone — they inherit the `false` default and
must set it true:

```bash
  # shell.sh, immediately before its ensure_runtime_ready call:
  NEEDS_ENGINE=true
  # inject.sh, in resolve_agent_storage, same position:
  NEEDS_ENGINE=true
```

Declare the default in `dev` beside the other start-flow globals (near line 83):

```bash
# Whether the current operation talks to the engine. Read by
# ensure_runtime_ready (lib/dev/runtime.sh); verbs that only read state or
# print a command leave it false.
# shellcheck disable=SC2034  # consumed by ensure_runtime_ready
NEEDS_ENGINE=false
```

- [ ] **Step 5: Run the tests**

Run:
```bash
bash scripts/test/unit/test-runtime-ready.sh
bash scripts/test/unit/test-dev-subcommands.sh
bash scripts/test/scenarios/50-cli-verbs.sh
```
Expected: first prints `PASS: ensure_runtime_ready gates only engine-touching operations`; second exits 0; third prints `[PASS] 50-cli-verbs`.

- [ ] **Step 6: Commit**

```bash
mise x shellcheck -- shellcheck -x dev lib/dev/*.sh && bash scripts/lint.sh
git add -A
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "fix(cli): gate the podman-machine check on operations that need an engine"
```

---

### Task 3: Registry array, applicability filter and runner

**Files:**
- Create: `lib/dev/checks.sh`
- Test: `scripts/test/unit/test-checks-registry.sh` (extend Task 1's file)

**Interfaces:**
- Consumes: `_host_os`, `_have_cmd` (Task 1).
- Produces:
  - `CHECKS` — indexed array of `id|phase|applies-to|severity|title`
  - `check_applies <applies-to> <os> <runtime>` → 0 applicable, 1 not
  - `check_field <entry> <n>` → prints field n (1-indexed)
  - `run_check <id>` → sets `CHECK_STATE` to `pass|fail|na`, returns 0 always
  - `checks_select <phase> <severity-filter> <os> <runtime>` → prints matching ids, one per line. `severity-filter` is `blocking` (block + block-if-nested-when-nested) or `all`.

- [ ] **Step 1: Write the failing test — append to `scripts/test/unit/test-checks-registry.sh`, above its final `echo "PASS: ..."` line**

```bash
# --- registry -------------------------------------------------------------
# shellcheck source=lib/dev/checks.sh
. "$ROOT/lib/dev/checks.sh"

# Field extraction is 1-indexed and tolerates a title containing spaces.
e="buildx|1|linux,darwin:docker|block|docker buildx present"
[ "$(check_field "$e" 1)" = "buildx" ]                || fail "field 1"
[ "$(check_field "$e" 2)" = "1" ]                     || fail "field 2"
[ "$(check_field "$e" 4)" = "block" ]                 || fail "field 4"
[ "$(check_field "$e" 5)" = "docker buildx present" ] || fail "field 5 lost its spaces"

# Applicability: platform list, runtime list, and '*' wildcards.
check_applies "linux,darwin:docker" Linux  docker || fail "linux:docker should apply on Linux+docker"
check_applies "linux,darwin:docker" Darwin docker || fail "darwin listed but rejected"
check_applies "linux,darwin:docker" Linux  podman && fail "docker-only check applied to podman"
check_applies "linux:*"             Linux  podman || fail "runtime wildcard rejected"
check_applies "linux:*"             Darwin podman && fail "linux-only check applied on Darwin"
check_applies "*:*"                 Darwin podman || fail "full wildcard rejected"
check_applies "darwin:podman"       Linux  podman && fail "darwin-only check applied on Linux"

# A probe's three states map onto CHECK_STATE, and an unknown id is 'na'
# rather than a silent pass.
_chk_fixture_pass() { return 0; }
_chk_fixture_fail() { return 1; }
_chk_fixture_na()   { return 2; }
run_check fixture_pass; [ "$CHECK_STATE" = pass ] || fail "0 should be pass, got $CHECK_STATE"
run_check fixture_fail; [ "$CHECK_STATE" = fail ] || fail "1 should be fail, got $CHECK_STATE"
run_check fixture_na;   [ "$CHECK_STATE" = na ]   || fail "2 should be na, got $CHECK_STATE"
run_check no_such_check
[ "$CHECK_STATE" = na ] || fail "missing probe must be na, never pass — got $CHECK_STATE"

# Selection filters by phase, applicability and severity. Phase 0 exists so
# 'is there a runtime at all' can be answered before $RUNTIME is known.
sel=$(checks_select 0 all Linux docker)
echo "$sel" | grep -q '^platform-supported$' || fail "phase 0 lost platform-supported"
echo "$sel" | grep -q '^buildx$'             && fail "phase 1 check leaked into phase 0"

# Bare (not nested): block-if-nested is advisory, so it is NOT in 'blocking'.
NESTED=false
sel=$(checks_select 1 blocking Linux docker)
echo "$sel" | grep -q '^buildx$'        || fail "blocking filter dropped buildx"
echo "$sel" | grep -q '^userns-sysctl$' && fail "block-if-nested must not block when bare"
echo "$sel" | grep -q '^engine-cli-match$' && fail "advisory must never be in blocking"

# Nested: block-if-nested is promoted.
NESTED=true
sel=$(checks_select 1 blocking Linux podman)
echo "$sel" | grep -q '^userns-sysctl$' || fail "block-if-nested not promoted under --dind"
```

- [ ] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-checks-registry.sh`
Expected: FAIL — `lib/dev/checks.sh` does not exist (bash reports "No such file or directory").

- [ ] **Step 3: Create `lib/dev/checks.sh` with the registry and runner**

```bash
# shellcheck shell=bash
# lib/dev/checks.sh — the host-check registry shared by `dev doctor` and the
# blocking preflights in `dev up`. One source of truth: doctor runs every
# applicable entry, cmd_start runs the blocking subset, so the two can never
# disagree about whether a host is usable.
# Sourced by dev; not executed directly.
#
# Entry format:  id|phase|applies-to|severity|title
#   phase      0 = answerable before detect_runtime; 1 = needs $RUNTIME
#   applies-to platform[,platform]:runtime[,runtime], '*' = any
#   severity   block | block-if-nested | advise
#
# Each id has a `_chk_<id>` probe returning 0 pass / 1 fail / 2 not-applicable,
# and a `_chk_<id>_fix` printing remediation. Probes MUST reach the outside
# world only through the indirections in lib/dev/runtime.sh (_host_os,
# _have_cmd, _runtime_version, _read_sysfs) so they stay unit-testable from
# any platform.
CHECKS=(
  "platform-supported|0|*:*|block|supported platform (linux/darwin)"
  "runtime-present|0|*:*|block|a container runtime is installed"
  "buildx|1|linux,darwin:docker|block|docker buildx present"
  "not-docker-desktop|1|darwin:*|block|not Docker Desktop"
  "podman-machine|1|darwin:podman|block|podman machine running"
  "workspace-not-root|1|*:*|block|workspace not root-owned"
  "userns-sysctl|1|linux:*|block-if-nested|unprivileged userns permitted"
  "subid-grant|1|linux:podman|block-if-nested|subuid/subgid range >= 165535"
  "fuse-device|1|linux:*|block-if-nested|/dev/fuse accessible"
  "cgroup2|1|linux:*|block-if-nested|cgroup v2"
  "engine-cli-match|1|*:*|advise|CLI and engine agree"
  "home-volume-owner|1|*:podman|advise|home volume ownership matches uid"
  "selinux-enforcing|1|linux:*|advise|SELinux not enforcing"
  "disk-space|1|*:*|advise|at least 3 GB free"
  "memory|1|*:*|advise|at least 6 GB RAM for nested engines"
  "github-token-scopes|1|*:*|advise|GITHUB_TOKEN carries no scopes"
)

# Field n (1-indexed) of a registry entry.
check_field() {
  echo "$1" | cut -d'|' -f"$2"
}

# Does <applies-to> cover <os> + <runtime>? Case-insensitive on the OS so
# "Darwin" from uname matches "darwin" in the table (bash 3.2 has no
# ${var,,}, hence tr).
check_applies() {
  local spec="$1" os="$2" rt="$3" want_os want_rt
  want_os="${spec%%:*}"
  want_rt="${spec##*:}"
  os=$(echo "$os" | tr '[:upper:]' '[:lower:]')
  if [[ "$want_os" != "*" ]]; then
    case ",$want_os," in
      *",$os,"*) ;;
      *) return 1 ;;
    esac
  fi
  if [[ "$want_rt" != "*" ]]; then
    case ",$want_rt," in
      *",$rt,"*) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Run one probe. Sets CHECK_STATE to pass|fail|na and always returns 0 so a
# caller under `set -e` keeps going. A probe that does not exist is 'na',
# never 'pass' — an undetermined check must not read as a healthy host.
run_check() {
  local id="$1" rc
  if ! command -v "_chk_$id" >/dev/null 2>&1; then
    CHECK_STATE=na
    return 0
  fi
  "_chk_$id"; rc=$?
  case "$rc" in
    0) CHECK_STATE=pass ;;
    1) CHECK_STATE=fail ;;
    *) CHECK_STATE=na ;;
  esac
  return 0
}

# Print the ids matching <phase> and <severity-filter> for <os>/<runtime>,
# one per line, in registry order. severity-filter is 'all' or 'blocking';
# 'blocking' includes block-if-nested only when $NESTED is true.
checks_select() {
  local want_phase="$1" filter="$2" os="$3" rt="$4"
  local entry id phase spec sev
  for entry in "${CHECKS[@]}"; do
    id=$(check_field "$entry" 1)
    phase=$(check_field "$entry" 2)
    spec=$(check_field "$entry" 3)
    sev=$(check_field "$entry" 4)
    [[ "$phase" == "$want_phase" ]] || continue
    check_applies "$spec" "$os" "$rt" || continue
    if [[ "$filter" == blocking ]]; then
      case "$sev" in
        block) ;;
        block-if-nested) [[ "${NESTED:-false}" == true ]] || continue ;;
        *) continue ;;
      esac
    fi
    echo "$id"
  done
}
```

- [ ] **Step 4: Run it — must pass**

Run: `bash scripts/test/unit/test-checks-registry.sh`
Expected: `PASS: check registry indirections`

- [ ] **Step 5: Commit**

```bash
mise x shellcheck -- shellcheck -x dev lib/dev/*.sh && bash scripts/lint.sh
git add lib/dev/checks.sh scripts/test/unit/test-checks-registry.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "feat(cli): add the host-check registry, filter and runner"
```

---

### Task 4: Phase-0 and blocking probes

**Files:**
- Modify: `lib/dev/checks.sh` (append probes)
- Test: `scripts/test/unit/test-checks-catalog.sh` (create)

**Interfaces:**
- Consumes: `run_check`, `CHECK_STATE` (Task 3); `_host_os`, `_have_cmd`, `_runtime_version` (Task 1).
- Produces: `_chk_platform_supported`, `_chk_runtime_present`, `_chk_buildx`, `_chk_not_docker_desktop`, `_chk_podman_machine`, `_chk_workspace_not_root`, each with a `_fix` twin.

Note the shell-name mapping: registry id `not-docker-desktop` → function
`_chk_not_docker_desktop`. `run_check` must translate hyphens to underscores;
add that now.

- [ ] **Step 1: Write the failing test**

Create `scripts/test/unit/test-checks-catalog.sh`:

```bash
#!/usr/bin/env bash
# Unit: every probe in the check catalogue, against stubbed conditions.
# No real runtime, no real /proc, no real platform — that is the point: the
# macOS probes are verified here from Linux, and the Linux ones from macOS.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
# shellcheck source=lib/dev/checks.sh
. "$ROOT/lib/dev/checks.sh"
RUNTIME=docker; RUNTIME_ARGS=""

# Registry ids use hyphens; shell functions use underscores.
run_check not-docker-desktop
[ "$CHECK_STATE" != "na" ] || fail "run_check did not map hyphens to underscores"

# --- platform-supported ---
DEV_FAKE_OS=Linux  run_check platform-supported; [ "$CHECK_STATE" = pass ] || fail "Linux unsupported?"
DEV_FAKE_OS=Darwin run_check platform-supported; [ "$CHECK_STATE" = pass ] || fail "Darwin unsupported?"
DEV_FAKE_OS=SunOS  run_check platform-supported; [ "$CHECK_STATE" = fail ] || fail "SunOS should fail"

# --- runtime-present ---
DEV_FAKE_CMDS="docker" run_check runtime-present; [ "$CHECK_STATE" = pass ] || fail "docker present"
DEV_FAKE_CMDS="podman" run_check runtime-present; [ "$CHECK_STATE" = pass ] || fail "podman present"
DEV_FAKE_CMDS="git"    run_check runtime-present; [ "$CHECK_STATE" = fail ] || fail "no runtime should fail"

# --- buildx: the 2026-08-15 false-green ---
DEV_FAKE_CMDS="docker docker-buildx" run_check buildx
[ "$CHECK_STATE" = pass ] || fail "buildx present should pass"
DEV_FAKE_CMDS="docker" run_check buildx
[ "$CHECK_STATE" = fail ] || fail "missing buildx must FAIL — this is the check that would have saved a whole session"
_chk_buildx_fix | grep -qi 'docker-buildx' || fail "buildx fix does not name the package"

# --- not-docker-desktop ---
DEV_FAKE_RUNTIME_VERSION='Docker version 27.0.0, build abc' run_check not-docker-desktop
[ "$CHECK_STATE" = fail ] || fail "Docker Desktop must fail on macOS"
DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' run_check not-docker-desktop
[ "$CHECK_STATE" = pass ] || fail "podman is not Docker Desktop"

# --- podman-machine ---
DEV_FAKE_MACHINE_RUNNING=true  run_check podman-machine; [ "$CHECK_STATE" = pass ] || fail "running machine"
DEV_FAKE_MACHINE_RUNNING=false run_check podman-machine; [ "$CHECK_STATE" = fail ] || fail "stopped machine"
_chk_podman_machine_fix | grep -q 'podman machine start' || fail "machine fix lost its command"

# --- workspace-not-root ---
HOST_UID=1000 run_check workspace-not-root; [ "$CHECK_STATE" = pass ] || fail "uid 1000 is fine"
HOST_UID=0    run_check workspace-not-root; [ "$CHECK_STATE" = fail ] || fail "root must fail"

echo "PASS: phase-0 and blocking probes"
```

- [ ] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-checks-catalog.sh`
Expected: `FAIL: run_check did not map hyphens to underscores`

- [ ] **Step 3: Add the hyphen mapping to `run_check` in `lib/dev/checks.sh`**

Replace the first two lines of `run_check`'s body:

```bash
run_check() {
  local id="$1" fn rc
  fn="_chk_$(echo "$id" | tr '-' '_')"
  if ! command -v "$fn" >/dev/null 2>&1; then
    CHECK_STATE=na
    return 0
  fi
  "$fn"; rc=$?
```

and change the `_fix` lookup convention to match (used in Task 6):
`_chk_$(echo "$id" | tr '-' '_')_fix`.

- [ ] **Step 4: Append the probes to `lib/dev/checks.sh`**

```bash
# --- phase 0 --------------------------------------------------------------

_chk_platform_supported() {
  case "$(_host_os)" in
    Linux|Darwin) return 0 ;;
    *) return 1 ;;
  esac
}
_chk_platform_supported_fix() {
  echo "dev supports Linux and macOS only; this host reports $(_host_os)."
}

_chk_runtime_present() {
  _have_cmd docker && return 0
  _have_cmd podman && return 0
  return 1
}
_chk_runtime_present_fix() {
  if [[ "$(_host_os)" == "Darwin" ]]; then
    echo "Install podman (Docker Desktop is not supported):"
    echo "    brew install podman && podman machine init && podman machine start"
  else
    echo "Install a container runtime, e.g.:"
    echo "    sudo apt-get install -y docker.io docker-buildx"
  fi
}

# --- phase 1, blocking ----------------------------------------------------

# The Dockerfile uses BuildKit's RUN --mount=type=secret, which the legacy
# builder cannot handle. Missing buildx therefore fails EVERY image build.
# On 2026-08-15 this went undetected: the test orchestrator installs buildx
# only when no runtime is present at all, so a host with docker and no buildx
# failed every scenario and still wrote a summary that read as clean.
_chk_buildx() {
  _have_cmd docker-buildx && return 0
  _have_cmd buildx && return 0
  return 1
}
_chk_buildx_fix() {
  echo "The Dockerfile uses RUN --mount=type=secret, which the legacy builder"
  echo "cannot handle, so buildx is mandatory."
  echo "    Debian/Ubuntu:  sudo apt-get install -y docker-buildx"
  echo "    other:          https://docs.docker.com/go/buildx/"
  echo "Or force podman instead:  DEV_RUNTIME=podman"
}

_chk_not_docker_desktop() {
  _runtime_version | grep -qi podman && return 0
  _runtime_version | grep -qi docker && return 1
  return 2
}
_chk_not_docker_desktop_fix() {
  echo "Docker Desktop is not supported on macOS; dev targets podman."
  echo "    brew install podman && podman machine init && podman machine start"
  echo "Then pin it:  DEV_RUNTIME=podman"
}

_chk_podman_machine() {
  _machine_running && return 0
  return 1
}
_chk_podman_machine_fix() {
  echo "Start the VM that backs podman on macOS:"
  echo "    podman machine start"
  echo "(First time:  podman machine init)"
}

_chk_workspace_not_root() {
  [[ "${HOST_UID:-$(id -u)}" == "0" ]] && return 1
  return 0
}
_chk_workspace_not_root_fix() {
  echo "Run dev as your normal user. The image creates a non-root 'vscode'"
  echo "user; UID 0 would collide with the image's existing root."
}
```

- [ ] **Step 5: Run it — must pass**

Run: `bash scripts/test/unit/test-checks-catalog.sh`
Expected: `PASS: phase-0 and blocking probes`

- [ ] **Step 6: Commit**

```bash
mise x shellcheck -- shellcheck -x dev lib/dev/*.sh && bash scripts/lint.sh
git add lib/dev/checks.sh scripts/test/unit/test-checks-catalog.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "feat(cli): add phase-0 and blocking host checks"
```

---

### Task 5: Nested-only probes (migrating `preflight.sh`)

**Files:**
- Modify: `lib/dev/checks.sh` (append), `scripts/test/unit/test-checks-catalog.sh` (extend)
- Read: `lib/dev/preflight.sh` — the error text below is copied from it verbatim; do not paraphrase, scenario 15 greps it.

**Interfaces:**
- Consumes: `_read_sysfs`, `runtime_is_rootless`, `subid_total`.
- Produces: `_chk_userns_sysctl`, `_chk_subid_grant`, `_chk_fuse_device`, `_chk_cgroup2` and `_fix` twins. `subid_total` moves from `preflight.sh` into `checks.sh` unchanged.

- [ ] **Step 1: Write the failing test — append above the final `echo` of `scripts/test/unit/test-checks-catalog.sh`**

```bash
# --- userns-sysctl: the host control that blocked 10 scenarios on 2026-08-15 ---
DEV_FAKE_SYSFS_VALUE=0 run_check userns-sysctl; [ "$CHECK_STATE" = pass ] || fail "sysctl 0 is fine"
DEV_FAKE_SYSFS_VALUE=1 run_check userns-sysctl; [ "$CHECK_STATE" = fail ] || fail "sysctl 1 must fail"
_chk_userns_sysctl_fix | grep -q 'apparmor_restrict_unprivileged_userns=0' \
    || fail "userns fix lost its sysctl command"

# --- subid-grant: 165535 is the image contract, not a round number ---
_subid_stub() { echo 200000; }
subid_total() { _subid_stub; }
DIND_MIN_SUBIDS=165535 run_check subid-grant; [ "$CHECK_STATE" = pass ] || fail "200000 ids is enough"
_subid_stub() { echo 65536; }
DIND_MIN_SUBIDS=165535 run_check subid-grant; [ "$CHECK_STATE" = fail ] || fail "65536 ids is too few"
_chk_subid_grant_fix | grep -q 'usermod --add-subuids' || fail "subid fix lost usermod"

# --- fuse-device ---
_have_dev_fuse() { return 0; }; run_check fuse-device; [ "$CHECK_STATE" = pass ] || fail "fuse present"
_have_dev_fuse() { return 1; }; run_check fuse-device; [ "$CHECK_STATE" = fail ] || fail "fuse missing"

# --- cgroup2 ---
_cgroup_version() { echo 2; }; run_check cgroup2; [ "$CHECK_STATE" = pass ] || fail "cgroup v2"
_cgroup_version() { echo 1; }; run_check cgroup2; [ "$CHECK_STATE" = fail ] || fail "cgroup v1 must fail"
```

- [ ] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-checks-catalog.sh`
Expected: FAIL at the userns case (`CHECK_STATE` is `na`, probe undefined).

- [ ] **Step 3: Append to `lib/dev/checks.sh`**

Move `subid_total` from `preflight.sh` verbatim (it is unchanged), then add:

```bash
# --- phase 1, blocking only under --dind/--pind ---------------------------

_have_dev_fuse() { [[ -r /dev/fuse ]]; }
_cgroup_version() { [[ -d /sys/fs/cgroup/cgroup.controllers || -f /sys/fs/cgroup/cgroup.controllers ]] && echo 2 || echo 1; }

_chk_userns_sysctl() {
  [[ -n "${DEV_SKIP_APPARMOR_CHECK:-}" ]] && return 2
  local v
  v=$(_read_sysfs /proc/sys/kernel/apparmor_restrict_unprivileged_userns)
  [[ -z "$v" ]] && return 2       # kernel does not have the knob: not applicable
  [[ "$v" == "1" ]] && return 1
  return 0
}
_chk_userns_sysctl_fix() {
  cat <<'EOF'
Rootless dockerd/podman inside --dind/--pind must create a user namespace;
--security-opt apparmor=unconfined does NOT bypass this kernel restriction.

Allow it on this host:
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

Persist across reboots:
    echo 'kernel.apparmor_restrict_unprivileged_userns=0' \
      | sudo tee /etc/sysctl.d/99-rootless-userns.conf

Set DEV_SKIP_APPARMOR_CHECK=1 to bypass this check.
EOF
}

_chk_subid_grant() {
  [[ -n "${DEV_SKIP_SUBID_CHECK:-}" ]] && return 2
  runtime_is_rootless || return 2   # rootful maps every id already
  local u g
  u=$(subid_total /etc/subuid)
  g=$(subid_total /etc/subgid)
  [[ "$u" -lt "${DIND_MIN_SUBIDS:-165535}" ]] && return 1
  [[ "$g" -lt "${DIND_MIN_SUBIDS:-165535}" ]] && return 1
  return 0
}
_chk_subid_grant_fix() {
  local u next
  u=$(subid_total /etc/subuid)
  next=$((100000 + u))
  echo "Rootless runtimes give the container only the ids granted to $(id -un)"
  echo "in /etc/subuid + /etc/subgid. The image maps container ids"
  echo "100000-165535, so at least ${DIND_MIN_SUBIDS:-165535} are needed or"
  echo "rootlesskit dies with 'newuidmap: write to uid_map failed'."
  echo "    sudo usermod --add-subuids ${next}-365535 --add-subgids ${next}-365535 $(id -un)"
  _runtime_version | grep -qi podman && \
    echo "    podman system migrate    # restart podman's userns with the new grant"
  echo "Set DEV_SKIP_SUBID_CHECK=1 to bypass this check."
}

_chk_fuse_device() { _have_dev_fuse && return 0; return 1; }
_chk_fuse_device_fix() {
  echo "Nested engines need /dev/fuse for fuse-overlayfs."
  echo "    sudo modprobe fuse"
  echo "and ensure your user can read /dev/fuse."
}

_chk_cgroup2() { [[ "$(_cgroup_version)" == 2 ]] && return 0; return 1; }
_chk_cgroup2_fix() {
  echo "Nested rootless engines require cgroup v2 (unified hierarchy)."
  echo "Boot with:  systemd.unified_cgroup_hierarchy=1"
}
```

- [ ] **Step 4: Run it — must pass**

Run: `bash scripts/test/unit/test-checks-catalog.sh`
Expected: `PASS: phase-0 and blocking probes`

- [ ] **Step 5: Commit**

```bash
mise x shellcheck -- shellcheck -x dev lib/dev/*.sh && bash scripts/lint.sh
git add lib/dev/checks.sh scripts/test/unit/test-checks-catalog.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "feat(cli): add nested-mode host checks, migrating preflight probes"
```

---

### Task 6: Advisory probes

**Files:**
- Modify: `lib/dev/checks.sh` (append), `scripts/test/unit/test-checks-catalog.sh` (extend)

**Interfaces:**
- Produces: `_chk_engine_cli_match`, `_chk_home_volume_owner`, `_chk_selinux_enforcing`, `_chk_disk_space`, `_chk_memory`, `_chk_github_token_scopes` and `_fix` twins.

- [ ] **Step 1: Write the failing test — append above the final `echo`**

```bash
# --- engine-cli-match: the 2026-08-15 DOCKER_HOST bug ---
RUNTIME=docker
DEV_FAKE_RUNTIME_VERSION='podman version 5.7.0' run_check engine-cli-match
[ "$CHECK_STATE" = pass ] || fail "podman CLI + podman engine agree"
_engine_server_name() { echo "Podman Engine"; }
DEV_FAKE_RUNTIME_VERSION='Docker version 29.1.3' run_check engine-cli-match
[ "$CHECK_STATE" = fail ] || fail "docker CLI on a podman socket must be flagged"
_engine_server_name() { echo "Engine"; }
DEV_FAKE_RUNTIME_VERSION='Docker version 29.1.3' run_check engine-cli-match
[ "$CHECK_STATE" = pass ] || fail "docker CLI + dockerd agree"

# --- disk-space / memory: thresholds from docs/ci-testing.md ---
_free_disk_gb() { echo 10; }; run_check disk-space; [ "$CHECK_STATE" = pass ] || fail "10 GB is enough"
_free_disk_gb() { echo 1; };  run_check disk-space; [ "$CHECK_STATE" = fail ] || fail "1 GB is not"
_total_mem_gb() { echo 16; }; run_check memory;     [ "$CHECK_STATE" = pass ] || fail "16 GB is enough"
_total_mem_gb() { echo 4; };  run_check memory;     [ "$CHECK_STATE" = fail ] || fail "4 GB is not"

# --- github-token-scopes: a scoped token is power handed to the agent ---
GITHUB_TOKEN="" run_check github-token-scopes
[ "$CHECK_STATE" = na ] || fail "no token means not-applicable, not pass"
_token_scopes() { echo ""; }
GITHUB_TOKEN=x run_check github-token-scopes; [ "$CHECK_STATE" = pass ] || fail "scopeless token is fine"
_token_scopes() { echo "repo, workflow"; }
GITHUB_TOKEN=x run_check github-token-scopes; [ "$CHECK_STATE" = fail ] || fail "scoped token must warn"

# --- selinux ---
_selinux_mode() { echo Enforcing; }; run_check selinux-enforcing; [ "$CHECK_STATE" = fail ] || fail "enforcing"
_selinux_mode() { echo ""; };        run_check selinux-enforcing; [ "$CHECK_STATE" = na ]   || fail "absent = na"

# --- home-volume-owner: rootless-podman posture only ---
runtime_is_rootless() { return 1; }
run_check home-volume-owner
[ "$CHECK_STATE" = na ] || fail "rootful runtimes never remap ids — must be na, got $CHECK_STATE"
runtime_is_rootless() { return 0; }
run_check home-volume-owner
[ "$CHECK_STATE" = pass ] || fail "rootless posture should report pass, got $CHECK_STATE"
_chk_home_volume_owner_fix | grep -q 'dev down' || fail "home-volume fix lost its remediation"
```

- [ ] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-checks-catalog.sh`
Expected: FAIL at the engine-cli-match case.

- [ ] **Step 3: Append to `lib/dev/checks.sh`**

```bash
# --- phase 1, advisory ----------------------------------------------------

# The server's own component name, e.g. "Podman Engine" or "Engine".
_engine_server_name() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME ${RUNTIME_ARGS:-} version --format '{{.Server.Components}}' 2>/dev/null || true
}
_free_disk_gb() { df -Pg . 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }
_total_mem_gb() {
  if [[ "$(_host_os)" == "Darwin" ]]; then
    echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  else
    awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 0
  fi
}
_token_scopes() {
  curl -sS -I -H "Authorization: bearer ${GITHUB_TOKEN}" https://api.github.com/ 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}'
}
_selinux_mode() { command -v getenforce >/dev/null 2>&1 && getenforce 2>/dev/null || echo ""; }

# A real Docker CLI can be pointed at a podman socket via DOCKER_HOST. dev
# auto-switches to the podman CLI (runtime.sh), but the user should know why
# their commands are being rewritten. Advisory, never blocking.
_chk_engine_cli_match() {
  _runtime_version | grep -qi podman && return 0     # CLI is podman: agrees
  _engine_server_name | grep -qi podman && return 1  # CLI docker, engine podman
  return 0
}
_chk_engine_cli_match_fix() {
  echo "DOCKER_HOST=${DOCKER_HOST:-unset} points at a podman engine while the"
  echo "CLI is Docker. dev drives podman directly, because --userns=keep-id is"
  echo "podman-only and the Docker CLI rejects it."
  echo "Pin it explicitly to silence this:  DEV_RUNTIME=podman"
}

_chk_home_volume_owner() {
  runtime_is_rootless || return 2
  return 0   # dev migrates ownership automatically; report the posture only
}
_chk_home_volume_owner_fix() {
  echo "Under rootless podman dev re-chowns named volumes once via"
  echo "'podman unshare chown'. If \$HOME or /mise is unwritable inside the"
  echo "container, run 'dev down' then 'dev up' to trigger the migration."
}

_chk_selinux_enforcing() {
  local m; m=$(_selinux_mode)
  [[ -z "$m" ]] && return 2
  [[ "$m" == "Enforcing" ]] && return 1
  return 0
}
_chk_selinux_enforcing_fix() {
  echo "SELinux is enforcing. dev passes --security-opt label=disable for"
  echo "nested engines, so this is usually fine; if a nested mount is denied,"
  echo "that is the first thing to check."
}

_chk_disk_space() { [[ "$(_free_disk_gb)" -lt 3 ]] && return 1; return 0; }
_chk_disk_space_fix() { echo "Images and the mise cache need ~3 GB free; free some space."; }

_chk_memory() { [[ "$(_total_mem_gb)" -lt 6 ]] && return 1; return 0; }
_chk_memory_fix() {
  echo "Nested engines (--dind/--pind) want ~6 GB; with less the kernel may"
  echo "OOM-kill the build. Normal mode is fine on less."
}

_chk_github_token_scopes() {
  [[ -z "${GITHUB_TOKEN:-}" ]] && return 2
  [[ -n "$(_token_scopes)" ]] && return 1
  return 0
}
_chk_github_token_scopes_fix() {
  echo "GITHUB_TOKEN carries OAuth scopes. An agent inside the container can"
  echo "read it, so those scopes are scopes you hand the agent. Its only job"
  echo "here is rate-limit identification: use a fine-grained PAT with no"
  echo "repository access and no permissions."
}
```

- [ ] **Step 4: Run it — must pass**

Run: `bash scripts/test/unit/test-checks-catalog.sh`
Expected: `PASS: phase-0 and blocking probes`

- [ ] **Step 5: Budget checkpoint**

Run: `wc -l lib/dev/checks.sh`
If over 300, move every `_chk_*`/`_chk_*_fix` pair into a new
`lib/dev/checks-catalog.sh` (the loader glob in `dev` picks it up
automatically), leaving `CHECKS`, `check_field`, `check_applies`,
`run_check` and `checks_select` in `checks.sh`. Re-run both unit tests.

- [ ] **Step 6: Commit**

```bash
mise x shellcheck -- shellcheck -x dev lib/dev/*.sh && bash scripts/lint.sh
git add -A
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "feat(cli): add advisory host checks"
```

---

### Task 7: The `dev doctor` verb

**Files:**
- Create: `lib/dev/doctor.sh`
- Modify: `dev` (router arm), `lib/dev/usage.sh` (VERBS entry)
- Test: `scripts/test/unit/test-doctor-report.sh` (create)

**Interfaces:**
- Consumes: `checks_select`, `run_check`, `CHECK_STATE`, `check_field`, `CHECKS`; `detect_runtime`, `_host_os`.
- Produces: `cmd_doctor "$@"`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test/unit/test-doctor-report.sh`:

```bash
#!/usr/bin/env bash
# Unit: dev doctor's report and exit contract. Runs against a scratch cwd so
# the workspace name never collides with this checkout.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
doctor() { (cd "$WORK" && "$ROOT/dev" doctor "$@" </dev/null 2>&1); }
fail() { echo "FAIL: $1"; exit 1; }

# Runs at all, and names itself.
out=$(doctor); rc=$?
echo "$out" | grep -qi 'Host' || fail "no Host summary line: $out"

# Exit code is 0 or 1 — never a stack trace or 2 — on a normal host.
[ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || fail "unexpected exit $rc: $out"

# Every check title in the registry that applies here should appear.
echo "$out" | grep -q 'buildx' || fail "buildx check missing from report: $out"

# A summary line accounts for every check.
echo "$out" | grep -qE '[0-9]+ (blocking|passed)' || fail "no summary tally: $out"

# Unknown argument is a usage error, exit 2 — matches the verb grammar.
out=$(doctor --bogus); rc=$?
[ "$rc" -eq 2 ] || fail "bad flag should exit 2, got $rc: $out"

# --dind is accepted (it promotes nested checks to blocking).
doctor --dind >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || fail "--dind should be accepted, got $rc"

# Non-tty output is plain ASCII: this gets pasted into chat.
out=$(doctor)
echo "$out" | LC_ALL=C grep -q '[^ -~]' && fail "non-ASCII leaked into non-tty output"

# Nothing here required a running container or a built image.
echo "$out" | grep -qi 'no such container' && fail "doctor touched a container"

echo "PASS: doctor report and exit contract"
```

- [ ] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-doctor-report.sh`
Expected: FAIL — `dev` rejects `doctor` as an unknown verb (exit 2).

- [ ] **Step 3: Create `lib/dev/doctor.sh`**

```bash
# shellcheck shell=bash
# lib/dev/doctor.sh — the `dev doctor` verb: run every applicable host check
# and print one screen naming each problem and its fix.
#
# Must work on a machine where NOTHING is set up: no image, no container, no
# running podman machine. That is the whole point — it is the first command a
# colleague runs on an unfamiliar laptop.
# Sourced by dev; not executed directly.

# Glyphs. Non-tty output stays ASCII because this report gets pasted into
# chat when someone asks for help.
_doc_glyph() {
  local state="$1"
  if [[ -t 1 ]]; then
    case "$state" in
      pass) printf '\033[32m✓\033[0m' ;;
      fail) printf '\033[31m✗\033[0m' ;;
      advise) printf '\033[33m!\033[0m' ;;
      *) printf '–' ;;
    esac
  else
    case "$state" in
      pass) printf 'ok  ' ;;
      fail) printf 'FAIL' ;;
      advise) printf 'warn' ;;
      *) printf 'n/a ' ;;
    esac
  fi
}

cmd_doctor() {
  NESTED=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dind|--pind) NESTED=true; shift ;;
      *) echo "Error: unknown option for 'dev doctor': $1" >&2
         echo "Usage: dev doctor [--dind|--pind]" >&2
         exit 2 ;;
    esac
  done

  # Phase 0 runs before a runtime is known.
  local os id state sev title entry
  os="$(_host_os)"
  local blocking=0 advisories=0 passed=0 na=0

  _report_one() {
    local id="$1" sev="$2" title="$3"
    run_check "$id"
    local shown="$CHECK_STATE"
    if [[ "$CHECK_STATE" == fail && "$sev" == advise ]]; then
      shown=advise; advisories=$((advisories + 1))
    elif [[ "$CHECK_STATE" == fail && "$sev" == block-if-nested && "$NESTED" != true ]]; then
      shown=advise; advisories=$((advisories + 1))
    elif [[ "$CHECK_STATE" == fail ]]; then
      blocking=$((blocking + 1))
    elif [[ "$CHECK_STATE" == pass ]]; then
      passed=$((passed + 1))
    else
      na=$((na + 1))
    fi
    printf '  %s  %s\n' "$(_doc_glyph "$shown")" "$title"
    if [[ "$shown" == fail || "$shown" == advise ]]; then
      local fixfn
      fixfn="_chk_$(echo "$id" | tr '-' '_')_fix"
      if command -v "$fixfn" >/dev/null 2>&1; then
        "$fixfn" | sed 's/^/       /'
      fi
    fi
  }

  for id in $(checks_select 0 all "$os" ""); do
    for entry in "${CHECKS[@]}"; do
      [[ "$(check_field "$entry" 1)" == "$id" ]] || continue
      _report_one "$id" "$(check_field "$entry" 4)" "$(check_field "$entry" 5)"
    done
  done

  # Only now is it safe to identify the runtime.
  if _chk_runtime_present; then
    NEEDS_ENGINE=false
    detect_runtime
    printf 'Host      %s\n' "$os"
    printf 'Runtime   %s\n' "$RUNTIME"
    for id in $(checks_select 1 all "$os" "$RUNTIME"); do
      for entry in "${CHECKS[@]}"; do
        [[ "$(check_field "$entry" 1)" == "$id" ]] || continue
        _report_one "$id" "$(check_field "$entry" 4)" "$(check_field "$entry" 5)"
      done
    done
  fi

  echo
  printf '%d blocking, %d advisory, %d passed, %d not applicable\n' \
    "$blocking" "$advisories" "$passed" "$na"
  [[ "$blocking" -eq 0 ]] || exit 1
  exit 0
}
```

Note: the `Host`/`Runtime` lines print after phase 0 because phase 0 can fail
before a runtime exists. If a reviewer prefers them first, buffer phase-0
output — do not move `detect_runtime` earlier.

- [ ] **Step 4: Route the verb**

In `dev`, in the `case "$subcmd"` block, after the `status)` arm:

```bash
  doctor)           cmd_doctor "$@" ;;
```

In `lib/dev/usage.sh`, in the VERBS block after the `status` entry:

```
  doctor          Check this host for everything dev needs and print a
                  report with fixes. Works before anything is set up.
                  Options: --dind / --pind (also require nested-mode
                  prerequisites). Exits 1 if anything blocking fails.
```

- [ ] **Step 5: Run the tests**

Run:
```bash
bash scripts/test/unit/test-doctor-report.sh
bash scripts/test/unit/test-dev-subcommands.sh
bash scripts/test/scenarios/50-cli-verbs.sh
```
Expected: `PASS: doctor report and exit contract`; the other two exit 0.

- [ ] **Step 6: Eyeball it**

Run: `./dev doctor` and read the output. It must fit a screen, name a real
problem if this host has one, and print no remediation under a passing check.

- [ ] **Step 7: Commit**

```bash
mise x shellcheck -- shellcheck -x dev lib/dev/*.sh && bash scripts/lint.sh
git add -A
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "feat(cli): add the dev doctor verb"
```

---

### Task 8: `dev up` consumes the registry

**Files:**
- Modify: `lib/dev/up.sh` (`cmd_start`, currently calls `preflight_apparmor_userns` at line 167 and `preflight_subid_grant` at line 196)
- Delete: `lib/dev/preflight.sh`
- Test: existing scenarios 11, 12, 15, 16 are the gate

**Interfaces:**
- Consumes: `checks_select`, `run_check`, `CHECK_STATE`, `check_field`.
- Produces: `run_blocking_checks <phase>` in `checks.sh`.

- [ ] **Step 1: Add the blocking runner to `lib/dev/checks.sh`**

```bash
# Run every blocking check for <phase> and refuse if any fail. Reports ALL
# failures, not just the first: the old code ordered the apparmor check ahead
# of the subid one purely so its error would win the race (see the comment
# that used to sit at up.sh:143), which meant a user fixed one problem only to
# discover the next. Ordered registry, all failures, one exit.
run_blocking_checks() {
  local phase="$1" os rt id entry failed=0
  os="$(_host_os)"
  rt="${RUNTIME:-}"
  for id in $(checks_select "$phase" blocking "$os" "$rt"); do
    run_check "$id"
    [[ "$CHECK_STATE" == fail ]] || continue
    failed=1
    for entry in "${CHECKS[@]}"; do
      [[ "$(check_field "$entry" 1)" == "$id" ]] || continue
      echo "Error: $(check_field "$entry" 5)" >&2
    done
    local fixfn
    fixfn="_chk_$(echo "$id" | tr '-' '_')_fix"
    command -v "$fixfn" >/dev/null 2>&1 && "$fixfn" | sed 's/^/       /' >&2
    echo >&2
  done
  if [[ "$failed" -eq 1 ]]; then
    echo "Run 'dev doctor' for the full picture." >&2
    exit 1
  fi
}
```

- [ ] **Step 2: Replace the preflight calls in `lib/dev/up.sh`**

`NESTED` drives `block-if-nested`, so set it from the mode flags. Delete the
line `preflight_apparmor_userns` and the line `preflight_subid_grant`, and the
`DIND_MIN_SUBIDS=165535` assignment stays (the subid probe reads it).

Before `detect_runtime`:

```bash
  # block-if-nested checks apply only to --dind/--pind.
  NESTED=false
  [[ "$DIND" == true || "$PIND" == true ]] && NESTED=true
  run_blocking_checks 0
```

After `detect_runtime` / `ensure_runtime_ready`, where `preflight_subid_grant`
used to be:

```bash
  run_blocking_checks 1
```

`refuse_root_uid` is now the `workspace-not-root` check; delete its call too.

- [ ] **Step 3: Delete the migrated file**

```bash
git rm lib/dev/preflight.sh
grep -rn 'preflight_apparmor_userns\|preflight_subid_grant\|refuse_root_uid' dev lib/ scripts/ \
  || echo "no dangling references"
```
Expected: `no dangling references`.

- [ ] **Step 4: Run the migration gate**

These four scenarios assert preflight behaviour and are the risk the spec
flagged. All must still pass:

```bash
for s in 11-userns-clone-disabled 12-fuse-missing 15-apparmor-userns-restrict 16-rootless-subid-preflight; do
  echo "=== $s"; sudo bash scripts/test/scenarios/$s.sh 2>&1 | tail -2
done
```
Expected: each prints `[PASS]` or `[SKIP]` — no `[FAIL]`.

If one fails on message wording rather than behaviour, fix the check's text to
match what the scenario greps; the scenarios encode the contract users see.

- [ ] **Step 5: Full local verification**

```bash
bash scripts/lint.sh
for t in scripts/test/unit/*.sh; do n=$(basename "$t" .sh); [ "$n" = test-runner ] && continue
  bash "$t" >/dev/null 2>&1 && echo "OK   $n" || echo "FAIL $n"; done
bash scripts/test/scenarios/50-cli-verbs.sh
```
Expected: lint exits 0; the only unit failure is `test-cli-invalid-distro`
(pre-existing, needs qemu); scenario 50 passes.

- [ ] **Step 6: Full matrix**

Run: `sudo bash scripts/test/run-all.sh`
Expected: **23 passed, 10 failed, 6 skipped** — identical to the 2026-08-15
baseline. The 10 failures are the `kernel.apparmor_restrict_unprivileged_userns=1`
blockers, left set deliberately. Any *other* failure is a regression from this
task; investigate before committing.

- [ ] **Step 7: Commit**

```bash
git add -A
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "refactor(cli): drive dev up preflights from the check registry"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md` (Daily Use, Host Requirements), `CLAUDE.md` (command block, Architecture)

- [ ] **Step 1: README — add `dev doctor` to Daily Use**

After the `dev up --host-port 8080` line in the Daily Use block:

```bash
dev doctor                # check this host for everything dev needs
dev doctor --dind         # also check nested-engine prerequisites
```

- [ ] **Step 2: README — rewrite the Host Requirements opening**

Replace its first paragraph with:

```markdown
Run `dev doctor` — it checks every requirement below on your actual machine
and prints the fix for anything missing. It needs no image, no container and
no running podman machine, so it works before anything is set up.
```

- [ ] **Step 3: CLAUDE.md — add to the command block and Architecture**

In the `## Build and Run` block:

```bash
# Check the host for everything dev needs (no image or container required).
./dev doctor
```

In `## Architecture`, after the `dev` bullet:

```markdown
- **lib/dev/checks.sh** — the host-check registry. One entry per requirement
  (`id|phase|applies-to|severity|title`) plus a probe function. `dev doctor`
  runs every applicable entry; `cmd_start` runs the blocking subset, so the
  two cannot disagree about whether a host is usable. Probes reach the outside
  world only through the indirections in `runtime.sh`, which is what makes the
  macOS checks testable from Linux.
```

- [ ] **Step 4: Verify and commit**

```bash
grep -n 'dev doctor' README.md CLAUDE.md | head
bash scripts/lint.sh
git add README.md CLAUDE.md
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "docs: document dev doctor and the check registry"
```

---

## Increment 1 complete

At this point `dev doctor` exists, `dev up` shares its registry, and every
check is unit-tested from any platform. Increment 2 (privilege tagging, the
rootless cell, the macOS cell, scenario 51, and the `run-all.sh` buildx gate
fix) is a separate plan that depends on this one.
