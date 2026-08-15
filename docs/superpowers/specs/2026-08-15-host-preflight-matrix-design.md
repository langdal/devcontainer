# Host Preflight + Test Matrix Design

Date: 2026-08-15
Status: approved in discussion; pending spec review
Scope: workstream 3 of the org-rollout roadmap (host preflight checking and
the platform/runtime test matrix). Follows workstreams 1+2
(`2026-08-14-cli-overhaul-design.md`).

## Goal

A colleague on a machine nobody has seen before gets a good first run: `dev`
either works, or refuses with a message that names the problem and the fix.
Everything here is measured against that sentence.

## Why now

Three host-environment gaps surfaced in a single session on 2026-08-15, each
producing either a silent false-green or a wall of unrelated failures:

- `docker-buildx` was missing. `run-all.sh:72` installs it only when *neither*
  runtime is on PATH, so a host with docker but no buildx failed every image
  build. The orchestrator wrote a truncated summary with no failure list, the
  run read as clean, and a task review passed on it.
- `DOCKER_HOST` pointed at a rootless podman socket. `dev` classified the
  engine from the CLI binary's version string, skipped `--userns=keep-id` and
  the volume chown migration, and every write to `/home/vscode` and `/mise`
  failed with EACCES.
- `kernel.apparmor_restrict_unprivileged_userns=1` blocked ten scenarios.
  `dev` handled it correctly, but nothing told the operator up front.

None of these were code defects in the tool. All three were host facts the
tool could have detected and reported in one line.

## Non-goals

- No `--fix` flag. Every remediation mutates host security posture (sysctls,
  subuid ranges, package installs); those stay the user's to run.
- No checks requiring a built image or a running container. Doctor must work
  on a bare machine — that is its whole purpose.
- No cartesian matrix. 3 distros x 2 runtimes x 2 privilege levels is twelve
  cells; most combinations do not exist in the fleet and CI time is real.

## Target fleet

Three combinations must work:

1. macOS Apple Silicon + podman
2. Linux + rootful docker
3. Linux + rootless podman

macOS Intel is explicitly out of scope. Docker Desktop remains unsupported.

## Architecture

### Check registry

The project targets bash 3.2 (macOS ships it), so the registry cannot be an
associative array. Indexed arrays are fine.

Each check is a declaration line plus a probe function:

```bash
# lib/dev/checks.sh
# id|applies-to|severity|title
CHECKS=(
  "buildx|linux,darwin:docker|block|docker buildx present"
  "engine-cli-match|linux,darwin:*|advise|CLI and engine agree"
  "userns-sysctl|linux:*|block-if-nested|unprivileged userns permitted"
  "subid-grant|linux:podman|block-if-nested|subuid/subgid range >= 165535"
  "podman-machine|darwin:podman|block|podman machine running"
)

_chk_buildx()     { ... }   # 0 pass, 1 fail, 2 not-applicable
_chk_buildx_fix() { ... }   # prints remediation
```

`applies-to` is `platform[,platform]:runtime[,runtime]`, `*` meaning any. The
runner filters on live platform and runtime before probing, so a docker-only
check never runs on a podman host and never reports a misleading failure.

A probe returns **three** states, not two: pass, fail, and not-applicable.
"Could not determine" must never render as "fine" — the same fail-open defect
fixed in `dev status` on 2026-08-15 (`status.sh`, firewall probe).

### Severities

- `block` — `dev up` refuses.
- `block-if-nested` — refuses only under `--dind`/`--pind`. The apparmor and
  subuid preflights are this today; naming it stops them reading as "your host
  is broken" to someone who only wants a normal container.
- `advise` — `dev doctor` reports it, `dev up` proceeds.

### Modules

`lib/dev/checks.sh` holds the registry and probes; `lib/dev/doctor.sh` holds
the verb and its reporting. Split because the catalogue grows and the reporter
does not, and because `scripts/lint.sh` enforces a 300-line budget per module.

`lib/dev/preflight.sh` collapses into `checks.sh`; its three functions become
registry entries.

### Probe indirection (testability constraint)

Probes must not call `uname`, `command -v`, or the runtime directly. They go
through thin indirections — `_host_os`, `_have_cmd`, `_runtime_version` — that
unit tests override. This is what lets macOS-only checks be verified from
Linux. A probe that shells out directly is not unit-testable, and the macOS
cell loses its coverage; treat this as a review gate, not a style preference.

## `dev doctor`

### Output

```
$ dev doctor
Host      Linux 7.0.0 · x86_64
Runtime   docker (CLI 29.1.3) → podman 5.7.0, rootless    ← engine ≠ CLI
Workspace devcontainer  (image: not built)

  ✓  unprivileged userns permitted
  ✓  subuid/subgid range ≥ 165535        100000–365535
  ✗  docker buildx present
       The Dockerfile uses RUN --mount=type=secret, which the legacy
       builder cannot handle.
       Fix:  sudo apt-get install docker-buildx
  !  CLI and engine agree
       DOCKER_HOST points at a podman socket; dev will drive podman
       directly. Set DEV_RUNTIME to pin this.
  –  podman machine running                              (macOS only)

1 blocking, 1 advisory, 3 passed, 1 not applicable
```

Four states render distinctly, with plain-ASCII fallback when stdout is not a
tty — this output gets pasted into chat when someone asks for help.
Remediation prints only under failures; passing checks stay one line so the
report fits a screen.

### Exit codes

Consistent with the verb grammar from workstreams 1+2:

- `0` — no blocking failures. Advisories do not fail; a working-but-unusual
  host must not show a red exit.
- `1` — at least one blocking failure.
- `2` — usage error.

Exit 0/1 is what makes doctor the matrix's assertion: a cell runs `dev doctor`
and requires 0, turning "is this host combination supported" into one testable
claim.

### Arguments

`dev doctor [--dind|--pind]`. Bare, `block-if-nested` checks report as
advisory. Passing `--dind` promotes them to blocking, because then they
genuinely block.

## Integration with `dev up`

`cmd_start` currently hard-codes two preflight calls (`up.sh:167`, `up.sh:196`).
Both are replaced by one runner over the registry, filtered to blocking
severity for the live platform, runtime and mode.

**Two phases**, because "is there a runtime at all" is itself a check while
most checks need `$RUNTIME`:

- **Phase 0**, before `detect_runtime`: platform supported, a runtime exists.
  `detect_runtime`'s own "Neither docker nor podman found" error becomes a
  phase-0 entry and stops being a special case.
- **Phase 1**, after it: everything runtime-specific.

Two visible behaviour changes:

- **All blocking failures report, not just the first.** The ordering comment at
  `up.sh:143` exists purely so the apparmor error wins the race against the
  subid one; with an ordered registry that hack disappears. Nobody discovers
  the second problem after fixing the first.
- **Advisories never print during `dev up`** — they would be noise on every
  start. The engine/CLI mismatch keeps its existing `Note:`, because it changes
  which binary runs.

**Migration risk:** scenarios 11, 12, 15 and 16 assert preflight behaviour, and
scenario 15's whole job is that the apparmor refusal fires cleanly with
remediation. They grep for message presence rather than exact ordering, so they
should survive — but "those four still pass" is an implementation gate, not an
assumption. This is the part of the design most likely to bite.

## Check catalogue

Sixteen checks, in four groups by origin:

- **Seven migrate** logic that already exists but is scattered across
  `preflight.sh`, `runtime.sh` and `up.sh` (platform, runtime-exists,
  podman-machine, workspace-not-root-owned, userns-sysctl, subid-grant,
  `GITHUB_TOKEN` scopes).
- **Three enforce requirements only the scenario suite tests today**, moving
  them to the point of use (not-Docker-Desktop, `/dev/fuse`, cgroup v2).
- **Three are new**, each from a bug found on 2026-08-15 (buildx,
  CLI-and-engine-agree, home-volume ownership).
- **Three are advisory conveniences** (SELinux enforcing, free disk, free RAM).

### Phase 0

| Check | Severity | Origin |
|---|---|---|
| platform supported (linux/darwin) | block | migrated from `detect_runtime` |
| a container runtime exists | block | migrated from `detect_runtime` |

### Phase 1 — blocking

| Check | Applies | Origin |
|---|---|---|
| `docker buildx` present | docker | **new** — 2026-08-15 false-green |
| not Docker Desktop | darwin | scenario 91; unsupported by design |
| `podman machine` running | darwin+podman | scenario 90; from `ensure_runtime_ready` |
| workspace not root-owned | all | migrated from `refuse_root_uid` |

### Phase 1 — blocking only for `--dind`/`--pind`

| Check | Applies | Origin |
|---|---|---|
| unprivileged userns permitted | linux | from `preflight_apparmor_userns` |
| subuid/subgid >= 165535 | linux+podman | from `preflight_subid_grant` |
| `/dev/fuse` accessible | linux | scenario 12 |
| cgroup v2 | linux | scenario 10 |

### Phase 1 — advisory

| Check | Applies | Origin |
|---|---|---|
| CLI and engine agree | all | **new** — 2026-08-15 `DOCKER_HOST` bug |
| home volume ownership matches uid | podman rootless | **new** — the EACCES wall |
| SELinux enforcing | linux | Fedora cell; `dev` handles it, worth surfacing |
| free disk >= 3 GB | all | `docs/ci-testing.md` image cache |
| free RAM >= 6 GB when nested | all | `docs/ci-testing.md` OOM warning |
| `GITHUB_TOKEN` carries no scopes | all | migrated from the existing warning |

Had `dev doctor` existed on the morning of 2026-08-15, `buildx` and
`CLI-and-engine-agree` would each have turned a multi-hour investigation into
one line of output.

## Testing

### Unit layer

Every check gets stubbed cases in the style of
`scripts/test/unit/test-engine-identity.sh`: no runtime contacted, all sixteen
exercised on any host. This is the bulk of the coverage and the only way
macOS-only checks are verified from Linux. Depends on the probe-indirection
constraint above.

### Scenario layer

One new container-free scenario, `51-doctor.sh`, asserting the contract:

- exit 0 on a good host
- exit 1 with the failing check named when a prerequisite is masked
- `--dind` promoting nested checks from advisory to blocking
- ASCII rendering when stdout is not a tty

### Privilege tagging

Each scenario declares what it needs, alongside the existing `# platform:`
field:

```bash
# platform: linux
# privilege: root        # or: user
```

`run-all.sh` filters on it. Scenarios manipulating host state (sysctls,
apparmor, package installs) are `root`; the rest are `user`. This is what makes
a rootless cell honest rather than one that silently skips half its suite.

### Matrix

Five cells:

| Cell | Runs |
|---|---|
| Debian 13 · rootful docker | full suite |
| Fedora 41 · rootful docker | full suite (SELinux enforcing) |
| Ubuntu 24.04 · rootful docker | full suite |
| Ubuntu 24.04 · rootless podman | `privilege: user` subset — new |
| macOS 14 · podman (GHA) | unit suite + `dev doctor` smoke |

Every cell asserts `dev doctor` exits 0 before running anything else. If the
doctor cannot certify the host, the suite result is meaningless — precisely the
failure mode that produced the truncated summary on 2026-08-15.

### Folded-in fixes

- `run-all.sh:72`'s install gate becomes "ask `dev doctor`" instead of keeping
  its own idea of a working host. That drift is what started this workstream.
- The rootless cell is what would have caught scenarios 41–44 and 46 rotting
  undetected under rootful podman.

### Open question, to resolve during implementation

Whether `podman machine` can start on GitHub's macOS runners is unverified.

**Run 1 (2026-08-15, `macos-14`) did not answer it.** `podman machine init`
succeeded in 44s, then `start` failed with:

```
Error: exec: "krunkit": executable file not found in $PATH
```

podman 6.0 on macOS defaults to the **libkrun** provider, which shells out to
an external `krunkit` binary that `brew install podman` does not pull in. That
is a packaging gap, not a statement about the runner's ability to host a VM.
`applehv` is podman's built-in macOS provider and needs no extra binary. The
probe now takes a `provider` input defaulting to `applehv`; re-run before
concluding anything. Runner facts for sizing: Apple M1 (Virtual), 3 CPU,
7 GiB RAM, 40 GiB free.

**Run 1 was still worth it** — it found four real defects that had nothing to
do with the question asked:

1. `test-engine-identity` failed on macOS: `detect_runtime` branches on
   `uname -s`, and its Linux-only cases inverted on Darwin. Fixed by routing
   the branch through a `_host_os` indirection, which is the probe-indirection
   constraint above arriving early. The suite now covers both platforms'
   branches from either platform.
2. `test-acquire-image` called `sha256sum`, which macOS does not ship, while
   the file it sources already defines the portable `sha256_of` wrapper.
3. Five "unit" tests shell out to `./dev`, which calls `ensure_runtime_ready`
   and exits when no podman machine is running. **They are not unit tests on
   macOS.** See below.
4. `dev status` and `dev up --dry-run` both refuse when the machine is down.

Findings 3 and 4 are a design input, not just bugs: `--dry-run` prints a
command without executing it, and `dev status` and `dev doctor` must work on a
machine where nothing is set up. Requiring a running VM for any of them
defeats the purpose. **`ensure_runtime_ready` should gate only operations that
actually touch the engine** — the doctor work should fix this, and
`podman machine running` becomes a `block` check for operations that need it
rather than a blanket precondition.

`.github/workflows/macos-probe.yml` exists to answer it: a `workflow_dispatch`
job that installs podman, times `machine init` and `machine start`, runs a
nested container, exercises the `dev` CLI on a bare Mac, runs the unit suite,
and writes a verdict to the job summary. Every probe is `continue-on-error`, so
one manual run collects every answer rather than stopping at the first failure.

Run it against `macos-14` before the matrix work in increment 2 begins, record
the answer here, and delete the workflow — its output is an answer, not a gate.

If `machine start` fails, the macOS cell degrades to unit-suite plus
`dev doctor` without a VM, and the manual Apple Silicon session below becomes
the only real-hardware coverage.

Note: `workflow_dispatch` only exposes the "Run workflow" button for workflows
present on the repository's **default branch**, so the probe has to reach
`main` before it can be run by hand.

## Release gates

In order:

1. Unit suite green on every developer platform
2. Four Linux matrix cells green
3. macOS GHA smoke green (or documented as degraded, per the open question)
4. **Manual Apple Silicon sanity session**, run by the repo owner on a real
   Mac, covering `dev doctor`, `dev up`, `dev shell`, and `podman machine`
   lifecycle. This is a required gate, not a courtesy check: it is the only
   place real macOS hardware is exercised.
5. Org rollout

## Sequencing

Two shippable increments:

1. **Registry + `dev doctor`** — the catalogue, the verb, the `dev up`
   integration, and the unit layer. On its own this gives a newcomer a good
   first run.
2. **Matrix expansion** — privilege tagging, the rootless cell, the macOS cell,
   scenario 51, and the `run-all.sh` gate fix. Locks increment 1 in.
