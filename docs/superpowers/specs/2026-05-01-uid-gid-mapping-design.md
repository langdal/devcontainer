# Host UID/GID propagation in `dev`

Date: 2026-05-01
Status: draft

## Problem

The `Dockerfile` accepts a `USER_UID` build arg (default 1000) and forces
the `vscode` group to the same number, but the `dev` script never sets
that arg. macOS users are told in the README to run
`docker build --build-arg USER_UID=501 .` by hand; everyone else gets
the 1000:1000 default. When the host's UID and/or GID differ, the named
volumes (`devcontainer-mise`, `devcontainer-home`, and the DinD-only
`devcontainer-dind`) accumulate files owned by the wrong IDs, leading
to permission errors that the README only resolves with `docker volume
rm`.

## Goal

`./dev --build` and `./dev` (implicit first build) bake the host's
actual UID/GID into the image without manual `--build-arg` plumbing,
and `./dev` refuses to attach to an image built for a different
identity without first prompting to rebuild.

## Non-goals

- In-place `chown` of volume contents. On accepted mismatch, volumes
  are removed; the next start re-populates them at the correct IDs.
- Detecting drift across image variants the user is not invoking now
  (e.g., warning that `:dind` is stale while running normal mode).
- Running `dev` as root. UID 0 is refused with a diagnostic.

## Architecture

The `dev` script becomes the single source of host identity. At startup
it reads `id -u` / `id -g` once and propagates them in two places:

1. **Build time.** Every build (explicit `--build` or implicit "no
   image yet") passes `--build-arg USER_UID=<host_uid>
   --build-arg USER_GID=<host_gid>`. The Dockerfile applies them to the
   `vscode` user/group and bakes labels `dev.uid` / `dev.gid` into the
   image.
2. **Run time.** Before deciding whether to attach/start/run, `dev`
   inspects the chosen image's labels and compares them to the host.
   On mismatch it prompts the user (interactive) or exits non-zero
   (non-interactive).

The host's UID/GID is the truth, the image labels are the cache, the
volumes live and die with the image.

## Components

### `dev` script changes

Insertions, in order:

1. **UID/GID detection** after `detect_runtime` /
   `ensure_runtime_ready`:

       HOST_UID=$(id -u)
       HOST_GID=$(id -g)

   Refuse `HOST_UID == 0` with:

       Error: refusing to run dev as root (UID 0). The image creates a
       non-root 'vscode' user; using UID 0 would conflict with the
       image's existing root user.

2. **`runtime_build` extension.** Append
   `--build-arg USER_UID=$HOST_UID --build-arg USER_GID=$HOST_GID` to
   both the docker-buildx and podman build paths. Reads the globals;
   no new positional arguments.

3. **`check_image_uid_match` helper.** Runs after `IMAGE_TAG` is chosen
   but before the existing "container running → attach" early returns.
   Logic:

   - Image absent → return clean (the existing build branch will
     build it).
   - Labels match host → return clean.
   - Image inspect fails → treat as image absent.
   - Empty/missing labels → treat as mismatch (older image built before
     this feature).
   - Mismatch + `FORCE_BUILD=true` → log, fall through. The build
     branch will rebuild; we still run the volume cleanup.
   - Mismatch + `DRY_RUN=true` → print "Would remove container X, would
     remove volumes Y, Z, would rebuild …", fall through.
   - Mismatch + interactive (TTY on stdin) → prompt with the combined
     question:

         Image generic-devcontainer was built for UID:GID 4242:4242,
         but you are 1000:1000.
         Rebuild image and remove volumes (devcontainer-mise,
         devcontainer-home)? [y/N]

     Yes → run `cleanup_for_rebuild`, set `FORCE_BUILD=true`, fall
     through. No → exit 1.
   - Mismatch + non-interactive → write the same diagnostic plus a
     `Run 'dev --build' to rebuild for UID/GID <h_uid>:<h_gid>` hint
     to stderr; exit 1.

4. **`cleanup_for_rebuild` helper.** Removes only what exists for the
   current invocation's image tag (per the architecture decision to
   stay narrow):

   - The named container we'd start (running or stopped) — `$RUNTIME
     rm -f`. Probe with `$RUNTIME ps -aq -f name=^…$` first.
   - Each named volume that exists. Probe with `$RUNTIME volume
     inspect <name>` before attempting `volume rm`. List:
     `devcontainer-mise`, `devcontainer-home`, plus
     `devcontainer-dind` only when `DIND=true`.

   Each step ignores "absent" but propagates real failures (paused
   container, runtime mid-restart) — print the runtime's error and
   exit non-zero.

5. **`DEV_ASSUME_YES` env var.** When set to `1`, the prompt is
   skipped and treated as a yes. Test harness uses this. Documented
   briefly in `dev --help` epilogue, not as a flag.

6. **Early-exit flag interactions.** The new check must be inserted
   *after* the existing `--monitor`, `--monitor-fw`,
   `--disable-firewall`, `--enable-firewall` early-exec blocks. Those
   act on a running container and should not block on label mismatch.

### `Dockerfile` changes

- Add `ARG USER_GID=1000` alongside `ARG USER_UID=1000`.
- Extend the existing UID-rewrite `RUN`:

      RUN if [ "${USER_UID}" != "1000" ] || [ "${USER_GID}" != "1000" ]; then \
              groupmod --gid ${USER_GID} vscode && \
              usermod --uid ${USER_UID} --gid ${USER_GID} vscode && \
              chown -R ${USER_UID}:${USER_GID} /home/vscode; \
          fi

- Add `LABEL dev.uid="${USER_UID}" dev.gid="${USER_GID}"` immediately
  after the rewrite. Labels propagate to the `dind` stage automatically
  because it is `FROM base`.

### README changes

Rewrite the macOS section to "just run `./dev`". Drop the manual
`docker build --build-arg USER_UID=501 .` instruction. Drop the
"if you change USER_UID after the volume already exists, you must
remove it" caveat — `dev` now handles that.

## Control flow

    ./dev [--build] [--dind] …
            |
            v
    detect_runtime, ensure_runtime_ready
            |
            v
    HOST_UID = id -u; HOST_GID = id -g
            |
            v
    HOST_UID == 0 ? --refuse--> exit 1
            |
            v
    early-exec flags (--monitor*, --*-firewall) …
            |
            v
    choose IMAGE_TAG / BUILD_TARGET / CONTAINER_NAME (existing)
            |
            v
    check_image_uid_match(IMAGE_TAG, HOST_UID, HOST_GID)
       |     |                |               |
       |     |                |               +--> mismatch + --build  --> log, fall through
       |     |                +--> mismatch + --dry-run --> "would …", fall through
       |     +--> mismatch + interactive   --> prompt
       |     |                                   +-- yes --> cleanup_for_rebuild; FORCE_BUILD=true; fall through
       |     |                                   +-- no  --> exit 1
       |     +--> mismatch + non-interactive --> error + exit 1
       +--> match or no image --> fall through
            |
            v
    existing build branch:
       if FORCE_BUILD or image not present:
           runtime_build …  # now with UID/GID build-args
            |
            v
    existing attach/start/run branches (unchanged)

### Invariants

- `cleanup_for_rebuild` runs strictly before `runtime_build` whenever
  the user accepted the prompt.
- A successful cleanup forces `FORCE_BUILD=true`. The existing image
  build branch then runs unconditionally, regardless of whether the
  image tag still resolves locally (we do not `rmi` the image
  ourselves).
- `--dry-run` prints what would happen but does not prompt and does
  not execute. The downstream "Would build image …" line is preceded
  by a "Would remove …" line.

## Edge cases

- **Image with no `dev.*` labels.** Treated as mismatch. Self-heals
  after one rebuild.
- **`docker image inspect` fails between `images -q` and inspect.**
  Treat as image absent; fall through to build.
- **Empty label values.** Treat as missing label.
- **Volume `inspect` fails / volume absent.** Skip removal; do not
  error.
- **Container removal fails** (paused, runtime mid-restart). Print
  the runtime's error and exit non-zero. Workspace state is
  inconsistent and the user should resolve it manually.
- **`--maintenance` / `--dind` mode.** Same flow; the volume list
  differs only by including `devcontainer-dind` when `DIND=true`.
- **macOS + podman.** `id -u` / `id -g` return the macOS user IDs
  (typically 501:20). Podman remaps through the VM, but the
  bake-into-image path is identical and labels match against the
  host. README's stale per-platform `--build-arg` instructions are
  removed.
- **Non-Linux container hosts other than macOS.** Out of scope (the
  project only supports Linux and macOS).

## Testing

Five new scenarios under `scripts/test/scenarios/`. All are platform:
linux because the test harness is Linux-only. Each sources
`assert.sh`, `runtime.sh`, `restore.sh`, and traps `restore_host EXIT`.

### `40-uid-gid-default-build.sh`

- Remove any pre-existing `generic-devcontainer` images and the three
  named volumes.
- `./dev --build -- true`.
- Assert `docker image inspect generic-devcontainer --format
  '{{ index .Config.Labels "dev.uid" }}'` equals `$(id -u)`; same for
  `dev.gid` vs `$(id -g)`.
- Assert `./dev -- id -u vscode` returns `$(id -u)`; same for
  `id -g vscode` vs `$(id -g)`.
- Restore: remove the test container.

### `41-uid-gid-mismatch-no-tty.sh`

- Build with explicit non-host UID/GID:
  `docker build --build-arg USER_UID=4242 --build-arg USER_GID=4242 -t
  generic-devcontainer .` — bypasses `dev` so labels say `4242:4242`.
- `./dev -- true </dev/null` (closed stdin → non-interactive). Expect
  non-zero exit and stderr containing the host's UID/GID and a
  `dev --build` hint.
- Assert the image still has `4242` labels (no auto-rebuild happened).
- Restore: rebuild image with default labels via `./dev --build --
  true`; remove the test container.

### `42-uid-gid-mismatch-rebuild.sh`

- Same setup as 41 (image labels at `4242`).
- Pre-create a marker in `devcontainer-home`:
  `docker run --rm -v devcontainer-home:/h busybox sh -c 'echo old >
  /h/marker'`.
- `DEV_ASSUME_YES=1 ./dev -- test ! -e /home/vscode/marker`. Expect
  exit 0 (marker is gone because volume was wiped) and image labels
  now match host.
- Restore: remove the test container.

### `43-uid-gid-running-container.sh`

- Build at `4242`; capture the resulting image ID
  (`OLD_IMAGE_ID=$(docker images -q generic-devcontainer)`).
- Start a long-running stale container: `docker run -d --rm --name
  dev-<dir> generic-devcontainer sleep 3600`.
- `DEV_ASSUME_YES=1 ./dev -- true`. Expect: stale container removed
  before rebuild (so `./dev -- true` does not attach to the stale
  one), image tag now points at a different ID
  (`NEW_IMAGE_ID=$(docker images -q generic-devcontainer)` ≠
  `OLD_IMAGE_ID`), label `dev.uid` matches `$(id -u)`.
- Restore: remove the test container; defensive `volume rm` on the
  three named volumes.

### `44-uid-gid-rebuild-no-volumes.sh`

- Build at `4242`. Up-front remove the three named volumes so they do
  not exist.
- `DEV_ASSUME_YES=1 ./dev -- true`. Expect: succeeds with no
  `volume rm` errors; image rebuilt; new volumes created on container
  start (`docker volume inspect devcontainer-home` succeeds).
- Restore: remove the test container.

### Harness notes

- All scenarios use the existing `remember_volume` / `remember_
  container` helpers and run `restore_host` on EXIT.
- `run-all.sh` needs no changes; the `[0-9]*.sh` glob picks the new
  files up.
- Scenarios 41–44 mutate the global image tag and serialize naturally
  because `run-all.sh` is sequential. If the orchestrator is ever
  parallelized, these need to opt out.
- 40–44 leave the image at default UID/GID labels on exit so
  subsequent scenarios in the same run see a clean baseline.
