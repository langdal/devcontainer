# Test Matrix Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Test the two host combinations the suite currently cannot reach — rootless podman on Linux, and macOS — so a release is gated on the fleet people actually run rather than the one cell that happens to be easy.

**Architecture:** Scenarios declare the privilege they need in front-matter, the same way they already declare their platform. `run-all.sh` filters on it, which makes a rootless cell honest instead of one that silently skips half its suite. A new container-free scenario pins `dev doctor`'s contract. CI gains a rootless Linux cell and a macOS cell.

**Tech Stack:** bash (macOS 3.2-compatible: no associative arrays, no `${var,,}`, guard empty arrays with `${arr[@]+"${arr[@]}"}`), the scenario suite under `scripts/test/`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-15-host-preflight-matrix-design.md`

This is **increment 2 of 2**. Increment 1 (the check registry and `dev doctor`) has landed; this plan depends on it. The spec's `run-all.sh` buildx-gate item was already fixed as a follow-up (`330c7fb`) and is **not** part of this plan.

## Global Constraints

- **Branch:** execute on `production-prep`. No worktree, no merge to `main` — the owner is holding the branch until org-deploy readiness and all testing happens there.
- **bash 3.2 compatible.** No associative arrays, no `${var,,}`, no `readarray`. Guard empty-array expansion as `${arr[@]+"${arr[@]}"}`.
- **`scripts/lint.sh` must exit 0.** It enforces `dev` ≤ 190 and `lib/dev/*.sh` ≤ 300 (except `agent.sh` ≤ 550), and runs shellcheck, hadolint and actionlint.
- **The Linux matrix baseline is 23 passed / 10 failed / 6 skipped**, the 10 being `kernel.apparmor_restrict_unprivileged_userns=1` blockers on the dev host, deliberately left set. Any *other* failure is a regression. Never report a matrix result without comparing the failure set, not just the tally — a run can hit the same count with a different set.
- **Commits:** unsigned, with identity passed per-commit because this host has no git identity configured:
  `git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' -c commit.gpgsign=false commit -m "..."`
- **NEVER `git push`.**
- **A scenario's message strings are a contract.** Scenarios grep each other's output and `dev`'s; two regressions in increment 1 came from rewording a message whose exact text a scenario matched. Change behaviour freely, change user-facing wording only deliberately.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/test/lib/assert.sh` (modify) | add `scenario_privilege` + `require_privilege`, mirroring the existing `scenario_platform` / `require_platform` pair |
| `scripts/test/scenarios/*.sh` (modify, 39 files) | add a `# privilege:` front-matter line |
| `scripts/test/run-all.sh` (modify) | honour `DEV_TEST_PRIVILEGE`; relax the sudo precondition when running the unprivileged subset |
| `scripts/test/scenarios/51-doctor.sh` (new) | `dev doctor`'s contract, container-free |
| `scripts/test/run-rootless.sh` (new) | thin entry point: the `user` subset under rootless podman, no sudo |
| `.github/workflows/ci.yml` (modify) | add the rootless Linux cell and the macOS cell |
| `docs/ci-testing.md`, `CLAUDE.md` (modify) | document both new cells and the privilege axis |

---

### Task 1: `privilege:` front-matter and its helpers

**Files:**
- Modify: `scripts/test/lib/assert.sh` (add beside `scenario_platform`, currently at lines 62-69, and `require_platform`, lines 71-83)
- Test: `scripts/test/unit/test-scenario-privilege.sh` (create)

**Interfaces:**
- Produces: `scenario_privilege()` → prints `root` / `user` / `any` (default `any` when the tag is absent); `require_privilege <want>` → `log_skip` + `exit 0` when the current run cannot satisfy it.

- [x] **Step 1: Write the failing test**

Create `scripts/test/unit/test-scenario-privilege.sh`:

```bash
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

mk s-root.sh  '# privilege: root' 'echo "PRIV=$(scenario_privilege)"'
mk s-user.sh  '# privilege: user' 'echo "PRIV=$(scenario_privilege)"'
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
```

- [x] **Step 2: Run it — must fail**

Run: `bash scripts/test/unit/test-scenario-privilege.sh`
Expected: `FAIL: scenario_privilege not defined`

- [x] **Step 3: Implement, in `scripts/test/lib/assert.sh` immediately after `require_platform`**

```bash
# Read scenario front-matter privilege tag. Returns "root" / "user" / "any".
# "root" means the scenario manipulates HOST state — sysctls, AppArmor
# profiles, package installs, device nodes — and cannot run in a cell that has
# no sudo. "user" means it needs only a working runtime.
scenario_privilege() {
    local f="${BASH_SOURCE[1]}"
    local tag
    tag=$(awk '/^# privilege:/{print $3; exit}' "$f" 2>/dev/null)
    echo "${tag:-any}"
}

# Skip the scenario when the current run cannot grant what it needs.
# DEV_TEST_PRIVILEGE is set by the orchestrator: "root" (the default sudo
# invocation) runs everything; "user" runs only what needs no host changes.
# Unset means "run everything", so existing invocations are unaffected.
require_privilege() {
    local want="$1"
    local have="${DEV_TEST_PRIVILEGE:-root}"
    case "$want" in
        root)
            [[ "$have" == root ]] || {
                log_skip "scenario needs host privileges (run is $have)"; exit 0; } ;;
        user|any) : ;;
        *) log_fail "unknown privilege tag: $want"; exit 1 ;;
    esac
}
```

- [x] **Step 4: Run it — must pass**

Run: `bash scripts/test/unit/test-scenario-privilege.sh`
Expected: `PASS: scenario privilege tag and guard`

- [x] **Step 5: Commit**

```bash
mise x shellcheck -- shellcheck -x scripts/test/lib/assert.sh scripts/test/unit/test-scenario-privilege.sh
bash scripts/lint.sh
git add scripts/test/lib/assert.sh scripts/test/unit/test-scenario-privilege.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "test: add a privilege tag to the scenario front-matter"
```

---

### Task 2: Tag all 39 scenarios

**Files:**
- Modify: every `scripts/test/scenarios/[0-9]*.sh` (39 files)

This is mechanical. Do it as one batch, not one commit per file.

**These seven shell out to `sudo` and are therefore `# privilege: root`:**

```
02-host-podman-noshim.sh      11-userns-clone-disabled.sh
12-fuse-missing.sh            13-apparmor-enforcing.sh
15-apparmor-userns-restrict.sh  30-attack-sudo-iptables.sh
32-attack-host-mount.sh
```

**Everything else is `# privilege: user`** — but verify rather than assume, see Step 2.

- [x] **Step 1: Add the tag to every scenario**

Insert `# privilege: <root|user>` immediately after the existing `# platform:` line, so the front-matter block stays together. For a file with no `# platform:` line, put it after the `# scripts/test/scenarios/<name>.sh` comment.

- [x] **Step 2: Verify the classification rather than trusting the grep**

`sudo` in the file is a strong signal but not proof: a scenario can need host privileges without the string appearing (for example by writing to `/proc` or `/etc` directly), and one can mention `sudo` inside a here-doc that never runs on the host.

```bash
# Anything writing host state outside a container is a root scenario.
grep -ln 'sudo \|/proc/sys\|sysctl\|apt-get\|modprobe\|/etc/subuid\|/etc/subgid\|apparmor' \
    scripts/test/scenarios/[0-9]*.sh
```
Reconcile that list against your tags and report any file where the two disagree, with your reasoning.

- [x] **Step 3: Every scenario is tagged, and only with legal values**

```bash
for f in scripts/test/scenarios/[0-9]*.sh; do
  tag=$(awk '/^# privilege:/{print $3; exit}' "$f")
  case "$tag" in root|user) ;; *) echo "UNTAGGED/BAD: $f ($tag)" ;; esac
done
echo "root: $(grep -l '^# privilege: root' scripts/test/scenarios/[0-9]*.sh | wc -l)"
echo "user: $(grep -l '^# privilege: user' scripts/test/scenarios/[0-9]*.sh | wc -l)"
```
Expected: no `UNTAGGED/BAD` lines, and the two counts sum to 39.

- [x] **Step 4: Add the guard call to the root scenarios only**

In each of the seven `privilege: root` scenarios, add `require_privilege root` immediately after the existing `require_platform linux` call. `user` scenarios need no call — the tag alone is what the orchestrator filters on, and an unnecessary guard is one more line to drift.

- [x] **Step 5: The suite still behaves identically under the default invocation**

```bash
sudo bash scripts/test/run-all.sh
```
Expected: **23 passed, 10 failed, 6 skipped**, with the failure set exactly `10, 13, 20, 21, 22, 23, 24, 25, 30, 31`. Tagging must change nothing yet — the filter does not exist until Task 3.

- [x] **Step 6: Commit**

```bash
bash scripts/lint.sh
git add scripts/test/scenarios
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "test: tag every scenario with the privilege it needs"
```

---

### Task 3: `run-all.sh` honours the privilege filter

**Files:**
- Modify: `scripts/test/run-all.sh` — the sudo precondition (currently lines 64-67), `drop_privs_if_root` (line 34), and the scenario loop (line 164)

**Interfaces:**
- Consumes: `scenario_privilege` from Task 1; the tags from Task 2.
- Produces: `DEV_TEST_PRIVILEGE=user` runs only `privilege: user` scenarios and requires no sudo; unset or `root` behaves exactly as today.

- [x] **Step 1: Make the sudo precondition conditional**

Replace the precondition block:

```bash
# The unprivileged subset manipulates no host state, so it must run without
# sudo — that is the whole point of the rootless cell. Only the full run
# needs it.
if [[ "${DEV_TEST_PRIVILEGE:-root}" == root ]]; then
    if ! sudo -n true 2>/dev/null; then
        echo "FATAL: this orchestrator needs passwordless sudo (or run as root)." | tee -a "$LAST_LOG"
        echo "       For the unprivileged subset instead: DEV_TEST_PRIVILEGE=user bash $0" | tee -a "$LAST_LOG"
        exit 1
    fi
fi
```

- [x] **Step 2: Skip the privilege drop in an unprivileged run**

`drop_privs_if_root` re-execs through `runuser` and needs root to do it. In a `user` run there is nothing to drop. Guard its call:

```bash
if [[ "${DEV_TEST_PRIVILEGE:-root}" == root ]]; then
    drop_privs_if_root "$@"
fi
```

- [x] **Step 3: Filter the scenario loop**

Immediately after `name=$(basename "$scenario" .sh)` inside the loop:

```bash
    # Skip scenarios this run cannot satisfy. The scenario's own
    # require_privilege call would also skip, but filtering here keeps them
    # out of the tally entirely — a cell should report what it ran, not pad
    # its skip count with work it was never going to attempt.
    scen_priv=$(awk '/^# privilege:/{print $3; exit}' "$scenario")
    scen_priv="${scen_priv:-any}"
    if [[ "${DEV_TEST_PRIVILEGE:-root}" != root && "$scen_priv" == root ]]; then
        continue
    fi
```

- [x] **Step 4: Export the variable so scenarios see it**

Near the top, after the log setup:

```bash
# Scenarios read this through require_privilege.
export DEV_TEST_PRIVILEGE="${DEV_TEST_PRIVILEGE:-root}"
```

- [x] **Step 5: Both modes behave**

```bash
# Unchanged default:
sudo bash scripts/test/run-all.sh
# Expected: 23 passed, 10 failed, 6 skipped; failure set 10,13,20,21,22,23,24,25,30,31

# Unprivileged subset, no sudo at all:
DEV_TEST_PRIVILEGE=user bash scripts/test/run-all.sh
# Expected: runs and completes; the seven root scenarios appear nowhere in the
# tally. Record the exact tally — it becomes the rootless baseline in Task 5.
```
The second run may report failures. **Do not fix them here.** Record each one with its cause; they are the coverage this cell exists to add, and Task 5 decides which are real.

- [x] **Step 6: Commit**

```bash
mise x shellcheck -- shellcheck -x scripts/test/run-all.sh
bash scripts/lint.sh
git add scripts/test/run-all.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "test: filter the suite by the privilege a run can grant"
```

---

### Task 4: Scenario 51 — `dev doctor`'s contract

**Files:**
- Create: `scripts/test/scenarios/51-doctor.sh`

Container-free: every check uses `dev doctor` output, exit codes, or `DEV_FAKE_*` stubs. It must not build an image or start a container.

- [x] **Step 1: Write the scenario**

```bash
#!/bin/bash
# scripts/test/scenarios/51-doctor.sh
# platform: linux
# privilege: user
# Contract for the `dev doctor` verb. Container-free: exit codes, report
# shape, and the severity split, all driven through DEV_FAKE_* stubs.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
require_platform linux
require_privilege user

cd "$(dirname "$0")/../../.." || exit 1

fail=0
chk() { # description, expected-exit, grep-pattern, cmd...
    local desc="$1" want_rc="$2" pat="$3"; shift 3
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        log_fail "$desc: expected exit $want_rc, got $rc — output: $out"; fail=1; return
    fi
    if [ -n "$pat" ] && ! echo "$out" | grep -qE "$pat"; then
        log_fail "$desc: output did not match /$pat/ — output: $out"; fail=1; return
    fi
}

# Runs on a bare host and always produces a tally.
chk "doctor reports a tally" 0 '[0-9]+ blocking, [0-9]+ advisory' ./dev doctor

# The header names the host and the runtime it resolved.
chk "doctor names the host"    0 '^Host '    ./dev doctor
chk "doctor names the runtime" 0 '^Runtime ' ./dev doctor

# Usage errors exit 2, matching the verb grammar.
chk "bad flag exits 2" 2 'Usage: dev doctor' ./dev doctor --bogus

# --dind is accepted and promotes the nested checks.
chk "--dind accepted" 0 '[0-9]+ blocking' env DEV_SKIP_APPARMOR_CHECK=1 ./dev doctor --dind

# A blocking failure exits 1 and names the check. buildx is scoped to docker,
# so pin the runtime as well as the probe.
chk "blocking failure exits 1" 1 'buildx' \
    env -u DOCKER_HOST DEV_RUNTIME=docker DEV_FAKE_BUILDX=false ./dev doctor

# The same failure must NOT block dev up: image.sh guards the build site, so
# block-in-doctor is a doctor-only severity. This is the asymmetry the
# severity model exists to express, and it is worth pinning.
chk "block-in-doctor does not block dev up" 0 '' \
    env -u DOCKER_HOST DEV_RUNTIME=docker DEV_FAKE_BUILDX=false ./dev up --dry-run

# An unconfigured host still gets a full report rather than one bare error.
chk "bad DEV_RUNTIME still reports" 1 '[0-9]+ blocking' \
    env DEV_RUNTIME=nosuchruntime ./dev doctor

# Non-tty output is ASCII: this gets pasted into chat.
out=$(./dev doctor 2>&1)
if echo "$out" | LC_ALL=C grep -q '[^ -~]'; then
    log_fail "non-ASCII leaked into non-tty output"; fail=1
fi

[ "$fail" -eq 0 ] || exit 1
log_pass "dev doctor contract: tally, header, exit codes, severity split"
```

- [x] **Step 2: Run it**

Run: `bash scripts/test/scenarios/51-doctor.sh`
Expected: `[PASS] 51-doctor ...`

If the `--dind` case fails on this host, that is the apparmor sysctl: the `DEV_SKIP_APPARMOR_CHECK=1` above exists for exactly that. If it still fails, report what you saw rather than weakening the assertion.

- [x] **Step 3: It runs in both modes**

```bash
DEV_TEST_PRIVILEGE=user bash scripts/test/run-all.sh 2>&1 | grep 51-doctor
sudo bash scripts/test/run-all.sh 2>&1 | grep 51-doctor
```
Expected: present and passing in both.

- [x] **Step 4: Commit**

```bash
bash scripts/lint.sh
git add scripts/test/scenarios/51-doctor.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "test: pin the dev doctor contract in a container-free scenario"
```

---

### Task 5: The rootless-podman cell

**Files:**
- Create: `scripts/test/run-rootless.sh`

**Interfaces:**
- Consumes: `DEV_TEST_PRIVILEGE=user` from Task 3.

This is the cell that covers the repo owner's daily driver, and the one no cell has ever covered. Expect it to find things.

- [x] **Step 1: Write the entry point**

```bash
#!/usr/bin/env bash
# scripts/test/run-rootless.sh — the unprivileged subset under rootless
# podman, with no sudo anywhere.
#
# Why this exists: run-all.sh requires passwordless sudo and drops privileges
# through runuser, so every cell it produces is ROOTFUL. The project's own
# recommended setup on Linux is ROOTLESS podman, and until this cell existed
# nothing tested it — which is how scenarios 41-44 and 46 were able to rot
# undetected under a runtime nobody exercised.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if ! command -v podman >/dev/null 2>&1; then
    echo "FATAL: podman is required for the rootless cell." >&2
    exit 1
fi
if [[ "$(id -u)" -eq 0 ]]; then
    echo "FATAL: run this as your normal user — the point is that it needs no root." >&2
    exit 1
fi
if [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" != "true" ]]; then
    echo "FATAL: podman here is not rootless; this cell would duplicate the rootful one." >&2
    exit 1
fi

export DEV_RUNTIME=podman
export DEV_TEST_PRIVILEGE=user
exec bash scripts/test/run-all.sh "$@"
```

- [x] **Step 2: Run it and record what it finds**

```bash
chmod +x scripts/test/run-rootless.sh
bash scripts/test/run-rootless.sh
```

Record the tally AND the failure set. This is new coverage, so failures are expected and are the point.

- [x] **Step 3: Triage every failure — do not fix blindly**

For each failing scenario, decide and write down which it is:
1. **A real bug in `dev` under rootless podman** — the cell is doing its job. Fix it if the fix is contained; otherwise record it precisely and move on.
2. **A scenario that assumes rootful behaviour** — for example expecting an image label the rootless path sets differently. Fix the scenario.
3. **A genuine environment limit** — record it as an expected failure for this cell, the way the apparmor blockers are for the rootful one.

Known suspects from an earlier ad-hoc podman run: scenarios **41, 42, 43, 44, 46** failed with image-label and rebuild-detection errors, confirmed pre-existing rather than caused by any change. Start there, and note that run was *rootful* podman — under *rootless* they may behave differently.

- [x] **Step 4: Establish the documented baseline**

Once every failure is triaged, run it twice and confirm the failure set is identical both times. A cell whose failures move between runs is not a baseline — investigate the instability before recording anything.

Write the final tally and failure set into `docs/ci-testing.md` in Task 7.

- [x] **Step 5: Commit**

```bash
bash scripts/lint.sh
git add scripts/test/run-rootless.sh
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "test: add the rootless-podman cell"
```

---

### Task 6: CI cells for rootless Linux and macOS

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] **Step 1: Add the rootless Linux job**

After the existing `vm-matrix` job:

```yaml
  rootless-linux:
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4

      - name: Install podman
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends podman uidmap

      - name: Confirm podman is rootless here
        run: |
          podman info --format '{{.Host.Security.Rootless}}'
          id -u

      - name: Run the unprivileged subset under rootless podman
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash scripts/test/run-rootless.sh

      - name: Upload logs
        if: always()
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: logs-rootless-linux
          path: |
            scripts/test/last-run.log
            scripts/test/last-summary.log
          if-no-files-found: ignore
```

- [x] **Step 2: Add the macOS job**

GitHub's macOS runners are themselves VMs with no nested virtualization, so `podman machine` cannot start there — confirmed on 2026-08-15 (`vfkit exited unexpectedly`). This cell therefore runs no containers: it verifies the logic that can be verified, which is the unit suite and `dev doctor`.

```yaml
  macos-checks:
    runs-on: macos-14
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4

      - name: Unit suite
        run: |
          fails=0
          for t in scripts/test/unit/*.sh; do
            n=$(basename "$t" .sh)
            [ "$n" = "test-runner" ] && continue
            if bash "$t" >/tmp/"$n".log 2>&1; then
              echo "PASS $n"
            else
              echo "FAIL $n"; sed -n '1,20p' /tmp/"$n".log; fails=$((fails+1))
            fi
          done
          echo "unit failures: $fails"
          [ "$fails" -eq 0 ]

      - name: dev doctor runs on a bare Mac
        # No podman, no machine, no image. Doctor's whole promise is that it
        # still reports. Exit 1 is legitimate here (it will flag the missing
        # runtime); a crash, a hang, or an empty report is not.
        run: |
          set +e
          out=$(./dev doctor 2>&1); rc=$?
          set -e
          echo "$out"
          echo "exit=$rc"
          [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || { echo "doctor exited $rc"; exit 1; }
          echo "$out" | grep -qE '[0-9]+ blocking' || { echo "no tally — doctor bailed"; exit 1; }
```

- [x] **Step 3: Add both to the required-jobs gate**

The `ci` job at the end of the file lists its dependencies. Extend it:

```yaml
    needs: [lint, vm-matrix, rootless-linux, macos-checks]
```

- [x] **Step 4: Validate**

```bash
mise x actionlint -- actionlint .github/workflows/ci.yml
bash scripts/lint.sh
```
Expected: both clean.

You cannot run these jobs locally. **Do not claim they pass.** Say explicitly in your report that they are unverified until pushed, and that `test-cli-invalid-distro` needs qemu and may fail on the macOS runner — check whether that scenario is in the unit directory and whether the macOS job will therefore go red on a pre-existing condition. If it will, deal with it deliberately rather than letting the cell start life red.

- [x] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "ci: add rootless-linux and macos cells"
```

---

### Task 7: Documentation

**Files:**
- Modify: `docs/ci-testing.md`, `CLAUDE.md` (its `## Tests` section)

- [x] **Step 1: Document the privilege axis and both cells in `docs/ci-testing.md`**

Add a section covering: what the `# privilege:` tag means and its two values; how to run each cell (`sudo bash scripts/test/run-all.sh`, `bash scripts/test/run-rootless.sh`); the documented baseline for each, as a tally **and** a failure set; and the fact that the macOS cell runs no containers, with the reason (GitHub's macOS runners have no nested virtualization, confirmed 2026-08-15).

- [x] **Step 2: Update `CLAUDE.md`'s Tests section**

It currently describes only `sudo bash scripts/test/run-all.sh`. Add the rootless entry point and the privilege tag, matching the file's dense factual register — short declaratives, real commands, no adjectives.

- [x] **Step 3: Verify every command you documented actually runs**

Paste the output. A doc claiming a command that does not work is worse than no doc.

- [x] **Step 4: Commit**

```bash
bash scripts/lint.sh
git add docs/ci-testing.md CLAUDE.md
git -c user.name='Jakob Langdal' -c user.email='jakob@langdal.dk' \
    -c commit.gpgsign=false commit -m "docs: document the privilege axis and the two new cells"
```

---

## Increment 2 complete

The suite then covers rootful docker (three distros), rootless podman, and macOS logic. What it still does not cover is macOS *integration* — no CI runner can, so the manual Apple Silicon session remains release gate 4 and the only real-hardware evidence.
