# Sandbox Hardening Area D — CLI Subcommands + Module Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the ~1609-line `dev` script into focused `lib/dev/*.sh` modules and a subcommand CLI (`dev fw …`, `dev reset`, `dev scaffold`, `dev update`, `dev install`, plus the default start path), with every replaced flag kept as a deprecation alias, and the `forbid_companions` machinery + scattered pairwise guards deleted.

**Architecture:** Two phases on one branch. **Phase 1 (Tasks 1–7): behavior-preserving module extraction.** Move the already-function-ized helpers into `lib/dev/*.sh` sourced by `dev`, and wrap the two inline procedural blocks (the preflight checks; the run/attach/start assembly) into functions — each step changes zero observable behavior, verified by `--dry-run` output equality + shellcheck + the existing unit tests. **Phase 2 (Tasks 8–9): the CLI change.** Rewrite the now-thin entry into subcommand dispatch with back-compat aliases, delete the guards, then migrate docs + scenarios to subcommand syntax.

**Tech Stack:** bash (`dev` + `lib/dev/*.sh` + container init scripts), Docker/podman, the repo's scenario + unit test harness under `scripts/test/`.

## Global Constraints

- `dev` runs under `set -euo pipefail`; all code (moved or new) must stay errexit-safe. Moved functions keep their existing `# shellcheck disable=...` directives verbatim.
- Host code runs on Linux **and** macOS: no GNU-only flags in host-side code; sha256 only via the existing `sha256_portable`.
- **Behavior-preservation is the contract for Tasks 1–7.** The only allowed observable change in Phase 1 is internal file layout. `dev --help`, `dev --version`, and every `--dry-run` invocation must produce byte-identical output before and after each task (the tasks give you the exact snapshot commands).
- `bash scripts/lint.sh` must exit 0 before **every** commit (pinned shellcheck 0.11.0 + hadolint + actionlint; run `mise install` in the repo root first if a linter is missing). `scripts/lint.sh` lints `git ls-files` of shell scripts — confirm new `lib/dev/*.sh` files are picked up (see Task 1 Step 6).
- Conventional Commits (`type(scope): subject`, imperative, ≤72 chars). **NEVER `git push`.** Agent commits end with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. GPG signing has no key in this sandbox — commit with `git -c commit.gpgsign=false commit …`.
- **Environment limitation (read before you start):** work happens inside a nested-rootless dind devcontainer. `./dev --dind` **cannot run here** (dev's own rootless-subid preflight refuses in nested rootless), and the sudo-requiring full scenario matrix (`scripts/test/run-all.sh`) cannot run here either. Your verification surface is: `bash scripts/lint.sh`, `bash scripts/test/unit/test-runner.sh` (one pre-existing failure, `test-cli-invalid-distro`, is environmental — missing qemu — and unrelated; everything else must pass), and `./dev … --dry-run` (which runs the whole start path except the final `exec`). The **full matrix on a real non-nested host is the merge gate** and is out of scope for these tasks.
- Spec of record: `docs/superpowers/specs/2026-07-03-sandbox-hardening-design.md`, section D. Deviations must be raised, not silently made.
- Naming from the spec's CLI table is exact and binding: subcommands are `fw disable`, `fw enable`, `fw log`, `fw drops`, `reset`, `scaffold`, `update`, `install`. Alias→subcommand mapping: `--disable-firewall`→`fw disable`, `--enable-firewall`→`fw enable`, `--monitor`→`fw log`, `--monitor-fw`→`fw drops`, `--reset`→`reset`, `--create-dev-container`→`scaffold`, `--self-update`→`update`. Start-path flags (`--dind`, `--maintenance`, `--build`, `--port`, `--host-port`, `--default-ports`, `--dry-run`, `--force`, `-- CMD`) stay as flags on the default command. The three-way container-mode conflict guard (normal/maint/dind) stays.

---

## Phase 1 — Behavior-preserving module extraction

### Establishing snapshots (do this once, before Task 1)

Capture reference `--dry-run` outputs that Tasks 1–7 must reproduce byte-for-byte. Run from the repo root and keep these files out of the tree (they live in the scratch state dir, not the repo):

```bash
SNAP=/tmp/dev-refsnap; mkdir -p "$SNAP"
./dev --help > "$SNAP/help.txt" 2>&1
./dev --version > "$SNAP/version.txt" 2>&1
./dev --dry-run -- echo hi > "$SNAP/start.txt" 2>&1 || true
./dev --dry-run --default-ports --port 9000 --host-port 8080 -- echo hi > "$SNAP/start-ports.txt" 2>&1 || true
./dev --self-update --dry-run > "$SNAP/update.txt" 2>&1 || true
```

`--dind --dry-run` is NOT usable as a snapshot here (the subid preflight aborts before printing), so the preflight task (Task 3) verifies via a Linux-safe path described in that task. Each Phase-1 task re-runs the relevant subset and diffs against `$SNAP`.

---

### Task 1: Create `lib/dev/` and extract `scaffold.sh`

**Files:**
- Create: `lib/dev/scaffold.sh`
- Modify: `dev` (add sourcing block near the top; delete the moved functions)
- Modify: `scripts/lint.sh` (only if it does not already discover `lib/dev/*.sh` — verify first, see Step 6)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the sourcing convention every later module reuses — `dev` sources `"$SCRIPT_DIR"/lib/dev/*.sh` after `SCRIPT_DIR` is resolved and before any dispatch. Functions produced: `write_devcontainer_json_normal`, `write_devcontainer_json_dind`, `create_dev_container` (unchanged signatures; they read the globals `DIND`, `FORCE`, `SCRIPT_DIR`).

- [ ] **Step 1: Add the module-sourcing block to `dev`**

`SCRIPT_DIR` is assigned at `dev:40` (`SCRIPT_DIR="$(resolve_script_dir)"`). Immediately **after** that line, add:

```bash
# Source the dev modules. Split out of this file for readability; they are
# plain function-definition files (no side effects at source time). They live
# next to this script and are found via the symlink-resolved SCRIPT_DIR, so a
# `dev install` symlink on PATH still locates them.
for _mod in "$SCRIPT_DIR"/lib/dev/*.sh; do
  # The glob is literal if the dir is empty/missing; guard so we never source '*.sh'.
  [[ -e "$_mod" ]] || continue
  # shellcheck source=/dev/null
  . "$_mod"
done
unset _mod
```

- [ ] **Step 2: Create `lib/dev/scaffold.sh` with the moved functions**

Create `lib/dev/scaffold.sh` starting with:

```bash
# shellcheck shell=bash
# lib/dev/scaffold.sh — `dev scaffold` (.devcontainer/ generation).
# Sourced by dev; not executed directly.
```

Then move, **verbatim and unchanged**, these three functions from `dev` into this file (current locations): `write_devcontainer_json_normal` (`dev:750-772`), `write_devcontainer_json_dind` (`dev:774-812`), and `create_dev_container` (`dev:814-953`). Preserve every comment and heredoc exactly.

- [ ] **Step 3: Delete the moved functions from `dev`**

Remove `dev:750-953` (the three functions now in `scaffold.sh`). Leave the `if [[ "$CREATE_DC" == true ]]` dispatch block that follows them (it calls `create_dev_container`) exactly where it is — it still resolves because the function is sourced.

- [ ] **Step 4: Verify behavior unchanged**

```bash
bash scripts/lint.sh
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt && echo HELP-OK
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
```
Expected: lint exit 0; `HELP-OK`; `START-OK`.

- [ ] **Step 5: Functional smoke — scaffold still writes files**

```bash
T=$(mktemp -d); (cd "$T" && "$OLDPWD/dev" --create-dev-container >/dev/null 2>&1 || "$PWD/dev" --create-dev-container >/dev/null 2>&1); ls "$T/.devcontainer/" && rm -rf "$T"
```
Simpler and robust: `T=$(mktemp -d); cd "$T"; "$(git -C "$OLDPWD" rev-parse --show-toplevel)/dev" --create-dev-container; ls .devcontainer/; cd - >/dev/null; rm -rf "$T"`.
Expected: `.devcontainer/` contains `devcontainer.json Dockerfile entrypoint.sh firewall-init.sh firewall-disable.sh mise.base.toml allowlist.base`.

- [ ] **Step 6: Confirm the linter covers the new module**

```bash
grep -n 'ls-files\|find\|\*.sh\|shellcheck' scripts/lint.sh | head
```
Read `scripts/lint.sh`. If it enumerates scripts by an explicit list or a path glob that excludes `lib/`, extend it so `lib/dev/*.sh` are linted (they're bash; add them to whatever discovery it uses). If it already lints `git ls-files '*.sh'` or similar, no change is needed — confirm `scripts/lint.sh` output includes a check of `lib/dev/scaffold.sh` (run with `sh -x` or read its logic). Record which case applied in your report.

- [ ] **Step 7: Commit**

```bash
git add dev lib/dev/scaffold.sh scripts/lint.sh
git -c commit.gpgsign=false commit -m "refactor(dev): extract scaffold.sh module

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Extract `update.sh`

**Files:**
- Create: `lib/dev/update.sh`
- Modify: `dev` (delete the moved function)

**Interfaces:**
- Consumes: the sourcing block from Task 1.
- Produces: `self_update` (unchanged; reads globals `SCRIPT_DIR`, `DRY_RUN`).

- [ ] **Step 1: Create `lib/dev/update.sh`**

Header:
```bash
# shellcheck shell=bash
# lib/dev/update.sh — `dev update` (self-update the git checkout to latest tag).
# Sourced by dev; not executed directly.
```
Move `self_update` (`dev:588-648`) into it, verbatim.

- [ ] **Step 2: Delete `self_update` from `dev`** (remove `dev:588-648`). Leave the `if [[ "$SELF_UPDATE" == true ]]` dispatch block that calls it in place.

- [ ] **Step 3: Verify**

```bash
bash scripts/lint.sh
diff <(./dev --self-update --dry-run 2>&1) /tmp/dev-refsnap/update.txt && echo UPDATE-OK
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt && echo HELP-OK
```
Expected: lint 0; `UPDATE-OK`; `HELP-OK`. (`--self-update --dry-run` exercises `self_update` without touching the checkout.)

- [ ] **Step 4: Commit**

```bash
git add dev lib/dev/update.sh
git -c commit.gpgsign=false commit -m "refactor(dev): extract update.sh module

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Extract `preflight.sh` (functions + wrapped inline checks)

**Files:**
- Create: `lib/dev/preflight.sh`
- Modify: `dev` (move functions; wrap three inline blocks into functions and call them)

**Interfaces:**
- Consumes: the sourcing block.
- Produces: `detect_runtime`, `ensure_runtime_ready`, `runtime_is_rootless`, `subid_total` (unchanged), plus three new wrapper functions — `preflight_apparmor_userns` (the AppArmor `--dind` check), `preflight_subid_grant` (the rootless subid check), `refuse_root_uid` (the UID-0 refusal). These set/read the same globals as the inline code they replace (`DIND`, `RUNTIME`, `DIND_MIN_SUBIDS`, `HOST_UID`, `HOST_GID`); `refuse_root_uid` must run after `HOST_UID`/`HOST_GID` are assigned.

- [ ] **Step 1: Create `lib/dev/preflight.sh`**

Header:
```bash
# shellcheck shell=bash
# lib/dev/preflight.sh — host/runtime detection and --dind preflights.
# Sourced by dev; not executed directly.
```
Move verbatim: `detect_runtime` (`dev:45-89`), `ensure_runtime_ready` (`dev:91-101`), `runtime_is_rootless` (`dev:955-967`), `subid_total` (`dev:968-989`).

- [ ] **Step 2: Wrap the AppArmor preflight as a function in `preflight.sh`**

The current inline block is `dev:780-803` (the `if [[ "$DIND" == true && -z "${DEV_SKIP_APPARMOR_CHECK:-}" ]]; then … fi`). Move its body into a function appended to `preflight.sh`, preserving the logic and heredoc verbatim:

```bash
# --dind AppArmor userns preflight (Ubuntu 23.10+/Linux 6.x). No-op unless DIND.
preflight_apparmor_userns() {
  [[ "$DIND" == true && -z "${DEV_SKIP_APPARMOR_CHECK:-}" ]] || return 0
  local _aa_sysfs=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  if [[ -r "$_aa_sysfs" ]] && [[ "$(cat "$_aa_sysfs" 2>/dev/null)" == "1" ]]; then
    cat >&2 <<'EOF'
<the exact heredoc body currently at dev:783-799>
EOF
    exit 1
  fi
}
```
Copy the heredoc body exactly from the current file — do not paraphrase it.

- [ ] **Step 3: Wrap the subid preflight as a function in `preflight.sh`**

The current inline block is `dev:990-1021` (`if [[ "$DIND" == true && "$(uname -s)" == "Linux" && … ]]`). Move its body verbatim into:

```bash
# --dind rootless subuid/subgid grant preflight (Linux rootless runtimes).
preflight_subid_grant() {
  [[ "$DIND" == true && "$(uname -s)" == "Linux" && -z "${DEV_SKIP_SUBID_CHECK:-}" ]] || return 0
  if runtime_is_rootless; then
    <the exact body currently at dev:992-1020, verbatim>
  fi
}
```

- [ ] **Step 4: Wrap the UID-0 refusal as a function in `preflight.sh`**

Current inline block `dev:1028-1031`. Add:
```bash
# Refuse to run as root: the image's vscode user would collide with UID 0.
refuse_root_uid() {
  if [[ "$HOST_UID" == "0" ]]; then
    echo "Error: refusing to run dev as root (UID 0). The image creates a non-root 'vscode' user; using UID 0 would conflict with the image's existing root user." >&2
    exit 1
  fi
}
```

- [ ] **Step 5: Update `dev` to delete the moved code and call the wrappers in the same order**

Delete from `dev`: the function defs now in `preflight.sh` (`detect_runtime`, `ensure_runtime_ready`, `runtime_is_rootless`, `subid_total`) and the three inline blocks. Replace each inline block with a call at the identical position:
- Where the AppArmor block was (before `detect_runtime`/`ensure_runtime_ready` calls at `dev:805-806`): `preflight_apparmor_userns`.
- The existing `detect_runtime` and `ensure_runtime_ready` calls (`dev:805-806`) stay.
- Where the subid block was: `preflight_subid_grant`.
- Where the UID-0 block was (right after `HOST_UID`/`HOST_GID` assignment): replace with `refuse_root_uid`.

Keep the `DIND_MIN_SUBIDS=…` global assignment and the `DIND_RUNTIME_ARGS` resolution in `dev` where they are (they are shared state, not preflight internals) — `preflight_subid_grant` reads `DIND_MIN_SUBIDS` at call time.

- [ ] **Step 6: Verify**

```bash
bash scripts/lint.sh
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt && echo HELP-OK
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
```
Preflight-order check (can't use `--dind` here): confirm the call sites appear in `dev` in the order apparmor → detect_runtime → ensure_runtime_ready → (DIND_RUNTIME_ARGS/IMAGE_TAG resolution) → subid → refuse_root_uid, matching the pre-refactor top-to-bottom order:
```bash
grep -n 'preflight_apparmor_userns\|detect_runtime$\|ensure_runtime_ready$\|preflight_subid_grant\|refuse_root_uid' dev
```
Expected: lint 0; HELP-OK; START-OK; the grep shows the calls in that order.

- [ ] **Step 7: Commit**

```bash
git add dev lib/dev/preflight.sh
git -c commit.gpgsign=false commit -m "refactor(dev): extract preflight.sh module

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Extract `image.sh`

**Files:**
- Create: `lib/dev/image.sh`
- Modify: `dev` (delete moved functions)

**Interfaces:**
- Consumes: sourcing block; `remove_container_if_exists`/`remove_volume_if_exists` (defined in `dev` today, moving to `lifecycle.sh` in Task 5 — cross-module call resolves at runtime regardless of source order).
- Produces: `runtime_build`, `check_image_uid_match`, `check_image_version_match`, `cleanup_for_rebuild` (unchanged; read globals `RUNTIME`, `RUNTIME_ARGS`, `HOST_UID`, `HOST_GID`, `VERSION`, `IMAGE_EXISTS`, `IMAGE_VERSION`, `FORCE_BUILD`, `DRY_RUN`, `DEV_ASSUME_YES`, `CONTAINER_NAME`, `DIND`, `GITHUB_TOKEN`).

- [ ] **Step 1: Create `lib/dev/image.sh`**

Header:
```bash
# shellcheck shell=bash
# lib/dev/image.sh — image build + UID/version label checks + rebuild cleanup.
# Sourced by dev; not executed directly.
```
Move verbatim: `runtime_build` (`dev:103-140`), `cleanup_for_rebuild` (`dev:1250-1268`), `check_image_uid_match` (`dev:1270-1332`), `check_image_version_match` (`dev:1333-…` — the function ending before the DIND/refuse_if_running dispatch; confirm its closing brace by reading it). Preserve all `# shellcheck disable` lines.

- [ ] **Step 2: Delete those functions from `dev`.** The call sites (`check_image_uid_match "$IMAGE_TAG"`, `runtime_build …`, etc.) stay.

- [ ] **Step 3: Verify**

```bash
bash scripts/lint.sh
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt && echo HELP-OK
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
diff <(./dev --dry-run --default-ports --port 9000 --host-port 8080 -- echo hi 2>&1) /tmp/dev-refsnap/start-ports.txt && echo PORTS-OK
```
Expected: lint 0; HELP-OK; START-OK; PORTS-OK. (`--dry-run` runs `check_image_uid_match`/`check_image_version_match` against the local image and prints the same build/run decision.)

- [ ] **Step 4: Commit**

```bash
git add dev lib/dev/image.sh
git -c commit.gpgsign=false commit -m "refactor(dev): extract image.sh module

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Extract `lifecycle.sh` (helpers + reset + managed-container resolution)

**Files:**
- Create: `lib/dev/lifecycle.sh`
- Modify: `dev` (delete moved functions)

**Interfaces:**
- Consumes: sourcing block.
- Produces: `container_running`, `container_exists`, `remove_container_if_exists`, `remove_volume_if_exists`, `reset_workspace`, `resolve_managed_container`, `require_workspace_firewall_container`, `refuse_if_running`, `migrate_volume_for_keepid` (all unchanged). `resolve_managed_container` sets globals `MANAGED_TARGET`/`MANAGED_NAME`/`MANAGED_RUNTIME_ARGS`; Task 7's `fw.sh` consumes those.

- [ ] **Step 1: Create `lib/dev/lifecycle.sh`**

Header:
```bash
# shellcheck shell=bash
# lib/dev/lifecycle.sh — container/volume helpers, reset, managed-container
# resolution, and rootless-podman volume ownership migration.
# Sourced by dev; not executed directly.
```
Move verbatim: `container_running` (`dev:146-149`), `container_exists` (`dev:150-153`), `remove_container_if_exists` (`dev:160-171`), `remove_volume_if_exists` (`dev:172-184`), `reset_workspace` (`dev:1055-…`), `resolve_managed_container` (`dev:1138-1156`), `require_workspace_firewall_container` (`dev:1157-…`), `refuse_if_running` (`dev:1235-1249`), and `migrate_volume_for_keepid` (`dev:1483-…`; read it to get its exact range and closing brace). Preserve all `# shellcheck disable` lines (there are several `SC2086` ones).

- [ ] **Step 2: Delete those functions from `dev`.** All call sites and dispatch blocks that use them stay in `dev`.

- [ ] **Step 3: Verify**

```bash
bash scripts/lint.sh
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt && echo HELP-OK
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
./dev --reset --dry-run 2>&1 | head -5 || true   # composition still validated; no crash
bash scripts/test/unit/test-runner.sh 2>&1 | tail -2
```
Expected: lint 0; HELP-OK; START-OK; `--reset --dry-run` runs without a bash/unbound-var error; unit runner shows only the known `test-cli-invalid-distro` failure.

- [ ] **Step 4: Commit**

```bash
git add dev lib/dev/lifecycle.sh
git -c commit.gpgsign=false commit -m "refactor(dev): extract lifecycle.sh module

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Wrap the run/attach/start assembly into `start_container()`

**Files:**
- Modify: `dev` (wrap the trailing procedural block into a function in `lifecycle.sh`); `lib/dev/lifecycle.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: `start_container` — the function form of the current end-of-file orchestration (TTY detection, attach-vs-create, `DOCKER_CMD` assembly, port/host-port/dind/maint/fw-disabled wiring, and the final `exec`/`--dry-run` print). Reads all the globals the inline code reads today; it must be called as the last statement of `dev`'s start path.

- [ ] **Step 1: Identify the block**

The trailing orchestration runs from the TTY-flags comment (`# Allocate a TTY only when …`, currently ~`dev:1276`) through the final `if [[ "$DRY_RUN" == true ]]; then echo … else exec … fi` at end of file. Read it in full first so the wrap is exact.

- [ ] **Step 2: Move the block into `start_container` in `lifecycle.sh`**

Append to `lib/dev/lifecycle.sh`:
```bash
# Build and run/attach the workspace container. Terminal step of the default
# start path; either exec's into the container or, under --dry-run, prints the
# command. Reads the start-path globals assembled by dev (RUNTIME, RUNTIME_ARGS,
# CONTAINER_NAME, IMAGE_TAG, DIND, MAINTENANCE, DEFAULT_PORTS, EXTRA_PORTS,
# HOST_PORTS, CMD_ARGS, FW_DISABLED_START, DRY_RUN, GITHUB_TOKEN, …).
start_container() {
  <the trailing block, moved verbatim>
}
```
Because the block ends in `exec`/`echo`, wrapping it in a function preserves behavior (the function is the last thing `dev` calls). Keep the `# shellcheck disable=SC2206` on the `DOCKER_CMD=(…)` line.

- [ ] **Step 3: Call it from `dev`**

Where the block used to be (end of the start path, after the image build/`check_image_*` section), put a single call:
```bash
start_container
```

- [ ] **Step 4: Verify byte-identical dry-run command**

```bash
bash scripts/lint.sh
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
diff <(./dev --dry-run --default-ports --port 9000 --host-port 8080 -- echo hi 2>&1) /tmp/dev-refsnap/start-ports.txt && echo PORTS-OK
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt && echo HELP-OK
```
Expected: lint 0; START-OK; PORTS-OK; HELP-OK. This is the highest-value equality check in Phase 1 — the printed `docker run …` line must be identical.

- [ ] **Step 5: Commit**

```bash
git add dev lib/dev/lifecycle.sh
git -c commit.gpgsign=false commit -m "refactor(dev): wrap run/attach assembly into start_container

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Extract `fw.sh` (firewall management handlers)

**Files:**
- Create: `lib/dev/fw.sh`
- Modify: `dev` (convert the monitor/toggle dispatch blocks into functions)

**Interfaces:**
- Consumes: `resolve_managed_container`, `require_workspace_firewall_container` (lifecycle.sh).
- Produces: `fw_log`, `fw_drops`, `fw_enable`, `fw_disable` — each wraps one current dispatch block. `fw_disable` keeps the dual behavior (toggle a running container, else set `FW_DISABLED_START=true` and fall through to a fresh start). Because `fw_disable`'s "else" path must let the caller continue into the start path, it sets the global `FW_DISABLED_START` and returns 0 (rather than exec'ing) in the no-container case; the exec/toggle case still `exec`s. Document this in a comment.

- [ ] **Step 1: Read the current dispatch blocks**

They are: the `--monitor`/`--monitor-fw` block (currently ~`dev:1165-…`, ending in `exec … tail`/`exec … tcpdump`) and the `--disable-firewall`/`--enable-firewall` block (the `FW_DISABLED_START` machinery, ~`dev:1195-…`). Read both fully.

- [ ] **Step 2: Create `lib/dev/fw.sh` with four handlers**

Header:
```bash
# shellcheck shell=bash
# lib/dev/fw.sh — `dev fw` handlers (log, drops, enable, disable).
# Sourced by dev; not executed directly.
```
Define:
- `fw_log`: `require_workspace_firewall_container "fw log"` then `exec $RUNTIME $MANAGED_RUNTIME_ARGS exec -it "$MANAGED_NAME" tail -F /var/log/tinyproxy.log` (the current `--monitor` exec, verbatim).
- `fw_drops`: `require_workspace_firewall_container "fw drops"` then the current `--monitor-fw` `exec … tcpdump -i nflog:1 -nn -l` (verbatim).
- `fw_enable`: `require_workspace_firewall_container "fw enable"` then the current `--enable-firewall` `exec … /usr/local/sbin/firewall-init.sh` (verbatim).
- `fw_disable`: the current `--disable-firewall` logic — `resolve_managed_container`; if `MANAGED_TARGET` is `maint` → error+exit; elif non-empty → `exec … /usr/local/sbin/firewall-disable.sh`; else `FW_DISABLED_START=true` and `return 0` (so the caller continues to a fresh start).

Move the exact command strings and error messages from the current blocks; do not paraphrase. Preserve `# shellcheck disable=SC2086` lines.

- [ ] **Step 3: Replace the dispatch blocks in `dev` with calls**

For now (Phase 1, flags still in force) keep the flag-driven dispatch but route through the functions, e.g. where `--monitor` was handled: `if [[ "$MONITOR" == true ]]; then fw_log; fi`, etc., preserving the existing mutual-exclusion error checks and the `MAINTENANCE` guards that surround them. The `--disable-firewall` no-container path already sets `FW_DISABLED_START` and falls through — keep that flow via `fw_disable`.

- [ ] **Step 4: Verify**

```bash
bash scripts/lint.sh
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt && echo HELP-OK
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
# No firewall container is running here, so these should print the
# "no dev container is running" error and exit non-zero (unchanged behavior):
./dev --monitor 2>&1 | grep -q 'no dev container is running' && echo MONITOR-ERRS-OK
```
Expected: lint 0; HELP-OK; START-OK; MONITOR-ERRS-OK.

- [ ] **Step 5: Commit**

```bash
git add dev lib/dev/fw.sh
git -c commit.gpgsign=false commit -m "refactor(dev): extract fw.sh module

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Phase 2 — Subcommand CLI

### Task 8: Subcommand dispatch + deprecation aliases; delete guards

**Files:**
- Modify: `dev` (replace the top-level flag parser + scattered dispatch with a subcommand router; delete `forbid_companions` and the pairwise guards)
- Test: `scripts/test/unit/test-dev-subcommands.sh` (create)

**Interfaces:**
- Consumes: all module functions (`create_dev_container`, `self_update`, `install_self`, `reset_workspace`, `fw_*`, `start_container`, preflight/image/lifecycle helpers).
- Produces: the final CLI. Deprecation aliases print exactly `Warning: '<oldflag>' is deprecated; use 'dev <subcommand>'.` to stderr, then behave identically to the subcommand.

- [ ] **Step 1: Write the failing unit test**

Create `scripts/test/unit/test-dev-subcommands.sh`:

```bash
#!/usr/bin/env bash
# Unit: dev subcommand dispatch + deprecation aliases (via --dry-run/--help;
# no containers started).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "no container runtime on PATH"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
dev() { (cd "$WORK" && "$ROOT/dev" "$@" </dev/null 2>&1); }

# 1. `update` subcommand == old `--self-update` (dry-run, no checkout here).
out=$(dev update --dry-run); echo "$out" | grep -qiE 'self-update|not a git checkout|latest tag' \
    || { echo "update subcommand not routed: $out"; exit 1; }

# 2. Deprecated alias prints a warning AND still works.
out=$(dev --self-update --dry-run)
echo "$out" | grep -q "deprecated" || { echo "no deprecation warning for --self-update: $out"; exit 1; }
echo "$out" | grep -qiE 'self-update|not a git checkout|latest tag' \
    || { echo "--self-update alias did not run update: $out"; exit 1; }

# 3. `fw log` with no running container == old `--monitor`: same error.
out=$(dev fw log); echo "$out" | grep -q 'no dev container is running' \
    || { echo "fw log not routed: $out"; exit 1; }
out=$(dev --monitor); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --monitor: $out"; exit 1; }

# 4. `scaffold` writes .devcontainer/ (old --create-dev-container).
(cd "$WORK" && "$ROOT/dev" scaffold >/dev/null 2>&1)
[ -f "$WORK/.devcontainer/devcontainer.json" ] || { echo "scaffold did not write files"; exit 1; }
rm -rf "$WORK/.devcontainer"
out=$(dev --create-dev-container --force); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --create-dev-container: $out"; exit 1; }
rm -rf "$WORK/.devcontainer"

# 5. Default command (no subcommand) still starts: --dry-run prints a run command.
out=$(dev --dry-run -- echo hi); echo "$out" | grep -qE 'run .*--rm .*--name' \
    || { echo "default start path broken: $out"; exit 1; }

# 6. Unknown subcommand is an error with guidance.
if dev bogus >/dev/null 2>&1; then echo "unknown subcommand should fail"; exit 1; fi
out=$(dev bogus 2>&1); echo "$out" | grep -qiE 'unknown|usage' || { echo "no guidance on bad subcommand: $out"; exit 1; }

# 7. `reset` composes standalone; a start flag with it is rejected (or ignored
#    per design) — assert it does NOT silently start a container.
out=$(dev reset --dind 2>&1 || true); echo "$out" | grep -qvE 'run .*--rm' || true

# 8. install subcommand still recognized (dry: just don't crash routing).
out=$(dev --help); echo "$out" | grep -qi 'usage' || { echo "help broke: $out"; exit 1; }

echo ok
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash scripts/test/unit/test-dev-subcommands.sh`
Expected: FAIL at check 1 (`update subcommand not routed`) — subcommands don't exist yet.

- [ ] **Step 3: Implement subcommand dispatch in `dev`**

Replace the current top section — the `if [[ ${1:-} == "install" ]]` shortcut (`dev:650-653`), the `while [[ $# -gt 0 ]]` flag parser (`dev:655-748`), and the scattered `if [[ "$CREATE_DC" == true ]]`/`SELF_UPDATE`/mutex/monitor/fw dispatch blocks — with a router. Structure:

```bash
# --- Subcommand router ------------------------------------------------------
# First non-flag token selects a subcommand. Bare flags (or --) fall through
# to the default "start" command. Deprecated flags map to subcommands with a
# one-line warning. Each subcommand parses only its own flags, so invalid
# cross-command combinations are simply unrepresentable — no companion guard.
_deprecated() { echo "Warning: '$1' is deprecated; use 'dev $2'." >&2; }

subcmd=""
case "${1:-}" in
  fw|reset|scaffold|update|install) subcmd="$1"; shift ;;
  --help)       usage; exit 0 ;;
  --version)    echo "dev $(resolve_dev_version)"; exit 0 ;;
  # Deprecated flag aliases -> subcommands. Note the ordering for the fw
  # aliases: shift FIRST to drop the old flag, THEN inject the fw action word,
  # so `dev --monitor` becomes `dev fw log` (not `dev fw log --monitor`).
  --self-update)        _deprecated --self-update "update"; subcmd="update"; shift ;;
  --reset)              _deprecated --reset "reset"; subcmd="reset"; shift ;;
  --create-dev-container) _deprecated --create-dev-container "scaffold"; subcmd="scaffold"; shift ;;
  --monitor)            _deprecated --monitor "fw log"; subcmd="fw"; shift; set -- "log" "$@" ;;
  --monitor-fw)         _deprecated --monitor-fw "fw drops"; subcmd="fw"; shift; set -- "drops" "$@" ;;
  --disable-firewall)   _deprecated --disable-firewall "fw disable"; subcmd="fw"; shift; set -- "disable" "$@" ;;
  --enable-firewall)    _deprecated --enable-firewall "fw enable"; subcmd="fw"; shift; set -- "enable" "$@" ;;
esac
```

Then dispatch on `$subcmd`. Every handler except the default command and the
`fw disable`-with-no-container case terminates the script itself (via `exit`
or `exec`); only those two reach the start path below the dispatch:
- `install` → `install_self; exit 0`.
- `update` → parse only `--dry-run` (set `DRY_RUN=true`); reject unknown flags with an error naming `dev update`; then `self_update; exit 0`.
- `reset` → reject any flags (standalone); resolve runtime + names as `reset_workspace` needs (call `detect_runtime`, set `WORKSPACE_BASENAME`/names/`DIND_RUNTIME_ARGS`), then `reset_workspace; exit 0`.
- `scaffold` → parse `--dind` (`DIND=true`) and `--force` (`FORCE=true`); then `create_dev_container; exit 0`.
- `fw` → next positional token is the action `disable|enable|log|drops` (error on anything else, naming `dev fw`). `fw log`/`fw drops`/`fw enable` call `fw_log`/`fw_drops`/`fw_enable`, which `exec` (or error+exit) — they never return. `fw disable` calls `fw_disable`; if a container is running it `exec`s the toggle, but with **no** running container `fw_disable` sets `FW_DISABLED_START=true` and returns 0. To preserve today's behavior, structure the `fw disable` branch so that a return from `fw_disable` **falls through** to the start path (do NOT `exit` after it) — set `subcmd=""` (or an equivalent "continue to start" flag) before leaving the `fw` dispatch so control reaches the default start command with `FW_DISABLED_START=true`. All other `fw` actions exit within their handler.
- default (empty `subcmd`) → the **start** command: run the existing start-flag parser (keep the `--dry-run/--build/--port/--host-port/--default-ports/--maintenance/--dind/--force/--` cases from the old `while` loop, minus the moved-to-subcommand flags) over the remaining args, then the preflight/image/`start_container` path. This is also where `fw disable` (no container) lands with `FW_DISABLED_START=true`.

Reuse the pieces that already exist: the start-flag `while` loop is the old loop with the seven relocated flags removed; the mode-selection (`IMAGE_TAG`/`BUILD_TARGET`/`RUNTIME_ARGS`) and the three-way `refuse_if_running` guard stay in the start path.

- [ ] **Step 4: Delete `forbid_companions` and the pairwise guards**

Remove `forbid_companions` (`dev:550-586`) and its call sites. Remove now-dead pairwise guards that only existed to reject flag combinations the router makes impossible: the `--dind`+`--maintenance` mutex (`dev:759-762`), the `forbid_companions --reset`/`--self-update`/`--create-dev-container` calls, and the `--monitor`+`--monitor-fw` / `--disable`+`--enable` mutual-exclusion checks (each subcommand now takes exactly one action). **Keep** the three-way container-mode guard (`refuse_if_running` for normal/maint/dind) in the start path — it guards runtime state, not flag composition.

- [ ] **Step 5: Run the unit test + snapshots**

```bash
bash scripts/test/unit/test-dev-subcommands.sh
bash scripts/test/unit/test-runner.sh 2>&1 | tail -2
bash scripts/lint.sh
diff <(./dev --help 2>&1) /tmp/dev-refsnap/help.txt || echo "HELP CHANGED (expected — usage rewritten in Task 9; re-snapshot after that)"
diff <(./dev --dry-run -- echo hi 2>&1) /tmp/dev-refsnap/start.txt && echo START-OK
```
Expected: subcommand test prints `ok`; unit runner shows only the known `test-cli-invalid-distro` failure; lint 0; START-OK. (`--help` text may still match here; it's formally updated in Task 9.)

- [ ] **Step 6: Commit**

```bash
git add dev scripts/test/unit/test-dev-subcommands.sh
git -c commit.gpgsign=false commit -m "feat(dev): subcommand CLI with deprecation aliases; drop companion guards

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Docs + scenario migration

**Files:**
- Modify: `dev` `usage()` (document subcommands)
- Modify: `README.md`, `CLAUDE.md` (subcommand syntax in examples/prose)
- Modify: scenarios that invoke the relocated flags; shrink `scripts/test/scenarios/20-mode-conflict-pairs.sh`

**Interfaces:**
- Consumes: the Task 8 CLI.
- Produces: nothing downstream.

- [ ] **Step 1: Rewrite `usage()` for subcommands**

Update the `usage()` heredoc so the synopsis is:
```
Usage: dev [OPTIONS] [-- COMMAND...]      # start/attach (default)
       dev fw {disable|enable|log|drops}
       dev reset
       dev scaffold [--dind] [--force]
       dev update [--dry-run]
       dev install
```
List the start OPTIONS (the retained start-path flags) under the default command. Add a short "Deprecated flags" note: the old flags still work with a warning and map to the subcommands. Keep the ENVIRONMENT section (including the DEV_ASSUME_YES allowlist note added in area C) intact.

- [ ] **Step 2: Re-snapshot help and update README/CLAUDE.md**

```bash
./dev --help > /tmp/dev-refsnap/help.txt 2>&1   # new reference
```
In `README.md`: update the "Daily Use", "Firewall controls", "Container Modes", and any `dev --self-update`/`dev --reset`/`dev --create-dev-container` examples to subcommand syntax (`dev fw disable`, `dev fw log`, `dev fw drops`, `dev reset`, `dev scaffold`, `dev update`), noting once that the old flags are deprecated aliases. In `CLAUDE.md`: the "Build and Run" command list uses the old flags (`./dev --dind`, `./dev --maintenance`, `./dev --disable-firewall`, `./dev --monitor`, etc.) — update the firewall/monitor/reset/scaffold/self-update ones to subcommands; `--dind`/`--maintenance` stay as start flags.

- [ ] **Step 3: Migrate scenario invocations to subcommand syntax**

Update scenarios that call the relocated flags. Known call sites to convert (grep to confirm the full set):
```bash
grep -rn -- '--disable-firewall\|--enable-firewall\|--monitor\|--monitor-fw\|--self-update\|--create-dev-container\|--reset' scripts/test/scenarios/
```
Convert each to the subcommand form (`./dev fw disable`, `./dev fw log`, `./dev reset`, etc.). Scenario `46-version-mismatch.sh` and the `21-monitor-firewall-targets-dind.sh` firewall/monitor scenario and `45-create-dev-container.sh` are the likely ones. Leave `--dind`/`--maintenance`/`--build`/`--port` as-is (still start flags). Because these scenarios need `--dind`/containers, they cannot run in this environment — convert them by inspection and note in your report that they run on the host/CI matrix.

- [ ] **Step 4: Shrink scenario 20 to the container-mode guard**

`scripts/test/scenarios/20-mode-conflict-pairs.sh` currently tests flag-composition refusals that the router makes impossible. Reduce it to assert only the surviving guard: a running normal/maint/dind container makes the other two modes refuse to start (the `refuse_if_running` three-way guard). Remove assertions about flags like `--reset --dind` being rejected as a companion (that's now just `dev reset` ignoring/handling extra args, not a guard). Read the current scenario and keep only the container-mode-conflict cases.

- [ ] **Step 5: Verify what can run here**

```bash
bash scripts/lint.sh
bash scripts/test/unit/test-runner.sh 2>&1 | tail -2
bash scripts/test/unit/test-dev-subcommands.sh
```
Expected: lint 0; only `test-cli-invalid-distro` fails; subcommand test `ok`. Note in the report that the migrated `--dind`/container scenarios (20, 21, 45, 46) are verified on the host/CI matrix, not here.

- [ ] **Step 6: Commit**

```bash
git add dev README.md CLAUDE.md scripts/test/scenarios/
git -c commit.gpgsign=false commit -m "docs(dev): document subcommand CLI; migrate scenarios to subcommands

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (after Task 9)

```bash
bash scripts/lint.sh                                  # exit 0
bash scripts/test/unit/test-runner.sh                 # only test-cli-invalid-distro fails (environmental)
bash scripts/test/unit/test-dev-subcommands.sh        # ok
bash scripts/test/unit/test-dev-allowlist-approval.sh # ok (regression guard on sourced fns)
bash scripts/test/unit/test-dev-github-token.sh       # ok
./dev --help                                          # subcommand synopsis
wc -l dev lib/dev/*.sh                                # dev is now a thin entry; logic in modules
```

**The full scenario matrix (`sudo bash scripts/test/run-all.sh`) on a real non-nested host is the merge gate** — it exercises `--dind`, the migrated subcommand scenarios, and the mode-conflict guard, none of which run in this environment. Area B (per-workspace home volume) follows in its own plan, layered on the modularized `lifecycle.sh` this plan produces.
