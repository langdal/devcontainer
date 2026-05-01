# Host UID/GID propagation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `./dev --build` (and implicit first build) bake the host's
real UID/GID into the image, and make `./dev` refuse to attach to an
image built for a different identity without first prompting to rebuild
and wipe the named volumes.

**Architecture:** The `dev` script becomes the single source of host
identity. It reads `id -u` / `id -g` once, propagates them to every
build via `--build-arg`, and (before any attach/start) inspects
`dev.uid` / `dev.gid` labels on the chosen image to decide whether to
prompt-rebuild. On accepted mismatch the script removes the workspace's
container and the named volumes; the next start re-populates them from
the freshly built image.

**Tech Stack:** bash, Docker / Podman, multi-stage Dockerfile.

---

## File Structure

**Modify:**
- `Dockerfile` — add `ARG USER_GID`; extend the existing UID-rewrite
  `RUN`; add `LABEL dev.uid` / `dev.gid`. Single stage (`base`); the
  `dind` stage inherits via `FROM base`.
- `dev` — add host UID/GID detection + UID-0 refusal; add
  `--build-arg` plumbing in `runtime_build`; add `check_image_uid_match`
  and `cleanup_for_rebuild` helpers; honour `DEV_ASSUME_YES`.
- `README.md` — rewrite the macOS section to "just run `./dev`"; drop
  the volume-removal warning.

**Create:**
- `scripts/test/scenarios/40-uid-gid-default-build.sh`
- `scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh`
- `scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh`
- `scripts/test/scenarios/43-uid-gid-running-container.sh`
- `scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh`

**Test orchestration:** `scripts/test/run-all.sh` is unchanged. The
new scenario files are picked up by its `[0-9]*.sh` glob.

**TDD pattern for this plan:** each task writes the scenario file
first, runs it (expect FAIL because the dev/Dockerfile change is not
yet in place), makes the source change, re-runs the scenario (expect
PASS), and commits.

**Single-scenario invocation** (used in every task):

```bash
sudo bash scripts/test/scenarios/40-uid-gid-default-build.sh
```

The scenario harness needs `sudo -n` available (same as `run-all.sh`).
Output ends with `[PASS] …` or `[FAIL] …`.

**Image / volume hygiene between scenarios:** scenarios 41–44
deliberately mutate the global `generic-devcontainer` image tag.
Each one ends with `./dev --build -- true >/dev/null 2>&1` so the
image is restored to host-UID labels before the next scenario runs.

---

### Task 1: Detect host UID/GID and propagate to every build

**Files:**
- Create: `scripts/test/scenarios/40-uid-gid-default-build.sh`
- Modify: `Dockerfile`
- Modify: `dev`

- [ ] **Step 1: Write the failing scenario**

Create `scripts/test/scenarios/40-uid-gid-default-build.sh`:

```bash
#!/bin/bash
# scripts/test/scenarios/40-uid-gid-default-build.sh
# platform: linux
#
# `dev --build` bakes the invoking user's UID/GID into the image labels
# and into the in-container vscode user.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
remember_container "dev-${WS}"

HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Wipe image + volumes so we exercise the cold-start build path.
docker rm -f "dev-${WS}" >/dev/null 2>&1
docker rmi -f generic-devcontainer >/dev/null 2>&1
docker volume rm devcontainer-mise devcontainer-home >/dev/null 2>&1

if ! ./dev --build -- true >/dev/null 2>&1; then
    log_fail "dev --build failed"
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
img_gid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.gid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ] || [ "$img_gid" != "$HOST_GID" ]; then
    log_fail "labels are ${img_uid}:${img_gid}, want ${HOST_UID}:${HOST_GID}"
    exit 1
fi

in_uid=$(./dev -- id -u vscode 2>/dev/null | tr -d '\r')
in_gid=$(./dev -- id -g vscode 2>/dev/null | tr -d '\r')
if [ "$in_uid" != "$HOST_UID" ] || [ "$in_gid" != "$HOST_GID" ]; then
    log_fail "in-container vscode is ${in_uid}:${in_gid}, want ${HOST_UID}:${HOST_GID}"
    exit 1
fi

# Idempotency: a second invocation with matching labels must not
# trigger a rebuild prompt. (No DEV_ASSUME_YES, no closed stdin —
# if a prompt fired, the closed-stdin probe would error out.)
if ! ./dev -- true </dev/null >/dev/null 2>&1; then
    log_fail "second dev invocation with matching labels failed"
    exit 1
fi

log_pass "dev --build bakes host UID/GID and is idempotent"
exit 0
```

- [ ] **Step 2: Run the scenario to verify it fails**

```bash
chmod +x scripts/test/scenarios/40-uid-gid-default-build.sh
sudo bash scripts/test/scenarios/40-uid-gid-default-build.sh
```

Expected: `[FAIL] 40-uid-gid-default-build  labels are :, want <UID>:<GID>` — the current image has no `dev.uid` / `dev.gid` labels.

- [ ] **Step 3: Add `USER_GID` arg + label to the Dockerfile**

Modify `Dockerfile`. Replace the existing UID-rewrite block (lines 3–11)
with:

```Dockerfile
# Allow UID/GID override so the image can be built for the invoking
# host user. The dev script reads `id -u` / `id -g` and passes both
# as build-args; the labels are what the dev script later inspects to
# detect a mismatch on subsequent runs.
ARG USER_UID=1000
ARG USER_GID=1000

# Apply UID/GID override if needed (vscode already exists at 1000:1000
# in the base image).
RUN if [ "${USER_UID}" != "1000" ] || [ "${USER_GID}" != "1000" ]; then \
        groupmod --gid ${USER_GID} vscode && \
        usermod --uid ${USER_UID} --gid ${USER_GID} vscode && \
        chown -R ${USER_UID}:${USER_GID} /home/vscode; \
    fi

LABEL dev.uid="${USER_UID}" dev.gid="${USER_GID}"
```

The `dind` stage is `FROM base` (line 99), so the labels propagate
automatically.

- [ ] **Step 4: Detect host UID/GID in the dev script**

Modify `dev`. Just after `ensure_runtime_ready` is called (around
line 315 in the current script — the line that reads
`ensure_runtime_ready`), insert:

```bash
# Host identity. Used to (a) bake correct UID/GID into the image at
# build time, and (b) detect when an existing image was built for a
# different user.
HOST_UID=$(id -u)
HOST_GID=$(id -g)
if [[ "$HOST_UID" == "0" ]]; then
  echo "Error: refusing to run dev as root (UID 0). The image creates a non-root 'vscode' user; using UID 0 would conflict with the image's existing root user." >&2
  exit 1
fi
```

- [ ] **Step 5: Pass UID/GID build args from `runtime_build`**

Modify `dev`. Replace the body of `runtime_build` (current lines 79–92)
with:

```bash
runtime_build() {
  local tag="$1"; shift
  local target="$1"; shift   # may be empty string; only docker/podman with --target use it
  local context="$1"; shift
  local extra=()
  if [[ -n "$target" ]]; then
    extra+=(--target "$target")
  fi
  extra+=(--build-arg "USER_UID=$HOST_UID" --build-arg "USER_GID=$HOST_GID")
  if [[ "$RUNTIME" == "docker" ]]; then
    docker buildx build --network=host "${extra[@]}" -t "$tag" "$context"
  else
    podman build --network=host "${extra[@]}" -t "$tag" "$context"
  fi
}
```

`runtime_build` is called from one place (the existing build branch
near line 428). It already runs after the new HOST_UID/HOST_GID
detection — no other callers to update.

- [ ] **Step 6: Run the scenario to verify it passes**

```bash
sudo bash scripts/test/scenarios/40-uid-gid-default-build.sh
```

Expected: `[PASS] 40-uid-gid-default-build  dev --build bakes host UID/GID and is idempotent`

- [ ] **Step 7: Commit**

```bash
git add Dockerfile dev scripts/test/scenarios/40-uid-gid-default-build.sh
git commit -m "$(cat <<'EOF'
dev: bake host UID/GID into image at build time

dev now reads id -u / id -g and passes them as USER_UID / USER_GID
build-args. Dockerfile applies them to the vscode user/group and bakes
dev.uid / dev.gid labels for later mismatch detection. Refuses to run
as root.

Adds scenario 40 covering: cold-build labels match host, in-container
vscode user matches host, idempotent on second invocation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Detect mismatch in non-interactive runs

**Files:**
- Create: `scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh`
- Modify: `dev`

- [ ] **Step 1: Write the failing scenario**

Create `scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh`:

```bash
#!/bin/bash
# scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh
# platform: linux
#
# Image built for a different UID/GID than the host: a non-interactive
# `dev` invocation must refuse to attach and exit non-zero with a
# diagnostic referencing the host's UID/GID and a `dev --build` hint.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
remember_container "dev-${WS}"

HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Bypass dev to bake labels of 4242:4242 directly.
docker rm -f "dev-${WS}" >/dev/null 2>&1
if ! docker buildx build --network=host \
        --build-arg USER_UID=4242 --build-arg USER_GID=4242 \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build mismatched image"
    exit 1
fi

# Closed stdin → non-interactive. dev should exit non-zero.
out=$(./dev -- true </dev/null 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    log_fail "expected dev to refuse attach with mismatched labels; got rc=0 output: $out"
    # Restore image before exit so subsequent scenarios are clean.
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -qE "${HOST_UID}|UID"; then
    log_fail "expected diagnostic mentioning host UID; got: $out"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi
if ! echo "$out" | grep -q "dev --build"; then
    log_fail "expected '--build' hint in diagnostic; got: $out"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Image must still have the 4242 labels (no auto-rebuild).
img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "4242" ]; then
    log_fail "image was rebuilt without consent: labels=$img_uid"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Restore image to host UID/GID for subsequent scenarios.
./dev --build -- true >/dev/null 2>&1 || true

log_pass "non-interactive mismatch refuses attach with diagnostic"
exit 0
```

- [ ] **Step 2: Run the scenario to verify it fails**

```bash
chmod +x scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh
sudo bash scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh
```

Expected: `[FAIL] 41-uid-gid-mismatch-no-tty  expected dev to refuse attach with mismatched labels; got rc=0 …` — the dev script does not yet inspect labels.

- [ ] **Step 3: Add `check_image_uid_match` to the dev script**

Modify `dev`. Insert this function just before the existing
`refuse_if_running` function (around line 399):

```bash
# Compare host UID/GID to the labels on $IMAGE_TAG. On a clean match (or
# image absent), return 0. On mismatch, either prompt-and-rebuild
# (interactive) or print a diagnostic and exit 1 (non-interactive). The
# explicit `--build` flag and `--dry-run` make this advisory rather than
# fatal — the build branch will still rebuild with the right args.
check_image_uid_match() {
  local tag="$1"
  # No image yet → nothing to check; the existing build branch will build it.
  if ! $RUNTIME image inspect "$tag" >/dev/null 2>&1; then
    return 0
  fi
  local img_uid img_gid
  img_uid=$($RUNTIME image inspect "$tag" \
      --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
  img_gid=$($RUNTIME image inspect "$tag" \
      --format '{{ index .Config.Labels "dev.gid" }}' 2>/dev/null)
  if [[ -n "$img_uid" && -n "$img_gid" \
        && "$img_uid" == "$HOST_UID" && "$img_gid" == "$HOST_GID" ]]; then
    return 0
  fi
  # Mismatch (including the empty-label case from older images).
  local img_id="${img_uid:-?}:${img_gid:-?}"
  if [[ "$FORCE_BUILD" == true ]]; then
    echo "Note: image $tag built for UID:GID $img_id; rebuilding for $HOST_UID:$HOST_GID." >&2
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "Would rebuild $tag for UID:GID $HOST_UID:$HOST_GID (current labels: $img_id)" >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: image $tag was built for UID:GID $img_id, but you are $HOST_UID:$HOST_GID." >&2
    echo "       Run 'dev --build' to rebuild for UID:GID $HOST_UID:$HOST_GID." >&2
    exit 1
  fi
  # Interactive prompt path — implemented in Task 3.
  echo "Error: image $tag was built for UID:GID $img_id, but you are $HOST_UID:$HOST_GID." >&2
  echo "       Run 'dev --build' to rebuild for UID:GID $HOST_UID:$HOST_GID." >&2
  exit 1
}
```

- [ ] **Step 4: Wire `check_image_uid_match` into the main flow**

Modify `dev`. Just before the existing build branch (the line
`if [[ "$FORCE_BUILD" == true ]] || ! $RUNTIME images -q "$IMAGE_TAG"`,
around line 423), insert:

```bash
# Refuse to attach to an image built for a different host user. This
# must run AFTER the early --monitor / --*-firewall exits (those act on
# a running container and shouldn't be blocked by label mismatch) and
# BEFORE the existing build branch (so a mismatch can short-circuit
# into a forced rebuild via the path added in Task 3).
check_image_uid_match "$IMAGE_TAG"
```

- [ ] **Step 5: Run the scenario to verify it passes**

```bash
sudo bash scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh
```

Expected: `[PASS] 41-uid-gid-mismatch-no-tty  non-interactive mismatch refuses attach with diagnostic`

- [ ] **Step 6: Commit**

```bash
git add dev scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh
git commit -m "$(cat <<'EOF'
dev: refuse mismatched image in non-interactive runs

Adds check_image_uid_match: inspects dev.uid / dev.gid labels on the
chosen image tag and exits non-zero with a 'dev --build' hint when the
host user's UID/GID does not match. Honoured by --build (advisory) and
--dry-run (advisory). Closed stdin always exits 1.

Adds scenario 41 covering the closed-stdin path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Prompt-driven rebuild + volume cleanup

**Files:**
- Create: `scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh`
- Modify: `dev`

- [ ] **Step 1: Write the failing scenario**

Create `scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh`:

```bash
#!/bin/bash
# scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh
# platform: linux
#
# DEV_ASSUME_YES bypasses the prompt; the script then removes the named
# volumes and rebuilds the image. The marker file we plant in
# devcontainer-home before invocation must be gone afterwards.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
remember_container "dev-${WS}"

HOST_UID=$(id -u)

# Build mismatched image directly.
docker rm -f "dev-${WS}" >/dev/null 2>&1
if ! docker buildx build --network=host \
        --build-arg USER_UID=4242 --build-arg USER_GID=4242 \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build mismatched image"
    exit 1
fi

# Plant a marker in devcontainer-home that the rebuild path must wipe.
docker volume create devcontainer-home >/dev/null
docker run --rm -v devcontainer-home:/h busybox \
    sh -c 'echo old > /h/marker' >/dev/null 2>&1

# DEV_ASSUME_YES=1 bypasses the prompt. The command runs inside the
# rebuilt container; the marker should be gone (volume was removed and
# repopulated from the image's empty /home/vscode).
out=$(DEV_ASSUME_YES=1 ./dev -- test -e /home/vscode/marker 2>&1)
rc=$?
# `test -e` returns 1 when missing → expected outcome here.
if [ "$rc" -eq 0 ]; then
    log_fail "marker still present after rebuild — volume not wiped (out: $out)"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Image labels now match host.
img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "image not rebuilt to host UID; labels=$img_uid"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "DEV_ASSUME_YES rebuilds image and wipes named volumes"
exit 0
```

- [ ] **Step 2: Run the scenario to verify it fails**

```bash
chmod +x scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh
sudo bash scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh
```

Expected: `[FAIL] 42-uid-gid-mismatch-rebuild  …` — the no-tty branch from Task 2 currently exits 1 even when `DEV_ASSUME_YES=1` is set, because the `DEV_ASSUME_YES` short-circuit and `cleanup_for_rebuild` helper do not exist yet.

- [ ] **Step 3: Add `cleanup_for_rebuild` to the dev script**

Modify `dev`. Insert just below the existing `refuse_if_running`
function (around line 406):

```bash
# Remove the workspace's container (running or stopped) and the named
# volumes for the current invocation's image variant. Used after the
# user accepts the rebuild prompt; the rebuild path that follows
# replaces the image and the next container start re-populates the
# volumes from the freshly-built image.
cleanup_for_rebuild() {
  local container="$1" with_dind="$2"
  if $RUNTIME ps -aq -f name="^${container}$" | grep -q .; then
    echo "Removing container ${container}…" >&2
    if ! $RUNTIME rm -f "$container" >/dev/null 2>&1; then
      echo "Error: failed to remove container ${container}." >&2
      exit 1
    fi
  fi
  local vols=(devcontainer-mise devcontainer-home)
  if [[ "$with_dind" == true ]]; then
    vols+=(devcontainer-dind)
  fi
  for v in "${vols[@]}"; do
    if $RUNTIME volume inspect "$v" >/dev/null 2>&1; then
      echo "Removing volume ${v}…" >&2
      if ! $RUNTIME volume rm "$v" >/dev/null 2>&1; then
        echo "Error: failed to remove volume ${v}." >&2
        exit 1
      fi
    fi
  done
}
```

- [ ] **Step 4: Add the prompt + assume-yes path to `check_image_uid_match`**

Modify `dev`. Replace the entire `check_image_uid_match` function
(added in Task 2) with the version below. The change adds the
interactive-prompt branch and the `DEV_ASSUME_YES` short-circuit, both
of which run `cleanup_for_rebuild` and force a rebuild via
`FORCE_BUILD=true`:

```bash
check_image_uid_match() {
  local tag="$1"
  if ! $RUNTIME image inspect "$tag" >/dev/null 2>&1; then
    return 0
  fi
  local img_uid img_gid
  img_uid=$($RUNTIME image inspect "$tag" \
      --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
  img_gid=$($RUNTIME image inspect "$tag" \
      --format '{{ index .Config.Labels "dev.gid" }}' 2>/dev/null)
  if [[ -n "$img_uid" && -n "$img_gid" \
        && "$img_uid" == "$HOST_UID" && "$img_gid" == "$HOST_GID" ]]; then
    return 0
  fi
  local img_id="${img_uid:-?}:${img_gid:-?}"
  if [[ "$FORCE_BUILD" == true ]]; then
    echo "Note: image $tag built for UID:GID $img_id; rebuilding for $HOST_UID:$HOST_GID." >&2
    cleanup_for_rebuild "$CONTAINER_NAME" "$DIND"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "Would rebuild $tag for UID:GID $HOST_UID:$HOST_GID (current labels: $img_id)" >&2
    return 0
  fi
  if [[ "${DEV_ASSUME_YES:-0}" == "1" ]]; then
    echo "Note: image $tag built for UID:GID $img_id; DEV_ASSUME_YES set, rebuilding for $HOST_UID:$HOST_GID." >&2
    cleanup_for_rebuild "$CONTAINER_NAME" "$DIND"
    FORCE_BUILD=true
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: image $tag was built for UID:GID $img_id, but you are $HOST_UID:$HOST_GID." >&2
    echo "       Run 'dev --build' to rebuild for UID:GID $HOST_UID:$HOST_GID." >&2
    exit 1
  fi
  echo "Image $tag was built for UID:GID $img_id, but you are $HOST_UID:$HOST_GID." >&2
  local vol_list="devcontainer-mise, devcontainer-home"
  if [[ "$DIND" == true ]]; then
    vol_list="${vol_list}, devcontainer-dind"
  fi
  local reply
  read -r -p "Rebuild image and remove volumes (${vol_list})? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      cleanup_for_rebuild "$CONTAINER_NAME" "$DIND"
      FORCE_BUILD=true
      ;;
    *)
      echo "Aborted." >&2
      exit 1
      ;;
  esac
}
```

Note `cleanup_for_rebuild` is also called from the `--build` branch
above. That guarantees: even if the user explicitly passed `--build`
when there's a label mismatch, the existing volumes are still wiped
before the build starts (otherwise the new container would mount
volumes owned by the old UID).

- [ ] **Step 5: Document `DEV_ASSUME_YES` in `--help`**

Modify `dev`. In `usage()`, just before `EXAMPLES:`, add:

```
ENVIRONMENT:
  DEV_ASSUME_YES=1   Answer yes to the rebuild prompt that triggers when
                     the image's dev.uid / dev.gid labels do not match
                     the invoking user's id -u / id -g. Used by tests.

```

- [ ] **Step 6: Run the scenario to verify it passes**

```bash
sudo bash scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh
```

Expected: `[PASS] 42-uid-gid-mismatch-rebuild  DEV_ASSUME_YES rebuilds image and wipes named volumes`

- [ ] **Step 7: Re-run scenario 41 to confirm no regression**

```bash
sudo bash scripts/test/scenarios/41-uid-gid-mismatch-no-tty.sh
```

Expected: `[PASS] 41-uid-gid-mismatch-no-tty  …`

- [ ] **Step 8: Commit**

```bash
git add dev scripts/test/scenarios/42-uid-gid-mismatch-rebuild.sh
git commit -m "$(cat <<'EOF'
dev: prompt to rebuild and wipe volumes on UID/GID mismatch

When dev.uid / dev.gid labels disagree with id -u / id -g, an
interactive run prompts to rebuild the image and remove the named
volumes. DEV_ASSUME_YES=1 short-circuits the prompt for tests. The
--build path also wipes the volumes when labels mismatched, so the
fresh image starts against fresh volumes.

Adds scenario 42 covering the assume-yes rebuild path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Mismatch with a running stale container

**Files:**
- Create: `scripts/test/scenarios/43-uid-gid-running-container.sh`

- [ ] **Step 1: Write the scenario**

Create `scripts/test/scenarios/43-uid-gid-running-container.sh`:

```bash
#!/bin/bash
# scripts/test/scenarios/43-uid-gid-running-container.sh
# platform: linux
#
# A running container backed by a mismatched image must be removed by
# the rebuild path. After DEV_ASSUME_YES=1 ./dev …, the image tag must
# point at a different image ID and the labels must match host.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
CN="dev-${WS}"
remember_container "$CN"

HOST_UID=$(id -u)

docker rm -f "$CN" >/dev/null 2>&1
if ! docker buildx build --network=host \
        --build-arg USER_UID=4242 --build-arg USER_GID=4242 \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build mismatched image"
    exit 1
fi
OLD_IMAGE_ID=$(docker images -q generic-devcontainer)

# Long-running stale container.
docker run -d --rm --name "$CN" generic-devcontainer sleep 3600 >/dev/null

if ! DEV_ASSUME_YES=1 ./dev -- true >/dev/null 2>&1; then
    log_fail "dev failed during rebuild path"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

NEW_IMAGE_ID=$(docker images -q generic-devcontainer)
if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
    log_fail "image was not rebuilt (id unchanged: $OLD_IMAGE_ID)"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "labels still mismatched after rebuild: $img_uid"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# Stale container must be gone (it was removed before rebuild).
if docker ps --format '{{.Names}}' | grep -qx "$CN"; then
    log_fail "stale container $CN is still running"
    docker rm -f "$CN" >/dev/null 2>&1
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "rebuild path removes stale container and re-tags image"
exit 0
```

- [ ] **Step 2: Run the scenario to verify it passes**

```bash
chmod +x scripts/test/scenarios/43-uid-gid-running-container.sh
sudo bash scripts/test/scenarios/43-uid-gid-running-container.sh
```

Expected: `[PASS] 43-uid-gid-running-container  rebuild path removes stale container and re-tags image`

(The rebuild plumbing in Tasks 1–3 already handles the running-container case via `cleanup_for_rebuild`'s `$RUNTIME rm -f`. This task is a pure regression-test addition; no source changes needed.)

- [ ] **Step 3: Commit**

```bash
git add scripts/test/scenarios/43-uid-gid-running-container.sh
git commit -m "$(cat <<'EOF'
test: scenario 43 — mismatch path removes running container

Locks in cleanup_for_rebuild's rm -f behaviour against a stale
long-running container. No source changes; the helper already handles
it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Mismatch when named volumes don't exist

**Files:**
- Create: `scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh`

- [ ] **Step 1: Write the scenario**

Create `scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh`:

```bash
#!/bin/bash
# scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh
# platform: linux
#
# cleanup_for_rebuild must skip absent volumes silently. Otherwise a
# user who manually wiped their volumes hits a `volume rm: no such
# volume` and fails the rebuild flow.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/runtime.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
remember_container "dev-${WS}"

HOST_UID=$(id -u)

docker rm -f "dev-${WS}" >/dev/null 2>&1
if ! docker buildx build --network=host \
        --build-arg USER_UID=4242 --build-arg USER_GID=4242 \
        -t generic-devcontainer . >/dev/null 2>&1; then
    log_fail "could not build mismatched image"
    exit 1
fi

# Make sure the named volumes really do not exist.
docker volume rm devcontainer-mise devcontainer-home >/dev/null 2>&1 || true

if ! DEV_ASSUME_YES=1 ./dev -- true >/dev/null 2>&1; then
    log_fail "dev failed when no volumes existed before rebuild"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

img_uid=$(docker image inspect generic-devcontainer \
    --format '{{ index .Config.Labels "dev.uid" }}' 2>/dev/null)
if [ "$img_uid" != "$HOST_UID" ]; then
    log_fail "labels not updated after rebuild: $img_uid"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

# `dev` re-creates the volumes on container start.
if ! docker volume inspect devcontainer-home >/dev/null 2>&1; then
    log_fail "devcontainer-home was not re-created on container start"
    ./dev --build -- true >/dev/null 2>&1 || true
    exit 1
fi

log_pass "cleanup_for_rebuild handles absent volumes"
exit 0
```

- [ ] **Step 2: Run the scenario to verify it passes**

```bash
chmod +x scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh
sudo bash scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh
```

Expected: `[PASS] 44-uid-gid-rebuild-no-volumes  cleanup_for_rebuild handles absent volumes`

(The `volume inspect` probe in `cleanup_for_rebuild` from Task 3 already gates each `volume rm`. This task is a pure regression-test addition; no source changes needed.)

- [ ] **Step 3: Commit**

```bash
git add scripts/test/scenarios/44-uid-gid-rebuild-no-volumes.sh
git commit -m "$(cat <<'EOF'
test: scenario 44 — mismatch path tolerates absent volumes

Locks in cleanup_for_rebuild's volume-inspect probe against the case
where named volumes were already wiped manually. No source changes;
the helper already handles it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Update the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the macOS section**

Modify `README.md`. Replace the entire `## macOS Users` block
(currently around lines 268–280) with:

```markdown
## macOS Users

`./dev` reads `id -u` / `id -g` and bakes those into the image
automatically. No manual `--build-arg` is needed. If your host UID/GID
ever changes, the next `./dev` invocation detects the mismatch and
prompts to rebuild + wipe the named volumes.
```

- [ ] **Step 2: Drop the stale UID-change warning from the volumes section**

Modify `README.md`. The current `## Volume Caching` section ends with
a paragraph (around line 285 onwards) that says nothing UID-specific
— leave it. The note that lived in the macOS block ("If you change
USER_UID after the volume already exists, you must remove it") is
removed by Step 1.

Also update the **Troubleshooting** section. Replace the
"UID Mismatch" bullet (around line 332) with:

```markdown
- **UID Mismatch**: `./dev` detects when the image's `dev.uid` /
  `dev.gid` labels disagree with your `id -u` / `id -g` and prompts
  to rebuild + wipe the named volumes. If you decline the prompt the
  script exits non-zero. Set `DEV_ASSUME_YES=1` to accept
  non-interactively.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
README: drop stale macOS USER_UID instructions

dev now bakes host UID/GID automatically and prompts to rebuild on
mismatch — the manual --build-arg dance is no longer needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full test run

**Files:** none modified.

- [ ] **Step 1: Run the full orchestrator and confirm green**

```bash
sudo bash scripts/test/run-all.sh
```

Expected: the final summary shows `5` more passes than before this
plan started (40, 41, 42, 43, 44 all passing) and **zero** new
failures in the existing scenarios. The `--build` rebuild that
`run-all.sh` runs at the top now also goes through the new build-arg
path, so the orchestrator's pre-built images carry the host's labels
— scenarios that used to ignore labels are unaffected.

- [ ] **Step 2: Inspect the orchestrator log if anything failed**

```bash
less scripts/test/last-run.log
```

If pre-existing scenarios fail because the image now has labels they
did not expect, fix the scenario; do not relax the new behaviour.

- [ ] **Step 3: No commit needed for this task** (no file changes).
