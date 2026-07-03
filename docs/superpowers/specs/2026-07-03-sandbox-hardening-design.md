# Sandbox Hardening & CLI Simplification — Design

**Date:** 2026-07-03
**Status:** Approved
**Scope:** This repository (the generic devcontainer)

## Goal

Fix the issues surfaced by the 2026-07-03 project review, prioritized by the
operator's criteria: developer experience first; protection of the **host
machine** and prevention of **accidental credential leakage/misuse by agents**
over exotic deliberate-exfiltration scenarios.

Five work areas, in implementation order:

| # | Area | Kind |
|---|------|------|
| A | Allowlist approval gate | host protection |
| C | GITHUB_TOKEN guidance + scope preflight | accidental cred misuse |
| E | Small-fix bundle (banner, sha256, docs, test runtime) | DX / hygiene |
| D | CLI subcommands + module split | DX |
| B | Per-workspace home volume | accidental cred exposure |

Explicitly **out of scope** (operator decision): the general "agent writes a
file the host later executes" class (e.g. git hooks in the bind-mounted
workspace); DNS egress scoping; shared-infrastructure allowlist hosts
(CloudFront/GCS/R2); threat-model rewording beyond what the sections below
touch.

## A. Allowlist approval gate

### Problem

`.devcontainer-allowlist` lives in `/workspace`, which the sandboxed agent can
write. `firewall-init.sh` merges it into the tinyproxy filter at every
container start and on `--enable-firewall`. An agent that hits a blocked host
can discover the mechanism (it is documented in CLAUDE.md) and "helpfully"
allowlist the host itself — taking effect at the next restart with no human in
the loop.

### Design

**Host-side state dir.** `dev` gains a per-workspace state directory:

```
${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/<basename>-<hash4>/
```

where `<hash4>` is the first 4 hex chars of the sha256 of the workspace's
absolute path (disambiguates same-basename workspaces; the container-name
collision caveat is unchanged and separate).

**Approval flow (runs in `dev` on the host, before container create/start):**

1. No `./.devcontainer-allowlist` in the workspace → remove any stale
   snapshot, proceed.
2. File matches the approved snapshot (`allowlist.approved` in the state dir)
   → proceed.
3. New or changed → show a unified diff (`diff -u snapshot workspace-file`;
   `/dev/null` as the old side when no snapshot exists) and prompt
   `Approve allowlist changes? [y/N]`.
   - Approve (or `DEV_ASSUME_YES=1`) → copy the workspace file to the
     snapshot, proceed.
   - Decline, or non-interactive stdin without `DEV_ASSUME_YES` → **start
     without the project allowlist** and print a warning. Fail-safe: never
     blocks a container start, never silently applies unreviewed entries.

**Container side.** The state dir is mounted read-only:

```
-v <state-dir>:/etc/devcontainer/project:ro
```

`firewall-init.sh` changes its `PROJECT` source from
`/workspace/.devcontainer-allowlist` to
`/etc/devcontainer/project/allowlist.approved` (merge behavior otherwise
unchanged). The **directory** is mounted, not the file: single-file bind
mounts pin an inode and go stale when the host file is atomically replaced.
With the directory mount, a re-approval while a container is running is
picked up by `dev fw enable` (section D naming) without a restart.

The workspace file remains the reviewable, committable source of truth that
teams check into their repos; it just stops being directly consumed inside
the container.

### Error handling

- State dir missing → created on demand (`mkdir -p`).
- Snapshot unreadable/corrupt → treated as "no snapshot": full-file diff and
  prompt.
- Stopped-container reuse: mounts are fixed at create time, but the mount is
  the state dir path, whose *contents* `dev` updates — restarted containers
  see the current approved snapshot.

### Testing

- New scenario: from inside a running container, append a host to
  `/workspace/.devcontainer-allowlist`; restart the container
  non-interactively; assert the host is still blocked. Then re-run with
  `DEV_ASSUME_YES=1` and assert it is allowed.
- Scenario 25 (private-registry-allowlist) updated to go through the approval
  flow (`DEV_ASSUME_YES=1`).
- `verify-firewall.sh` unchanged (posture checks are source-agnostic).

## C. GITHUB_TOKEN guidance + scope preflight

### Problem

`dev` forwards `GITHUB_TOKEN` into the container whenever it is set. The
*intended* use is rate-limit identification (mise/gh API calls), for which a
no-permission token suffices — but nothing tells users that, and a
full-permission token handed to an agent is the canonical accidental-misuse
setup.

### Design

**Docs.** README gains a "GitHub token" subsection under Environment
variables: the passthrough exists to lift the 60/hr anonymous API limit; the
recommended token is a **fine-grained PAT with no repository access and no
permissions** (identification only); step-by-step creation pointer.

**Preflight (in `dev`, when `GITHUB_TOKEN` is set).** Once per distinct
token, verdict cached in the state dir keyed on the token's sha256:

- `curl -fsS -D - -o /dev/null -m 5 -H "Authorization: Bearer $GITHUB_TOKEN"
  https://api.github.com/rate_limit`, read the `x-oauth-scopes` response
  header.
- Classic/OAuth token (`ghp_`, `gho_`, or scopes header present) with a
  **non-empty** scope list → one-line stderr warning naming the scopes and
  pointing at the README section.
- Fine-grained PAT (`github_pat_` prefix; no scopes header) → no warning
  (scoped by construction; permissions are not cheaply introspectable).
- Empty scopes header → no warning.
- curl missing, network failure, non-2xx → skip silently and do not cache
  (retry next run). The preflight **never blocks**.

### Testing

- Unit test using the existing PATH-overlay stub pattern
  (`scripts/test/lib/runtime.sh` masking) to fake `curl` responses: scoped
  classic token warns; unscoped classic token is silent; fine-grained token
  is silent; network failure is silent; cache prevents a second curl call.

## E. Small-fix bundle

1. **Firewall-off banner.** `firewall-disable.sh` writes
   `/etc/profile.d/zz-fw-disabled-banner.sh` (same mechanism as the existing
   maintenance banner in `entrypoint.sh`) announcing that the firewall is
   open. `firewall-init.sh` removes that file, so re-enabling clears the
   banner. Existing shells are unaffected (documented limitation, same as
   maintenance mode).
2. **sha256 fail-hard.** In the Dockerfile dind stage, delete the fallback
   that computes a checksum from the just-downloaded docker bundle when the
   `.sha256` sidecar is missing (a check that can never fail). A missing
   sidecar fails the build with a message naming the URL.
3. **Docs single-sourcing.** README's verbatim flags block is replaced by a
   pointer to `dev --help` plus the conceptual documentation; the drifted
   entries (`--self-update` missing from the flags section, `--reset` absent
   from README) disappear with it. CLAUDE.md keeps behavior notes only, not
   a flag list. `usage()` in `dev` becomes the single source of flag truth.
4. **Test-harness runtime.** `scripts/test/lib/runtime.sh` gains
   `host_runtime()` (docker preferred, podman fallback — same order as
   `dev`). `run-all.sh` and scenario scripts use it instead of hardcoded
   `docker` for container/volume cleanup.

## D. CLI subcommands + module split

### Problem

`dev` is ~1430 lines multiplexing seven distinct programs through one flag
parser. Flags imply composability, so every non-composable pair needs an
explicit guard (`forbid_companions`, plus pairwise checks scattered through
the file). Subcommands make invalid combinations unrepresentable.

### New CLI surface

| New | Replaces |
|---|---|
| `dev` (+ `--dind`, `--maintenance`, `--build`, `--port`, `--host-port`, `--default-ports`, `--dry-run`, `-- CMD`) | unchanged start/attach path |
| `dev fw disable` | `--disable-firewall` (keeps dual behavior: toggle running container, else start fresh with firewall off) |
| `dev fw enable` | `--enable-firewall` |
| `dev fw log` | `--monitor` |
| `dev fw drops` | `--monitor-fw` |
| `dev reset` | `--reset` |
| `dev scaffold [--dind] [--force]` | `--create-dev-container` |
| `dev update [--dry-run]` | `--self-update` |
| `dev install` | unchanged |
| `dev --version` / `dev --help` | unchanged |

**Back-compat.** Every replaced flag remains as an alias: it prints a
one-line deprecation note on stderr and dispatches to its subcommand.
Removal is deferred to the next major release. `DEV_ASSUME_YES`,
`DEV_RUNTIME`, and the other env vars are unchanged.

### Module split

`dev` stays the single entry point (release-please version literal, arg
dispatch, shared globals) and sources modules from `$SCRIPT_DIR/lib/dev/`:

| Module | Contents |
|---|---|
| `preflight.sh` | runtime detection/readiness, AppArmor + subid checks, UID-0 refusal |
| `image.sh` | UID/version label checks, `runtime_build`, rebuild cleanup |
| `lifecycle.sh` | run/attach/start, container+volume helpers, reset |
| `fw.sh` | `fw` subcommands, managed-container resolution |
| `scaffold.sh` | `.devcontainer/` generation |
| `update.sh` | self-update |

This costs nothing for distribution: `dev` already requires sibling files at
`SCRIPT_DIR` and installs as a symlink into the checkout. Scaffolding is
unaffected (it copies container-side files, not `dev`). `forbid_companions`
and the pairwise flag guards are deleted; each subcommand parses only its own
flags. The three-way *container-mode* conflict guard (normal/maint/dind)
legitimately remains.

### Testing

- Existing scenarios move to subcommand syntax.
- New unit test: every deprecated alias maps to its subcommand (string-level
  dispatch check via `--dry-run` where possible).
- Scenario 20 (mode-conflict pairs) shrinks to the container-mode guard.

## B. Per-workspace home volume

### Problem

`devcontainer-home` is one global volume: SSH keys, `.gitconfig`, `gh` auth,
and shell history from **every** project are readable and usable by the agent
in **any** project's container. This is the main accidental-cred-misuse
surface.

### Design

**Default change.** The home volume becomes `devcontainer-home-<dir>`
(matching the container-name convention, inheriting its documented
basename-collision caveat). Volume names are resolved in one place and used
by run, reset, and rebuild-cleanup paths. The rootless-podman volume
ownership handling introduced with the `--userns=keep-id` fix (detect raw
owner ≠ `$HOST_UID`, one-time re-chown via `podman unshare`) must key on the
resolved per-workspace name as well.

- `devcontainer-mise` stays **shared** — pure tool cache.
- `devcontainer-dind` stays **shared** — nested image cache, same rationale;
  it is mounted over `~/.local/share/docker` inside the per-workspace home.

**Escape hatch.** `DEV_SHARED_HOME=1` selects the legacy `devcontainer-home`
name; nothing else changes. Env var only — no new CLI flag.

**Migration.** No auto-copy. On the first run where the per-workspace volume
does not exist but legacy `devcontainer-home` does, print a one-time note:
isolated home is now the default, the old volume is untouched, set
`DEV_SHARED_HOME=1` to keep the old behavior.

**DX offset.** Losing the shared home means fresh git identity per project.
`dev` reads the host's `git config user.name` / `user.email` and passes them
as `DEV_GIT_NAME` / `DEV_GIT_EMAIL`; the entrypoint's vscode block seeds them
into `~/.gitconfig` **only when no identity is already set**. SSH keys are
deliberately not seeded. Projects that need push-from-inside get a documented
opt-in pattern in the README (mount an ssh-agent socket or a per-project
deploy key via `DEV_EXTRA_RUN_ARGS`) instead of a global key store.

### Testing

- Scenario: two workspaces produce distinct home volumes; `DEV_SHARED_HOME=1`
  reuses the legacy name.
- Git identity seeding asserted in the cold-start scenario (22), including
  the "already set → not overwritten" case.
- UID-mismatch rebuild scenarios (40-44) updated for resolved volume names.

## Alternatives considered

- **Move the allowlist out of the workspace** (A): rejected — kills the
  "team commits the allowlist with the repo" DX.
- **Abort the start on unapproved allowlist** (A): rejected in favor of
  start-without-entries — fail-safe without blocking CI/non-interactive use.
- **Make token passthrough opt-in** (C): rejected — the zero-config
  rate-limit fix is the feature; guidance + warning preserves it.
- **Docs-only for the home volume** (B): kept available via
  `DEV_SHARED_HOME=1`, but isolated-by-default is the safer default given
  the operator's accidental-misuse priority.
- **Keep the flag CLI and only split files** (D): rejected — the guard
  machinery, the actual complexity driver, would remain.
- **Rewrite `dev` in a non-bash language** (D): rejected — conflicts with
  the project's portability ethos.

## Implementation order

A → C → E → D → B. Each area lands as an independent, releasable unit; D
(the refactor) deliberately precedes B so the volume-name changes are made
in the already-modularized lifecycle code. A, C, and E do not depend on D
and use the current file layout; their code moves mechanically during D.
