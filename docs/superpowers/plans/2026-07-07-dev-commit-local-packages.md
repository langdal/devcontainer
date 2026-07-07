# `./dev commit` Local Package Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `./dev commit` subcommand that snapshots a running maintenance container into a per-workspace derived image so `sudo`-installed system packages persist across restarts in normal + maintenance modes.

**Architecture:** `./dev commit` runs `<runtime> commit` on `dev-<ws>-maint` into the tag `generic-devcontainer:local-<ws>`, stamping a `devcontainer.local.base` label that records the base image ID. On the start path, `resolve_run_image` boots normal + maintenance containers from that derived image when the label matches the current base ID, and drops it as stale otherwise. `--dind`/`--pind` are untouched.

**Tech Stack:** Bash (the `dev` host script + `lib/dev/*.sh` modules, auto-sourced by the glob at `dev:46`), docker/podman CLI, the `scripts/test/` e2e scenario harness (no unit-test framework; verification is shellcheck + targeted CLI invocations + one e2e scenario).

## Global Constraints

- Tag name is exactly `generic-devcontainer:local-<workspace>` = `${IMAGE_NAME}:local-${WORKSPACE_BASENAME}`. `IMAGE_NAME="generic-devcontainer"` (`dev:200`).
- Validity label key is exactly `devcontainer.local.base`; its value is the current base image's `{{.Id}}`.
- Feature applies to **normal + maintenance only**. `--dind`/`--pind` must ignore the derived image (they use `:dind`/`:pind` tags).
- Persistence is **explicit only** — never auto-commit.
- `lib/dev/*.sh` files are plain function-definition files with **no side effects at source time** (`dev:43`). A new module is auto-sourced by the glob; do not add a manual `source` line.
- Existing helpers to reuse (all in `lib/dev/lifecycle.sh`): `container_running "<name>"`, `container_exists "<name>"`, `remove_container_if_exists`, `remove_volume_if_exists`. Globals available on the start path: `RUNTIME`, `RUNTIME_ARGS`, `IMAGE_NAME`, `IMAGE_TAG`, `WORKSPACE_BASENAME`, `MAINT_NAME`, `DIND`, `PIND`, `DRY_RUN`, `VERSION`.
- Commit signing: if `git commit` fails for lack of a GPG key (sandbox), retry with `git -c commit.gpgsign=false commit …`.
- Never `git push`.

---

## File Structure

- **Create `lib/dev/commit.sh`** — new module, auto-sourced. Defines two functions:
  - `commit_workspace` — implements the `commit` subcommand.
  - `resolve_run_image` — sets the `RUN_IMAGE` global on the start path.
- **Modify `dev`** — subcommand router entry (`dev:453`), a `commit)` case in the `case "$subcmd"` dispatch (`dev:499`), usage text (`dev:280`+ block and the examples), a `RUN_IMAGE` default + `resolve_run_image` call between the build block (`dev:824`) and `start_container` (`dev:837`).
- **Modify `lib/dev/lifecycle.sh`** — `start_container` uses `$RUN_IMAGE` instead of `$IMAGE_TAG` at line 442; `reset_workspace` removes the derived image.
- **Modify `scripts/test/lib/restore.sh`** — add `remember_image` + image-cleanup loop in `restore_host`.
- **Create `scripts/test/scenarios/48-dev-commit-local-packages.sh`** — e2e scenario.
- **Modify `CLAUDE.md` and `README.md`** — document `./dev commit`.

---

## Task 1: `./dev commit` subcommand + `commit_workspace`

**Files:**
- Create: `lib/dev/commit.sh`
- Modify: `dev` (subcommand router `dev:453`; `case "$subcmd"` dispatch after the `reset)` block ending `dev:527`; usage text `dev:280`+)

**Interfaces:**
- Consumes: `RUNTIME`, `IMAGE_NAME`, `WORKSPACE_BASENAME`, `MAINT_NAME` globals; `container_running` helper.
- Produces: `commit_workspace` (no args; reads globals; exits non-zero on error). Derived tag `${IMAGE_NAME}:local-${WORKSPACE_BASENAME}` stamped with `LABEL devcontainer.local.base=<base id>`.

- [ ] **Step 1: Create `lib/dev/commit.sh` with `commit_workspace`**

```bash
# shellcheck shell=bash
# lib/dev/commit.sh — `dev commit`: snapshot the running maintenance
# container into a per-workspace derived image so sudo-installed system
# packages persist. Sourced by dev; not executed directly.

# Tag for this workspace's local package overlay. One layer on top of the
# base image, per-workspace, local-only (never pushed, never git-tracked).
_derived_local_tag() {
  echo "${IMAGE_NAME}:local-${WORKSPACE_BASENAME}"
}

# `dev commit`: commit dev-<ws>-maint -> generic-devcontainer:local-<ws>,
# stamping the base image id so the start path can detect staleness.
commit_workspace() {
  local maint="$MAINT_NAME"
  local derived base_id
  derived="$(_derived_local_tag)"

  if ! container_running "$maint"; then
    echo "Error: no running maintenance container ($maint) to commit." >&2
    echo "       Start one, install packages, then commit:" >&2
    echo "         ./dev --maintenance          # in one shell: sudo apt-get install …" >&2
    echo "         ./dev commit                 # in another: snapshot it" >&2
    exit 1
  fi

  # Record the base image id so resolve_run_image can drop the overlay when
  # the base is later rebuilt (UID/version/--build change the id).
  base_id="$($RUNTIME image inspect "$IMAGE_NAME" --format '{{.Id}}' 2>/dev/null)"
  if [[ -z "$base_id" ]]; then
    echo "Error: base image $IMAGE_NAME not found; run './dev' once first." >&2
    exit 1
  fi

  echo "Committing $maint -> $derived …" >&2
  if ! $RUNTIME commit -c "LABEL devcontainer.local.base=${base_id}" "$maint" "$derived" >/dev/null; then
    echo "Error: commit failed." >&2
    exit 1
  fi

  echo "Committed local package layer: $derived" >&2
  echo "Note: this layer was built with the firewall OFF and now runs inside the" >&2
  echo "      firewalled normal container. Everything changed in system dirs" >&2
  echo "      (not just the intended package) is baked in. './dev --build' or" >&2
  echo "      './dev reset' discards it." >&2
}
```

- [ ] **Step 2: Add `commit` to the subcommand router in `dev`**

Modify `dev:453`:

```bash
  fw|reset|scaffold|update|install|commit) subcmd="$1"; shift ;;
```

- [ ] **Step 3: Add the `commit)` dispatch case in `dev`**

Insert immediately after the `reset)` case (which ends with `exit 0 ;;` at `dev:527`), mirroring reset's setup:

```bash
  commit)
    if [[ $# -gt 0 ]]; then
      echo "Error: dev commit does not take options: $*" >&2
      exit 1
    fi
    detect_runtime
    ensure_runtime_ready
    _resolve_workspace_names
    commit_workspace
    exit 0
    ;;
```

- [ ] **Step 4: Add usage text**

In the subcommand help block (after the `reset` entry that ends around `dev:291`), add:

```
  commit          Snapshot the running maintenance container
                  (dev-<dir>-maint) into a per-workspace local image
                  (generic-devcontainer:local-<dir>) so packages you
                  installed there with sudo persist into normal +
                  maintenance mode. Local only; never pushed or
                  git-tracked. Discarded by 'dev --build' and 'dev reset'.
                  Takes no options.
```

And add an example near the other `dev …` examples (`dev:355`+):

```
  dev commit                    # Persist packages installed in --maintenance
```

- [ ] **Step 5: Verify shellcheck + the no-container error path**

Run: `mise exec -- shellcheck dev lib/dev/commit.sh` (or `shellcheck` if on PATH)
Expected: no errors.

Run (from repo root, with no maintenance container running): `./dev commit`
Expected: exits non-zero; stderr contains `no running maintenance container` and the two-shell recipe.

- [ ] **Step 6: Commit**

```bash
git add lib/dev/commit.sh dev
git -c commit.gpgsign=false commit -m "feat: add 'dev commit' to snapshot maintenance container to a local image"
```

---

## Task 2: Boot-from-derived resolution (`resolve_run_image` + `RUN_IMAGE` wiring)

**Files:**
- Modify: `lib/dev/commit.sh` (add `resolve_run_image`)
- Modify: `lib/dev/lifecycle.sh:442` (`start_container` uses `$RUN_IMAGE`)
- Modify: `dev` (default `RUN_IMAGE="$IMAGE_TAG"`; call `resolve_run_image` after the build block, before `start_container`)

**Interfaces:**
- Consumes: `RUNTIME`, `IMAGE_TAG`, `IMAGE_NAME`, `WORKSPACE_BASENAME`, `DIND`, `PIND`, `DRY_RUN` globals; `_derived_local_tag` from Task 1.
- Produces: sets global `RUN_IMAGE` to either the base tag or the derived tag. Removes a stale derived image as a side effect (label ≠ current base id). `start_container` runs from `$RUN_IMAGE`.

- [ ] **Step 1: Add `resolve_run_image` to `lib/dev/commit.sh`**

```bash
# Start-path hook: decide which image the container boots from. Normal +
# maintenance boot from the per-workspace derived overlay when it exists and
# still matches the current base image id; otherwise (and always for
# dind/pind) they boot from the base tag. A derived image whose recorded base
# id no longer matches is stale (base was rebuilt) and is removed here so it
# never runs on top of a base it was not derived from. Sets RUN_IMAGE.
resolve_run_image() {
  RUN_IMAGE="$IMAGE_TAG"

  # dind/pind have their own image targets; the overlay never applies.
  if [[ "$DIND" == true || "$PIND" == true ]]; then
    return 0
  fi

  local derived derived_base base_id
  derived="$(_derived_local_tag)"

  # No overlay for this workspace -> base.
  if ! $RUNTIME image inspect "$derived" >/dev/null 2>&1; then
    return 0
  fi

  base_id="$($RUNTIME image inspect "$IMAGE_TAG" --format '{{.Id}}' 2>/dev/null)"
  derived_base="$($RUNTIME image inspect "$derived" \
    --format '{{ index .Config.Labels "devcontainer.local.base" }}' 2>/dev/null)"

  if [[ -n "$base_id" && "$derived_base" == "$base_id" ]]; then
    RUN_IMAGE="$derived"
    return 0
  fi

  # Stale: base was rebuilt out from under the overlay. Under --dry-run,
  # report but do not mutate.
  if [[ "$DRY_RUN" == true ]]; then
    echo "Would discard stale local package layer $derived (base image changed)." >&2
    return 0
  fi
  echo "Discarding stale local package layer $derived (base image changed);" >&2
  echo "  re-run './dev --maintenance' + './dev commit' to recreate it." >&2
  $RUNTIME rmi -f "$derived" >/dev/null 2>&1 || true
}
```

- [ ] **Step 2: Make `start_container` use `$RUN_IMAGE`**

Modify `lib/dev/lifecycle.sh:442` from:

```bash
  DOCKER_CMD+=("$IMAGE_TAG")
```

to:

```bash
  DOCKER_CMD+=("${RUN_IMAGE:-$IMAGE_TAG}")
```

Also update the `start_container` header comment (`lib/dev/lifecycle.sh:216`) to list `RUN_IMAGE` alongside `IMAGE_TAG` in the read-globals list.

- [ ] **Step 3: Wire `RUN_IMAGE` default + call `resolve_run_image` in `dev`**

Immediately before the final `start_container` call (`dev:837`), and after the build block (`dev:824`), insert:

```bash
# Choose the boot image: base, or this workspace's local package overlay
# when it is present and still matches the freshly-checked/rebuilt base.
# shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
RUN_IMAGE="$IMAGE_TAG"
resolve_run_image
```

- [ ] **Step 4: Verify shellcheck + dry-run image selection**

Run: `shellcheck dev lib/dev/commit.sh lib/dev/lifecycle.sh`
Expected: no errors.

Run (no derived image present): `./dev --dry-run`
Expected: the printed `run …` command ends with the base tag `generic-devcontainer` (not `:local-…`).

Simulate a valid overlay and re-check (requires the base image built once via a prior `./dev`):
```bash
WS=$(basename "$(pwd)")
BID=$(docker image inspect generic-devcontainer --format '{{.Id}}')   # use $RUNTIME if podman
docker tag generic-devcontainer "generic-devcontainer:local-$WS"
docker image inspect "generic-devcontainer:local-$WS" >/dev/null   # sanity
# stamp the label via a throwaway commit-less retag is not possible; instead:
docker build -q - <<EOF >/dev/null
FROM generic-devcontainer:local-$WS
LABEL devcontainer.local.base=$BID
EOF
```
Simpler: rely on Task 4's scenario for the positive path. Minimum bar here: `./dev --dry-run` selects base when no overlay exists, and selects `:local-$WS` when an overlay whose label equals the base id exists. If constructing the labelled image by hand is awkward, defer the positive assertion to the Task 4 scenario and only assert the base-selection + stale-removal here:
```bash
docker tag generic-devcontainer "generic-devcontainer:local-$WS"   # label absent -> treated as stale
./dev --dry-run                                                     # prints "Would discard stale…"
docker rmi -f "generic-devcontainer:local-$WS" 2>/dev/null || true
```
Expected: dry-run reports it would discard the stale overlay and selects the base tag.

- [ ] **Step 5: Commit**

```bash
git add lib/dev/commit.sh lib/dev/lifecycle.sh dev
git -c commit.gpgsign=false commit -m "feat: boot normal/maintenance from local package overlay when valid"
```

---

## Task 3: `./dev reset` removes the derived image

**Files:**
- Modify: `lib/dev/lifecycle.sh` (`reset_workspace`, `dev:64`+)

**Interfaces:**
- Consumes: `RUNTIME`, `IMAGE_NAME`, `WORKSPACE_BASENAME`; `_derived_local_tag` from Task 1.
- Produces: `reset_workspace` additionally removes `${IMAGE_NAME}:local-<ws>` if present.

- [ ] **Step 1: Remove the overlay image in `reset_workspace`**

The overlay is derived state (regenerable), so remove it unconditionally like the containers — not behind the per-volume prompt. Insert after the container-removal loop (`lib/dev/lifecycle.sh:107`, right after the `for i in "${!containers[@]}"` loop closes) and before the volume-prompt loop:

```bash
  # The per-workspace local package overlay is derived state, not user data;
  # remove it unconditionally like the containers (regenerable via
  # --maintenance + 'dev commit').
  local derived
  derived="${IMAGE_NAME}:local-${WORKSPACE_BASENAME}"
  if $RUNTIME image inspect "$derived" >/dev/null 2>&1; then
    echo "Removing local package image ${derived}…" >&2
    $RUNTIME rmi -f "$derived" >/dev/null 2>&1 || true
  fi
```

Also update the "Nothing to reset" guard (`lib/dev/lifecycle.sh:99`) is not required — the overlay removal is best-effort and the guard already covers containers+volumes; leave the guard as-is.

- [ ] **Step 2: Verify shellcheck + removal**

Run: `shellcheck lib/dev/lifecycle.sh`
Expected: no errors.

Run (with the base image built, and no volumes to avoid prompts, non-interactive):
```bash
WS=$(basename "$(pwd)")
docker tag generic-devcontainer "generic-devcontainer:local-$WS"   # use $RUNTIME for podman
DEV_ASSUME_YES=1 ./dev reset
docker image inspect "generic-devcontainer:local-$WS"
```
Expected: `reset` prints `Removing local package image generic-devcontainer:local-<ws>…`; the final `image inspect` fails (image gone).

- [ ] **Step 3: Commit**

```bash
git add lib/dev/lifecycle.sh
git -c commit.gpgsign=false commit -m "feat: 'dev reset' removes the local package overlay image"
```

---

## Task 4: e2e scenario + `remember_image` test helper

**Files:**
- Modify: `scripts/test/lib/restore.sh`
- Create: `scripts/test/scenarios/48-dev-commit-local-packages.sh`

**Interfaces:**
- Consumes: `RUNTIME`, `log_pass`/`log_fail`/`log_skip`, `expect_grep`, `require_platform`, `remember_container`, `restore_host` (existing test lib).
- Produces: `remember_image "<tag>"` — records a tag for `restore_host` to `rmi -f`.

- [ ] **Step 1: Add `remember_image` to `scripts/test/lib/restore.sh`**

Add the array declaration next to the others (`restore.sh:12`):

```bash
declare -a _RESTORE_IMAGES=()            # image tags to force-remove
```

Add the recorder next to `remember_container` (`restore.sh:36`):

```bash
remember_image() {
    _RESTORE_IMAGES+=("$1")
}
```

Add a removal loop inside `restore_host`, after the container loop (`restore.sh:49`):

```bash
    for img in "${_RESTORE_IMAGES[@]:-}"; do
        [ -z "$img" ] && continue
        ${RUNTIME:-docker} rmi -f "$img" >/dev/null 2>&1
    done
```

- [ ] **Step 2: Write the scenario `scripts/test/scenarios/48-dev-commit-local-packages.sh`**

```bash
#!/bin/bash
# scripts/test/scenarios/48-dev-commit-local-packages.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
M="dev-${WS}-maint"
N="dev-${WS}"
DERIVED="generic-devcontainer:local-${WS}"
remember_container "$M"
remember_container "$N"
remember_image "$DERIVED"
"$RUNTIME" rm -f "$M" "$N" 2>/dev/null
"$RUNTIME" rmi -f "$DERIVED" 2>/dev/null

# Marker package that is NOT in the base image and is tiny.
PKG=sl

# Step A: start a persistent maintenance container in the background
# (maintenance = sudo + no firewall). A one-shot 'dev --maintenance -- cmd'
# would exit and be --rm'd before we could commit, so keep it alive.
./dev --maintenance -- sleep 600 >/dev/null 2>&1 &
for _ in $(seq 1 60); do
    [ "$("$RUNTIME" inspect -f '{{.State.Running}}' "$M" 2>/dev/null)" = "true" ] && break
    sleep 1
done
if [ "$("$RUNTIME" inspect -f '{{.State.Running}}' "$M" 2>/dev/null)" != "true" ]; then
    log_fail "maintenance container did not start"; exit 1
fi

# Step B: install the marker package inside the running maintenance container.
"$RUNTIME" exec "$M" sudo apt-get update >/dev/null 2>&1
if ! "$RUNTIME" exec "$M" sudo apt-get install -y "$PKG" >/dev/null 2>&1; then
    log_skip "could not apt-get install $PKG in maintenance (no network?)"; exit 0
fi

# Step C: commit the running maintenance container.
if ! ./dev commit >/dev/null 2>&1; then
    log_fail "dev commit failed"; exit 1
fi
"$RUNTIME" rm -f "$M" >/dev/null 2>&1

# Step D: derived image exists and carries the base-id label.
lbl=$("$RUNTIME" image inspect "$DERIVED" \
    --format '{{ index .Config.Labels "devcontainer.local.base" }}' 2>&1)
if ! expect_grep "$lbl" 'sha256:|.'; then
    log_fail "derived image missing or unlabelled; got: $lbl"; exit 1
fi

# Step E: normal mode boots from the overlay -> package present AND the
# firewall is wired (HTTPS_PROXY exported by the entrypoint in normal mode).
out=$(./dev -- bash -lc 'command -v '"$PKG"' && echo "PROXY=$HTTPS_PROXY"' 2>&1)
"$RUNTIME" rm -f "$N" 2>/dev/null
if ! expect_grep "$out" "/$PKG"; then
    log_fail "package $PKG not present in normal mode; got: $out"; exit 1
fi
if ! expect_grep "$out" 'PROXY=http://127.0.0.1:8888'; then
    log_fail "firewall not enforcing in normal mode (HTTPS_PROXY unset); got: $out"; exit 1
fi

# Step F: --build rebuilds the base -> overlay is stale -> removed, package gone.
./dev --build -- true >/dev/null 2>&1
"$RUNTIME" rm -f "$N" 2>/dev/null
if "$RUNTIME" image inspect "$DERIVED" >/dev/null 2>&1; then
    log_fail "overlay not invalidated by --build"; exit 1
fi
out=$(./dev -- bash -lc 'command -v '"$PKG"' || echo MISSING' 2>&1)
"$RUNTIME" rm -f "$N" 2>/dev/null
if ! expect_grep "$out" 'MISSING'; then
    log_fail "package $PKG still present after --build invalidation; got: $out"; exit 1
fi

log_pass "dev commit persists maintenance packages; --build invalidates overlay"
exit 0
```

- [ ] **Step 3: Verify shellcheck + run the scenario**

Run: `shellcheck scripts/test/lib/restore.sh scripts/test/scenarios/48-dev-commit-local-packages.sh`
Expected: no errors.

Run: `sudo bash scripts/test/scenarios/48-dev-commit-local-packages.sh`
Expected: a `[PASS] 48-dev-commit-local-packages …` line and exit 0. (A `[SKIP]` is acceptable only if the host genuinely has no network to `apt-get install`; investigate before accepting a skip in CI.)

- [ ] **Step 4: Commit**

```bash
git add scripts/test/lib/restore.sh scripts/test/scenarios/48-dev-commit-local-packages.sh
git -c commit.gpgsign=false commit -m "test: cover 'dev commit' persistence and --build invalidation"
```

---

## Task 5: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Add `./dev commit` to the CLAUDE.md command list**

In the `## Build and Run` fenced block, after the `./dev --maintenance` block, add:

```bash
# Persist packages installed in a running --maintenance shell. Commits
# dev-<dir>-maint to a per-workspace local image (generic-devcontainer:local-<dir>)
# that normal + maintenance boot from. Local only; discarded by --build/reset.
./dev commit
```

And in the `--maintenance` description, append a sentence: "Packages installed here vanish when the container exits unless you snapshot them with `./dev commit` (see below)."

- [ ] **Step 2: Add a README subsection**

Under the maintenance-mode section of `README.md`, add a short subsection titled "Persisting maintenance-installed packages" covering:
- The two-shell workflow: `./dev --maintenance` (install with `sudo apt-get …`) then `./dev commit` in another shell.
- The result is a per-workspace, **local-only** image `generic-devcontainer:local-<dir>` (never pushed, never git-tracked) that normal + maintenance boot from.
- Layers are **cumulative** — installing another package + re-committing stacks on top; flatten with `./dev --build` or `./dev reset`.
- Invalidation: `./dev --build` (or any base rebuild from a UID/version change) discards the overlay with a warning; recreate via `--maintenance` + `commit`.
- Security caveat: the overlay is built with the firewall off and then runs in the firewalled normal container; only install what you intend to.
- Not covered: `--dind`/`--pind` (separate images).

- [ ] **Step 3: Verify**

Run: `grep -n "dev commit" CLAUDE.md README.md`
Expected: matches in both files.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git -c commit.gpgsign=false commit -m "docs: document 'dev commit' local package persistence"
```

---

## Self-Review

**Spec coverage:**
- `./dev commit` subcommand, precondition, tag, label, security reminder → Task 1. ✓
- Boot-from-derived for normal + maintenance; dind/pind excluded → Task 2. ✓
- Volume mounts excluded from the snapshot → inherent to `commit` (documented Task 5); no code needed. ✓
- Label-driven staleness / base-rebuild invalidation → Task 2 (`resolve_run_image`) + Task 4 Step F. ✓
- `./dev reset` removes overlay → Task 3. ✓
- Cumulative layers, flatten on reset/--build → behavior of Tasks 2/3; documented Task 5. ✓
- Error: no maintenance container running → Task 1 Step 1 + verified Task 1 Step 5. ✓
- e2e test (install → commit → normal-mode present + firewall on → --build invalidates) → Task 4. ✓
- Docs (CLAUDE.md + README) → Task 5. ✓

**Placeholder scan:** No TBD/TODO. All code steps show complete code. Task 2 Step 4 acknowledges the hand-built positive-path image is awkward and explicitly defers the positive assertion to Task 4's scenario while still asserting base-selection + stale-removal locally — this is a deliberate verification choice, not a placeholder.

**Type/name consistency:** `_derived_local_tag`, `commit_workspace`, `resolve_run_image`, `RUN_IMAGE`, `remember_image`, label key `devcontainer.local.base`, tag `${IMAGE_NAME}:local-${WORKSPACE_BASENAME}` used identically across Tasks 1–5. ✓
