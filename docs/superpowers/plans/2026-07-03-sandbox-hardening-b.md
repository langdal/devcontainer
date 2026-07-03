# Sandbox Hardening Area B — Per-Workspace Home Volume — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the container home volume per-workspace (`devcontainer-home-<dir>`) by default so SSH keys, git creds, and shell history from one project are not exposed to the agent in another; keep `devcontainer-mise`/`devcontainer-dind` shared; offer `DEV_SHARED_HOME=1` to keep the legacy single home; and seed git identity from the host so the isolated home isn't a fresh-setup burden.

**Architecture:** Resolve the home volume name once (a `_resolve_home_volume` helper feeding a `HOME_VOLUME` global) and thread it through the four places that reference the home volume literally (start mount, keep-id migration, reset, rebuild-cleanup + its prompt text). Add a one-time migration note. Separately, `dev` reads the host's git `user.name`/`user.email` and passes them as env vars that `entrypoint.sh` seeds into `~/.gitconfig` only when unset. Layered on the area-D module structure (base commit 0d3c72b on branch `feature/sandbox-cli-home`).

**Tech Stack:** bash (`dev` + `lib/dev/lifecycle.sh` + `lib/dev/image.sh` + `entrypoint.sh`), Docker/podman, the repo's scenario + unit test harness.

## Global Constraints

- `dev` runs under `set -euo pipefail`; new code must be errexit-safe. Host code runs on Linux **and** macOS (no GNU-only flags host-side).
- `bash scripts/lint.sh` must exit 0 before **every** commit (pinned shellcheck 0.11.0 + hadolint + actionlint). New cross-module globals that per-file shellcheck sees as unused need a justified `# shellcheck disable=SC2034  # consumed by <fn> in lib/dev/<module>.sh` — the established pattern in this codebase.
- Conventional Commits; agent commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. GPG has no key here — commit with `git -c commit.gpgsign=false commit …`. **NEVER `git push`.**
- **Do NOT touch, revert, stage, or commit `allowlist.base`** — it has an unrelated uncommitted user edit. Use explicit `git add <paths>`, never `git add -A`.
- **Environment limitation:** nested-rootless dind devcontainer. `./dev --dind` and the sudo full matrix cannot run here. Verification surface: `bash scripts/lint.sh`, `bash scripts/test/unit/test-runner.sh` (only `test-cli-invalid-distro` fails — environmental, unrelated), and `./dev … --dry-run` (prints the docker command incl. `-v` mounts and `-e` env without starting a container). Reference dry-run snapshots are in `/tmp/dev-refsnap/` but **note: this plan intentionally CHANGES the start.txt/start-ports.txt command** (the home mount name changes), so re-capture those snapshots after Task 1 (the tasks say when). The **full matrix on a real host is the merge gate.**
- Spec of record: `docs/superpowers/specs/2026-07-03-sandbox-hardening-design.md`, section B. Exact naming: default home volume `devcontainer-home-<WORKSPACE_BASENAME>` (basename only — matches the `dev-<dir>` container-name convention and inherits its documented basename-collision caveat; NOT the state-dir's basename-hash form). `DEV_SHARED_HOME=1` selects the legacy name `devcontainer-home`. `devcontainer-mise` and `devcontainer-dind` stay shared (unchanged). Git identity env var names: `DEV_GIT_NAME`, `DEV_GIT_EMAIL`.

## Current state (area-D module layout, base 0d3c72b)

Home-volume references to thread (verified locations; confirm by grep, they may shift as you edit):
- `lib/dev/lifecycle.sh:263` — `DOCKER_CMD+=(-v devcontainer-home:/home/vscode)` (start mount, in `start_container`)
- `lib/dev/lifecycle.sh:273` — `migrate_volume_for_keepid devcontainer-home` (keep-id migration, in `start_container`)
- `lib/dev/lifecycle.sh:74` — `for v in devcontainer-mise devcontainer-home; do` (reset volume list, in `reset_workspace`)
- `lib/dev/image.sh:55` — `local vols=(devcontainer-mise devcontainer-home)` (rebuild cleanup, in `cleanup_for_rebuild`)
- `lib/dev/image.sh:113` — `local vol_list="devcontainer-mise, devcontainer-home"` (UID-mismatch prompt text, in `check_image_uid_match`)

Name resolution happens in two spots (a pre-existing duplication — do NOT refactor it away in area B): `_resolve_workspace_names()` at `dev:466-473` (used by the `reset`/`fw` management paths) and an inline block at `dev:720-721` (the default start path). Both set `WORKSPACE_BASENAME`/`NORMAL_NAME`/…. `migrate_volume_for_keepid` (`lib/dev/lifecycle.sh:183`) already takes a volume name as `$1`. `entrypoint.sh`'s vscode-context block runs `git config --global --add safe.directory /workspace` (~`entrypoint.sh:100`) inside a `gosu vscode bash <<'INNER'` heredoc.

---

### Task 1: Resolve `HOME_VOLUME`; use it for the start mount + keep-id migration + migration note

**Files:**
- Modify: `dev` (add `_resolve_home_volume` helper; call it wherever `WORKSPACE_BASENAME` is set — both `_resolve_workspace_names` and the inline start block; add the one-time migration note in the start path)
- Modify: `lib/dev/lifecycle.sh` (start mount + migrate call use `$HOME_VOLUME`)
- Test: `scripts/test/unit/test-dev-home-volume.sh` (create)

**Interfaces:**
- Produces: global `HOME_VOLUME` (set by `_resolve_home_volume`: `devcontainer-home` when `DEV_SHARED_HOME=1`, else `devcontainer-home-$WORKSPACE_BASENAME`). Consumed by `start_container` (Task 1), `reset_workspace` + `cleanup_for_rebuild` + the UID prompt (Task 2).

- [ ] **Step 1: Write the failing unit test**

Create `scripts/test/unit/test-dev-home-volume.sh`:

```bash
#!/usr/bin/env bash
# Unit: per-workspace home volume name in the dry-run docker command.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "no container runtime on PATH"; exit 1; }
WORK=$(mktemp -d); mkdir -p "$WORK/myproj"; trap 'rm -rf "$WORK"' EXIT
dev() { (cd "$WORK/myproj" && env "$@" "$ROOT/dev" --dry-run -- echo hi </dev/null 2>&1); }

# 1. Default: per-workspace home volume named after the dir basename.
out=$(dev)
echo "$out" | grep -q -- '-v devcontainer-home-myproj:/home/vscode' \
    || { echo "default home volume not per-workspace: $out"; exit 1; }
# mise + (no dind here) stay shared/unchanged.
echo "$out" | grep -q -- '-v devcontainer-mise:/mise' \
    || { echo "mise volume changed unexpectedly: $out"; exit 1; }

# 2. DEV_SHARED_HOME=1 selects the legacy shared name.
out=$(dev DEV_SHARED_HOME=1)
echo "$out" | grep -q -- '-v devcontainer-home:/home/vscode' \
    || { echo "DEV_SHARED_HOME did not select legacy name: $out"; exit 1; }
echo "$out" | grep -q -- '-v devcontainer-home-myproj:/home/vscode' \
    && { echo "DEV_SHARED_HOME still used per-workspace name: $out"; exit 1; }

echo ok
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash scripts/test/unit/test-dev-home-volume.sh`
Expected: FAIL at check 1 (`default home volume not per-workspace`) — dev still mounts `devcontainer-home`.

- [ ] **Step 3: Add `_resolve_home_volume` and set `HOME_VOLUME`**

In `dev`, add the helper (place it near `_resolve_workspace_names`):

```bash
# Resolve the home volume name. Per-workspace by default so one project's
# SSH keys / git creds / shell history are not exposed to the agent in
# another project's container. DEV_SHARED_HOME=1 keeps the legacy single
# volume. mise (tool cache) and dind (image cache) stay shared regardless.
# Basename only (matches the dev-<dir> container-name convention and its
# documented basename-collision caveat).
_resolve_home_volume() {
  if [[ "${DEV_SHARED_HOME:-}" == "1" ]]; then
    HOME_VOLUME="devcontainer-home"
  else
    HOME_VOLUME="devcontainer-home-${WORKSPACE_BASENAME}"
  fi
}
```

Call `_resolve_home_volume` immediately after `WORKSPACE_BASENAME` is assigned in **both** places: inside `_resolve_workspace_names` (after `dev:470`) and in the inline start block (after `dev:720`). Add `# shellcheck disable=SC2034  # consumed by start_container/reset_workspace/cleanup_for_rebuild in lib/dev/*.sh` on the `HOME_VOLUME` assignment(s) inside `_resolve_home_volume` if shellcheck flags it (it will — HOME_VOLUME is read only in modules).

- [ ] **Step 4: Use `$HOME_VOLUME` in `lib/dev/lifecycle.sh`**

Change `lib/dev/lifecycle.sh:263`:
```bash
  DOCKER_CMD+=(-v "$HOME_VOLUME":/home/vscode)
```
Change `lib/dev/lifecycle.sh:273`:
```bash
    migrate_volume_for_keepid "$HOME_VOLUME"
```
(The mise and dind mounts/migrations are unchanged.)

- [ ] **Step 5: Add the one-time migration note (start path, in `dev`)**

In the default start path, after `_resolve_home_volume`/name resolution and after `detect_runtime` (so `$RUNTIME` is set), before `start_container`, add:

```bash
# One-time heads-up: isolated home is now the default. If this workspace has
# no per-workspace home volume yet but a legacy shared one exists, the user is
# transitioning — the old volume is left untouched.
if [[ "$DRY_RUN" != true && "${DEV_SHARED_HOME:-}" != "1" ]] \
   && ! $RUNTIME $RUNTIME_ARGS volume inspect "$HOME_VOLUME" >/dev/null 2>&1 \
   && $RUNTIME $RUNTIME_ARGS volume inspect devcontainer-home >/dev/null 2>&1; then
  echo "Note: dev now uses a per-workspace home volume ($HOME_VOLUME) by default." >&2
  echo "      Your old shared 'devcontainer-home' volume is untouched; set" >&2
  echo "      DEV_SHARED_HOME=1 to keep using it for this workspace." >&2
fi
```
Add `# shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS` above each `$RUNTIME $RUNTIME_ARGS` line if lint flags it.

- [ ] **Step 6: Re-capture the changed dry-run snapshots, then verify**

The home mount name legitimately changed, so refresh the reference snapshots (from a real workspace dir — use the repo root, basename `workspace`):
```bash
./dev --dry-run -- echo hi > /tmp/dev-refsnap/start.txt 2>&1 || true
./dev --dry-run --default-ports --port 9000 --host-port 8080 -- echo hi > /tmp/dev-refsnap/start-ports.txt 2>&1 || true
```
Then:
```bash
bash scripts/test/unit/test-dev-home-volume.sh          # ok
bash scripts/test/unit/test-runner.sh                    # only test-cli-invalid-distro fails
bash scripts/lint.sh                                     # exit 0
./dev --dry-run -- echo hi 2>&1 | grep -- '-v devcontainer-home-workspace:/home/vscode'   # confirms new default
```
Expected: test `ok`; unit runner clean; lint 0; the grep matches.

- [ ] **Step 7: Commit**

```bash
git add dev lib/dev/lifecycle.sh scripts/test/unit/test-dev-home-volume.sh
git -c commit.gpgsign=false commit -m "feat(dev): per-workspace home volume by default (DEV_SHARED_HOME to opt out)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Thread `HOME_VOLUME` through reset, rebuild-cleanup, and the UID prompt

**Files:**
- Modify: `lib/dev/lifecycle.sh` (`reset_workspace` volume list)
- Modify: `lib/dev/image.sh` (`cleanup_for_rebuild` vols + `check_image_uid_match` prompt text)

**Interfaces:**
- Consumes: `HOME_VOLUME` (Task 1). Both `reset_workspace` and `cleanup_for_rebuild` run after name resolution (reset path calls `_resolve_workspace_names`; start path sets names inline), so `HOME_VOLUME` is set before either runs.

- [ ] **Step 1: `reset_workspace` uses `$HOME_VOLUME`**

In `lib/dev/lifecycle.sh:74`, the loop currently iterates literal names. Change it so the home volume is the resolved one:
```bash
  for v in devcontainer-mise "$HOME_VOLUME"; do
```
(Leave the `devcontainer-dind` handling below it unchanged.)

- [ ] **Step 2: `cleanup_for_rebuild` uses `$HOME_VOLUME`**

In `lib/dev/image.sh:55`:
```bash
  local vols=(devcontainer-mise "$HOME_VOLUME")
```

- [ ] **Step 3: UID-mismatch prompt text names the resolved volume**

In `lib/dev/image.sh:113`:
```bash
  local vol_list="devcontainer-mise, $HOME_VOLUME"
```
(The `devcontainer-dind` append on the next line stays.)

- [ ] **Step 4: Verify**

```bash
bash scripts/lint.sh                                     # exit 0 (add SC2154/SC2086 disables only if newly flagged)
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
./dev reset --dry-run </dev/null 2>&1 | head -3          # runs without unbound-var error
bash scripts/test/unit/test-dev-home-volume.sh           # still ok
bash scripts/test/unit/test-runner.sh 2>&1 | tail -2     # only test-cli-invalid-distro fails
```
Note: `image.sh` reads `$HOME_VOLUME` which is assigned in `dev`; if shellcheck flags SC2154 (referenced-but-unassigned) in image.sh, that's not expected for in-function refs — but if it appears, add `# shellcheck disable=SC2154` with a comment. Report if it happens.
Expected: lint 0; START-OK; reset dry-run clean; tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/dev/lifecycle.sh lib/dev/image.sh
git -c commit.gpgsign=false commit -m "feat(dev): thread per-workspace home volume through reset and rebuild

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Seed git identity from the host

**Files:**
- Modify: `dev` (read host git identity, pass as `DEV_GIT_NAME`/`DEV_GIT_EMAIL` in `start_container`'s env)
- Modify: `lib/dev/lifecycle.sh` (`start_container` adds the `-e` flags when set)
- Modify: `entrypoint.sh` (seed `~/.gitconfig` from those env vars when no identity is set)
- Test: extend `scripts/test/unit/test-dev-home-volume.sh` (dry-run shows the `-e` flags when host has identity)

**Interfaces:**
- Consumes: nothing from Task 2.
- Produces: `DEV_GIT_NAME`/`DEV_GIT_EMAIL` env in the container; entrypoint seeds `~/.gitconfig` only when `git config user.name`/`user.email` are unset (never overwrites an existing identity, e.g. one already on a shared or persisted home volume).

- [ ] **Step 1: Add the failing check to the home-volume unit test**

Append to `scripts/test/unit/test-dev-home-volume.sh` before the final `echo ok`:

```bash
# 3. Host git identity is forwarded as DEV_GIT_NAME/DEV_GIT_EMAIL env when set.
# Use a throwaway $HOME with a known gitconfig so the assertion is
# deterministic and independent of the sandbox's real git identity.
out=$( cd "$WORK/myproj" && HOME="$WORK/fakehome" bash -c '
    mkdir -p "$HOME"
    git config --global user.name "Test User"
    git config --global user.email "t@example.com"
    "'"$ROOT"'/dev" --dry-run -- echo hi </dev/null 2>&1' )
echo "$out" | grep -q -- '-e DEV_GIT_NAME' \
    || { echo "git name not forwarded: $out"; exit 1; }
echo "$out" | grep -q -- '-e DEV_GIT_EMAIL' \
    || { echo "git email not forwarded: $out"; exit 1; }
```

Note: `dev` reads the identity with `git config --get user.name`/`user.email` (global scope, which honors `$HOME`). The dry-run prints the command via `${DOCKER_CMD[*]}`, so a value with spaces ("Test User") still appears after `-e DEV_GIT_NAME=`; the grep matches the flag regardless of value.

- [ ] **Step 2: Run it, verify the new checks fail**

Run: `bash scripts/test/unit/test-dev-home-volume.sh`
Expected: FAIL at `git name not forwarded` (dev doesn't read/forward identity yet). Checks 1-2 still pass.

- [ ] **Step 3: Read host identity in `dev`**

In `dev`, near the other host-identity reads (where `HOST_UID`/`HOST_GID` are set in the start path), add:

```bash
# Read the host's git identity so a fresh per-workspace home volume gets a
# usable identity without manual setup. Empty when the host has none; the
# entrypoint only seeds these when the container has no identity yet.
DEV_GIT_NAME="$(git config --get user.name 2>/dev/null || true)"
DEV_GIT_EMAIL="$(git config --get user.email 2>/dev/null || true)"
```
Add `# shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh` on each if flagged.

- [ ] **Step 4: Pass them in `start_container`**

In `lib/dev/lifecycle.sh` `start_container`, near the `GITHUB_TOKEN` passthrough (`-e GITHUB_TOKEN`), add:

```bash
  if [[ -n "${DEV_GIT_NAME:-}" ]]; then
    DOCKER_CMD+=(-e "DEV_GIT_NAME=$DEV_GIT_NAME")
  fi
  if [[ -n "${DEV_GIT_EMAIL:-}" ]]; then
    DOCKER_CMD+=(-e "DEV_GIT_EMAIL=$DEV_GIT_EMAIL")
  fi
```

- [ ] **Step 5: Seed in `entrypoint.sh`**

In `entrypoint.sh`, inside the `gosu vscode bash <<'INNER'` block, next to the existing `git config --global --add safe.directory /workspace`, add (the heredoc is single-quoted so `$DEV_GIT_NAME` would NOT expand — pass the values through the environment instead: they're exported into the gosu child because `entrypoint.sh` received them as container env from the `-e` flags, and `gosu vscode bash` inherits the process environment):

```bash
# Seed git identity from the host ONLY if the container has none yet (never
# clobber an identity already present on a persisted/shared home volume).
if [ -n "${DEV_GIT_NAME:-}" ] && [ -z "$(git config --global user.name || true)" ]; then
    git config --global user.name "$DEV_GIT_NAME"
fi
if [ -n "${DEV_GIT_EMAIL:-}" ] && [ -z "$(git config --global user.email || true)" ]; then
    git config --global user.email "$DEV_GIT_EMAIL"
fi
```
Verify the `INNER` heredoc's quoting: it is `<<'INNER'` (literal), so these `$DEV_GIT_NAME` refs are evaluated at container runtime by the vscode shell reading its inherited env — correct. Confirm `gosu vscode bash` passes the environment through (it does by default; the existing block already relies on inherited env like `PATH`/`mise`).

- [ ] **Step 6: Verify**

```bash
bash scripts/test/unit/test-dev-home-volume.sh           # ok (all 3 checks)
bash scripts/lint.sh                                     # exit 0
# Rebuild so the entrypoint change is baked in, then confirm seeding end-to-end
# in NORMAL mode (works in this env; --dind does not):
DEV_ASSUME_YES=1 ./dev --build -- true
docker rm -f dev-workspace 2>/dev/null
# Fresh per-workspace home volume + host identity → container gets it:
./dev -- bash -lc 'git config --global user.name; git config --global user.email'
```
Expected: unit test ok; lint 0; the last command prints the host's name/email (seeded because the fresh per-workspace home had none). If the host running the test has no git identity, set one first or note it. Also verify non-clobber: run `./dev -- git config --global user.name "Keep Me"` then `./dev -- ...` again and confirm it stays `Keep Me` (entrypoint doesn't overwrite).

- [ ] **Step 7: Commit**

```bash
git add dev lib/dev/lifecycle.sh entrypoint.sh scripts/test/unit/test-dev-home-volume.sh
git -c commit.gpgsign=false commit -m "feat(dev): seed container git identity from host when unset

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Docs + scenarios

**Files:**
- Modify: `README.md` (Persistence section; add DEV_SHARED_HOME + ssh-agent opt-in note), `CLAUDE.md` (volumes design decision + env var), `dev` `usage()` (DEV_SHARED_HOME in ENVIRONMENT)
- Modify: `scripts/test/scenarios/22-cold-start-budget.sh` (assert git identity seeding + non-clobber)
- Create: `scripts/test/scenarios/47-home-volume-isolation.sh` (two workspaces → distinct home volumes; DEV_SHARED_HOME reuses legacy)
- Modify: UID-mismatch scenarios `40-44` if they hardcode `devcontainer-home` (grep to confirm)

**Interfaces:** Consumes the Task 1-3 behavior. Produces nothing downstream.

- [ ] **Step 1: README**

In the "Persistence" section, update the volume list to explain the per-workspace home default: `devcontainer-home-<dir>` (per-workspace, isolates SSH keys/git creds/history), `devcontainer-mise` (shared tool cache), `devcontainer-dind` (shared image cache). Document `DEV_SHARED_HOME=1` (keep the legacy single `devcontainer-home`). Add a short "Pushing from inside a container" note: git identity is seeded from the host automatically; SSH keys are deliberately NOT shared — for push-from-inside, mount an ssh-agent socket or a per-project deploy key via `DEV_EXTRA_RUN_ARGS` (give a one-line example, e.g. `DEV_EXTRA_RUN_ARGS="-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent"`).

- [ ] **Step 2: CLAUDE.md**

Update the "Two named Docker volumes" / "Key Design Decisions" bullet(s) to reflect: home volume is now per-workspace (`devcontainer-home-<dir>`) by default; mise + dind shared; `DEV_SHARED_HOME=1` opt-out; git identity seeded from host. Add `DEV_SHARED_HOME=1` to the env-var list.

- [ ] **Step 3: usage()**

Add to the ENVIRONMENT section in `dev`'s `usage()`:
```
  DEV_SHARED_HOME=1  Use the legacy shared home volume (devcontainer-home) for
                     every workspace instead of the per-workspace default
                     (devcontainer-home-<dir>).
```

- [ ] **Step 4: Cold-start scenario asserts git-identity seeding**

In `scripts/test/scenarios/22-cold-start-budget.sh`, after the container comes up, add an assertion that `git config --global user.name` inside the container is non-empty when the host had an identity (seeded), and that a pre-existing in-container identity is not overwritten on the next start. Read the scenario first; follow its `log_pass`/`log_fail` conventions and its `$RUNTIME`/container-name usage. (This scenario needs a runtime; it runs on the host/CI matrix — write it by inspection, note that in the report.)

- [ ] **Step 5: New isolation scenario**

Create `scripts/test/scenarios/47-home-volume-isolation.sh` (platform: linux). It: makes two temp workspace dirs with distinct basenames, runs `./dev -- true` (or `--dry-run` if a full start is too heavy) in each, and asserts each produced its own `devcontainer-home-<dir>` volume (via `"$RUNTIME" volume ls`), and that `DEV_SHARED_HOME=1 ./dev` reuses `devcontainer-home`. Use the `lib/assert.sh` + `lib/restore.sh` helpers, `remember_volume`/`remember_container` for cleanup, and `$RUNTIME` (from assert.sh). This needs a runtime → runs on the host/CI matrix; write by inspection, note in report. Follow the structure of an existing scenario (e.g. 23-cache-persists-restart.sh) for the volume-inspection idiom.

- [ ] **Step 6: UID-mismatch scenarios**

```bash
grep -rn 'devcontainer-home' scripts/test/scenarios/
```
For any scenario that hardcodes `devcontainer-home` (likely `42-uid-gid-mismatch-rebuild.sh` which does `docker volume create devcontainer-home`, and `44-uid-gid-rebuild-no-volumes.sh`), update to the per-workspace name `devcontainer-home-<dir>` OR set `DEV_SHARED_HOME=1` in that scenario so its `devcontainer-home` assumption holds. Pick whichever keeps the scenario's intent; note the choice. These run on host/CI.

- [ ] **Step 7: Verify**

```bash
bash scripts/lint.sh                                     # exit 0
bash scripts/test/unit/test-runner.sh 2>&1 | tail -2     # only test-cli-invalid-distro fails
./dev --help 2>&1 | grep -q DEV_SHARED_HOME && echo HELP-HAS-ENV
```
Expected: lint 0; unit runner clean; help documents the env var. Note in the report which scenarios (22, 47, 40-44) are verified only on the host/CI matrix.

- [ ] **Step 8: Commit**

```bash
git add README.md CLAUDE.md dev scripts/test/scenarios/
git -c commit.gpgsign=false commit -m "docs(dev): document per-workspace home + git-identity seeding; add isolation scenario

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (after Task 4)

```bash
bash scripts/lint.sh                                     # exit 0
bash scripts/test/unit/test-runner.sh                    # only test-cli-invalid-distro fails
bash scripts/test/unit/test-dev-home-volume.sh           # ok
./dev --dry-run -- echo hi 2>&1 | grep -- '-v devcontainer-home-workspace:/home/vscode'   # per-workspace default
DEV_SHARED_HOME=1 ./dev --dry-run -- echo hi 2>&1 | grep -- '-v devcontainer-home:/home/vscode'  # opt-out
```

**Host/CI matrix must verify (dry-run can't):** git-identity seeding + non-clobber end-to-end (scenario 22); two-workspace home isolation + DEV_SHARED_HOME reuse (scenario 47); UID-mismatch rebuild scenarios (40-44) with the per-workspace name; rootless-podman `migrate_volume_for_keepid "$HOME_VOLUME"` on the renamed volume; the one-time migration note firing when a legacy `devcontainer-home` exists but the per-workspace one doesn't.
