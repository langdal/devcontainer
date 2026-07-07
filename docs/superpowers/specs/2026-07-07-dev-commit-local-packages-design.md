# `./dev commit` — local persistence of maintenance-installed packages

**Date:** 2026-07-07
**Status:** Design — approved for planning
**Branch:** `feat/dev-commit-local-packages` (on top of `feat/podman-in-podman`)

## Problem

`./dev --maintenance` starts a container with the firewall off and `sudo`
enabled so an agent (or user) can install system packages
(`sudo apt-get install …`). But containers are `--rm` (ephemeral) and only a
fixed set of paths live on named volumes — `/mise`, `/home/vscode`, and the
dind/pind data dirs. System packages land in `/usr`, `/etc`,
`/var/lib/dpkg`, `/var/lib/apt`, … — none of which persist. The moment the
maintenance container exits, everything installed with `sudo` is gone. There
is currently **no way to keep those packages**.

## Goal and scope

The chosen goal is **local persistence only** (not reproducible/shared):

- Whatever was installed with `sudo` in a maintenance session should survive
  container restarts **on this host**.
- It does **not** need to be git-tracked, reviewable, or shared with
  teammates. (The reproducible route — a git-tracked package manifest or a
  project Dockerfile fragment — was explicitly considered and declined.)

Availability scope: persisted packages must be available in **normal +
maintenance** modes. Maintenance is where you install (sudo, no firewall);
normal mode (firewalled, no sudo) is where the agent does its real work and
therefore where the packages actually need to be present.

Out of scope: `--dind` and `--pind`. They use separate image targets
(`:dind` / `:pind`) and their own containers; the overlay applies only to the
base image consumed by normal + maintenance.

Non-goals:

- No reproducibility / no git-tracked manifest.
- No cross-workspace sharing (the overlay is per-workspace).
- No automatic capture — persistence is always an explicit action.

## Approach

Capture the maintenance container's filesystem delta as **one image layer on
top of the base image**, tagged per workspace, via `<runtime> commit`. Normal
and maintenance containers boot from that derived image when it exists and is
still valid.

Why `commit` and not a volume/overlay over system paths: dpkg state is spread
across many directories (`/usr`, `/etc`, `/var/lib/dpkg`, `/var/lib/apt`, …)
and packages hardcode absolute paths. Committing the whole container captures
all of it atomically with native tooling. Critically, **`commit` excludes
volume mounts**, so `/home/vscode` and `/mise` are *not* baked into the image
— only genuine system-layer changes are captured. That is exactly the desired
delta and nothing else.

Considered and rejected:

- **Volume/overlay mount over `/usr` etc.** — fragile; dpkg state spans many
  dirs; overlayfs-in-container is messy.
- **Nix profile on a persisted volume** — heavy new dependency; Nix package
  names differ from apt; overkill for "local persistence."
- **Re-run install script at each start** — that is the reproducible route
  (declined) and needs root + network on every start.

## Components

### 1. `./dev commit` subcommand

- New subcommand parsed alongside `fw|reset|scaffold|update|install` in `dev`.
- Precondition: a running `dev-<workspace>-maint` container. If none is
  running, error out with the recipe:
  `./dev --maintenance` → install packages → `./dev commit`.
- Action:
  ```sh
  <runtime> commit \
    -c 'LABEL devcontainer.local.base=<base-image-id>' \
    dev-<workspace>-maint \
    generic-devcontainer:local-<workspace>
  ```
  where `<base-image-id>` is the image ID of the current base tag
  (`generic-devcontainer`) and `<workspace>` is `WORKSPACE_BASENAME`.
- On success, print a one-line security reminder (see Security note) and the
  resulting tag.
- The subcommand lives in a small helper (e.g. `commit_workspace` in
  `lib/dev/lifecycle.sh` or a new `lib/dev/commit.sh`), consistent with how
  `reset_workspace`, `fw`, etc. are factored out of `dev`.

**Decision — tag name:** `generic-devcontainer:local-<workspace>` (i.e.
`${IMAGE_NAME}:local-${WORKSPACE_BASENAME}`). Consistent with the existing
`:dind` / `:pind` tag convention on the same repo name.

### 2. Boot-from-derived resolution

- All existing image checks (`check_image_uid_match`,
  `check_image_version_match`, `runtime_build`) continue to run against the
  **base** tag (`IMAGE_TAG`) unchanged. This preserves the current UID and
  dev-version gating semantics.
- After those checks and any base (re)build, resolve a separate `RUN_IMAGE`
  used by `start_container` for **normal and maintenance modes only**:
  - If `generic-devcontainer:local-<workspace>` exists **and** its
    `devcontainer.local.base` label equals the current base image ID →
    `RUN_IMAGE = generic-devcontainer:local-<workspace>`.
  - Otherwise → `RUN_IMAGE = <base tag>`.
- `--dind` / `--pind` ignore the derived image entirely (`RUN_IMAGE` =
  their `:dind` / `:pind` tag as today).
- `start_container` runs from `RUN_IMAGE` instead of `IMAGE_TAG`. Because
  `commit` preserves the source container's config (CMD, ENTRYPOINT, ENV,
  USER, WORKDIR, and the UID/version LABELs inherited from base), the derived
  image behaves identically to base apart from the extra packages.

### 3. Invalidation / lifecycle

The `devcontainer.local.base` label is the single source of truth for
validity:

- **Base rebuild** (UID mismatch, dev-version mismatch, or `--build`) produces
  a new base image ID. The derived image's recorded label no longer matches →
  it is treated as **stale**: removed, a loud warning is printed
  (`local package layer discarded — re-run './dev --maintenance' + './dev commit' to recreate`),
  and boot falls back to base. This guarantees the overlay is never run on top
  of a base it was not derived from.
- **`./dev reset`** removes the `:local-<workspace>` image alongside the
  containers and volumes it already handles (extend `reset_workspace`; the
  image is removed unconditionally like containers, since it is derived, not
  user state). No new prompt — it is regenerable.
- **Layer growth:** maintenance also boots from the derived image (per the
  normal + maintenance scope), so re-running `./dev commit` after installing a
  second package stacks another layer cumulatively — you do *not* have to
  reinstall the first package. The flatten-back-to-base escape hatch is
  `--build` or `reset`. This is a documented tradeoff, not a bug.

  **Decision — cumulative layers:** accept cumulative growth (flattened only on
  `reset` / `--build`) rather than always re-deriving cleanly from base. This
  keeps "install one more thing" ergonomic, which is the common case. Squashing
  is not implemented (`commit` cannot squash; `export`/`import` would lose
  CMD/ENV/USER/labels).

## Data flow

```
./dev --maintenance         # boots RUN_IMAGE (base, or existing valid derived)
  sudo apt-get install foo  # writes /usr, /var/lib/dpkg, …
./dev commit                # commit dev-<ws>-maint -> generic-devcontainer:local-<ws>
                            #   with LABEL devcontainer.local.base=<base id>
# ... later ...
./dev                       # normal mode: RUN_IMAGE = derived (label matches base id)
                            #   -> `foo` present, firewall enforcing, no sudo
./dev --build               # base rebuilt -> base id changes -> derived stale
                            #   -> removed with warning -> RUN_IMAGE = base
```

## Error handling

- **`./dev commit` with no maintenance container running** → exit non-zero
  with the `--maintenance` → install → `commit` recipe.
- **`commit` fails** (runtime error, disk full) → surface the runtime error,
  exit non-zero, leave any prior derived image untouched.
- **Stale derived image at boot** → remove + warn (non-fatal), continue on
  base.
- **Runtime routing:** `commit` and the derived-image inspect/rm use the same
  connection-args discipline as the rest of `dev`. Normal + maintenance live in
  the default (rootless-or-rootful) storage, so the empty-args path applies;
  `commit` does not need `DIND_RUNTIME_ARGS`.

## Security note

The overlay is built in a **no-firewall** maintenance session and then runs
inside the **firewalled** normal container — the security-sensitive agent
context. Anything changed in system dirs during maintenance (not just the
intended package) is baked into the agent's environment. This is inherent to
the feature and acceptable given the explicit, opt-in `./dev commit` action.
`./dev commit` prints a one-line reminder to this effect. The firewall posture
itself (iptables OUTPUT DROP, tinyproxy hostname filtering, no sudo for
`vscode` in normal mode) is **unchanged** — the derived image adds packages,
not privileges.

## Testing

New end-to-end scenario under `scripts/test/scenarios/` (self-contained, uses
`scripts/test/lib/` helpers, reports via `log_pass`/`log_fail`/`log_skip`):

1. `./dev --maintenance -- sudo apt-get install -y <marker>` (marker = a small
   package not in the base image, e.g. `sl`).
2. `./dev commit`.
3. Start **normal** mode; assert the marker binary exists **and** the firewall
   is still enforcing (reuse `verify-firewall.sh` posture checks).
4. Invalidation: `./dev --build`; assert the derived image was removed and the
   marker binary is gone (back to base).
5. Cleanup: `./dev reset` removes the derived image.

The orchestrator (`scripts/test/run-all.sh`) picks the scenario up
automatically.

## Documentation

- `CLAUDE.md`: add `./dev commit` to the Build and Run command list; cross-
  reference it from the `--maintenance` description ("to keep packages
  installed here, `./dev commit`").
- `README.md`: short subsection under maintenance mode explaining the
  local-only, per-workspace, cumulative-layer semantics and the invalidation
  rules.

## Open decisions (resolved)

- **Tag name:** `generic-devcontainer:local-<workspace>`.
- **Layer strategy:** cumulative; flatten via `reset` / `--build`.
- **Trigger:** explicit `./dev commit` only (no auto-on-exit).
- **Scope:** normal + maintenance; dind/pind excluded.
