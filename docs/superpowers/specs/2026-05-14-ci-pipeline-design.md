# CI pipeline — design

Date: 2026-05-14
Status: approved (brainstorming)

## Goal

Verify the container-creation behavior of this repo (the `dev` script,
Dockerfile, entrypoint, firewall, and DinD wiring) end-to-end on every
pull request, on a real Linux kernel of our choosing, with no kernel
state shared between runs.

Fidelity to real developer use takes precedence over speed. CI feedback
in 20–30 minutes per PR is acceptable.

## Non-goals

- A "fast smoke" PR tier. Every PR runs the full matrix.
- macOS coverage in CI. The two darwin scenarios (90, 91) stay manual
  for now.
- Reproducibility of build outputs at bit-for-bit level. Reproducibility
  of *test results* is the bar.
- Coupling to GitHub Actions specifically. GH Actions is the first
  consumer, but the design must port to any CI host that has QEMU.

## Constraints

- Tests must run on a **real Linux kernel** chosen by us, not the kernel
  of whatever container the CI host happens to give us. SELinux
  enforcing (`scenarios/14-selinux-enforcing.sh`) cannot be exercised
  any other way.
- Test state must not leak between runs (cgroup leftovers, masked
  runtimes, sysctl mutations).
- The same commands must work locally on a developer laptop. "It only
  runs in CI" is a regression.
- Linters and the VM launcher must function without GitHub-specific
  features or actions; CI hosts are interchangeable.

## Architecture

One launcher script, three distro config files, one thin GH Actions
workflow. The launcher is the primary artifact; the workflow is
disposable.

```
scripts/test/
  run-all.sh                 # existing — orchestrator, runs INSIDE the VM
  run-in-vm.sh               # NEW — boots distro VM, runs the orchestrator
  vms/
    fedora.conf              # NEW — image URL, sha256, packages, kernel cmdline
    debian.conf              # NEW
    ubuntu.conf              # NEW
  lib/
    ci.sh                    # NEW (optional) — ci_log_phase helper
scripts/
  lint.sh                    # NEW — shellcheck + hadolint + actionlint
.github/workflows/
  ci.yml                     # NEW — calls lint.sh and run-in-vm.sh in a matrix
docs/
  ci-testing.md              # NEW — how to reproduce a CI cell locally
```

### Launcher contract — `scripts/test/run-in-vm.sh`

- **Inputs:** distro name (`fedora` / `debian` / `ubuntu`), optional
  `--cmd "<bash-command>"`, optional `--shell` for interactive debug.
- **Default command:** `bash scripts/test/run-all.sh`.
- **Required host tools:** `bash`, `qemu-system-x86_64`, `qemu-img`,
  `ssh`, `scp`, `rsync`, `curl`, and one of `cloud-localds` /
  `xorriso` / `mkisofs` (auto-detect).
- **Exit code:** the in-VM command's exit code.
- **Side effects on host:** writes
  `scripts/test/last-run-<distro>.log` and
  `scripts/test/last-summary-<distro>.log`; on failure also writes
  `scripts/test/serial-<distro>.log` and
  `scripts/test/cloud-init-output-<distro>.log`. Maintains an image
  cache at `${XDG_CACHE_HOME:-$HOME/.cache}/devcontainer-ci/images/`.
  No other persistent state.
- **Acceleration policy:** `kvm` if `/dev/kvm` is writable; `hvf` on
  macOS if QEMU lists it; `tcg` fallback otherwise.

### Distro config format — `scripts/test/vms/<distro>.conf`

Plain bash, sourced by the launcher. No parser.

```bash
# fedora.conf — example
IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
IMAGE_SHA256="<pinned at plan-writing time>"
CLOUD_USER="fedora"
PACKAGES="docker-ce docker-buildx-plugin podman jq rsync"
PACKAGE_INSTALL_CMD="dnf install -y"
EXTRA_KERNEL_CMDLINE="selinux=1 enforcing=1"
```

Adding a new distro = drop a new `.conf` and a matrix entry. The
launcher itself is distro-agnostic.

## VM lifecycle (inside the launcher)

Eight phases, each with an explicit timeout and a postmortem artifact.

| # | Phase | Timeout | Postmortem on failure |
|---|-------|---------|------------------------|
| 1 | Acquire image (cache + sha256 verify) | 5 min | curl stderr |
| 2 | Generate cloud-init seed ISO | 30 s | seed contents |
| 3 | Boot QEMU, wait for SSH | 5 min | `serial.log` |
| 4 | `cloud-init status --wait` | 5 min | `cloud-init-output.log` |
| 5 | Rsync workspace to `/workspace` in VM | 2 min | rsync stderr |
| 6 | Exec command inside VM | 45 min | full stdout/stderr |
| 7 | Retrieve `last-run.log` / `last-summary.log` | 30 s | scp stderr |
| 8 | Teardown (kill PID, rm temp dir) | 30 s | n/a |

### Key invariants

- **Read-only base image, COW overlay per run.** `qemu-img create -f
  qcow2 -b base.qcow2 -F qcow2 overlay.qcow2`. The cached base is
  never written to. Each run is on a fresh disk.
- **Checksum-pinned images.** Verified after download; mismatch is
  fatal. Upstream changing an image silently is a known supply-chain
  risk for this kind of CI.
- **Ephemeral SSH key per run.** Generated with `ssh-keygen -t ed25519
  -N ''`, embedded in cloud-init's `user-data`, discarded with the run
  dir.
- **User-mode networking with one forwarded port.** `-netdev
  user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22`. No bridge, no tap,
  no host-network exposure. `$SSH_PORT` is picked from a free port at
  launch.
- **Headless, daemonized, PID-file-tracked.** `-display none -daemonize
  -pidfile vm.pid -serial file:serial.log`. The `trap EXIT` always
  kills by PID and removes the run dir — no orphan QEMU processes
  even on SIGINT.

### QEMU invocation (canonical)

```
qemu-system-x86_64 \
  -machine q35,accel=$ACCEL \
  -cpu host \              # 'max' if accel=tcg
  -smp 4 -m 4096 \
  -drive file=$RUN_DIR/overlay.qcow2,if=virtio \
  -drive file=$RUN_DIR/seed.iso,if=virtio,format=raw \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
  -device virtio-net-pci,netdev=n0 \
  -display none -daemonize \
  -pidfile $RUN_DIR/vm.pid \
  -serial file:$RUN_DIR/serial.log
```

`-smp 4 -m 4096` is chosen so the in-VM test suite — which itself
runs `--dind` — has room. Lowering either tends to surface as
spurious DinD start failures.

## Workspace transfer

`rsync -a --delete --exclude '.git' --exclude 'scripts/test/last-*.log'
. <CLOUD_USER>@127.0.0.1:/workspace/`, then `sudo chown -R
<CLOUD_USER>:<CLOUD_USER> /workspace` inside the VM. The cloud user
is UID 1000 on all three target distros, which matches the in-image
`vscode` user — keeping these aligned avoids UID drift between the
host-side rsync (which may write the developer-laptop's UID into file
metadata) and the in-container build.

`.git` is excluded because it's not needed by the test suite and is
the largest contributor to transfer time. If a future scenario needs
git history, switch to a fresh clone strategy then.

## CI workflow

`.github/workflows/ci.yml` with two jobs, both on `ubuntu-24.04`:

### `lint` job (~1 min)

- Installs shellcheck, hadolint, actionlint.
- Runs `bash scripts/lint.sh`. The script is the source of truth — no
  lint commands are inlined in YAML.
- Fails the workflow on any lint error.
- Runs in parallel with `vm-matrix` for fast author feedback.

### `vm-matrix` job (~20–30 min wall-clock)

- `strategy.fail-fast: false`, `strategy.matrix.distro: [fedora,
  debian, ubuntu]`.
- Steps per cell:
  1. `actions/checkout@v4`.
  2. `sudo apt-get install -y qemu-system-x86 qemu-utils
     cloud-image-utils openssh-client rsync`.
  3. Verify `/dev/kvm` is writable; log accel choice.
  4. `actions/cache@v4` on
     `~/.cache/devcontainer-ci/images/${{ matrix.distro }}`, keyed on
     the sha256 of the matching `.conf` file. Cold pulls only when the
     conf changes.
  5. `bash scripts/test/run-in-vm.sh ${{ matrix.distro }}`.
  6. `if: always()` upload-artifact: all `*-${{ matrix.distro }}.log`
     files under `scripts/test/`.
- Job-level timeout: 60 min (backstop — launcher phase timeouts fire
  first).
- Triggers: `pull_request`, `push` to `main`, `workflow_dispatch`.
  `concurrency.cancel-in-progress: true` per ref.

### Portability surface

Moving to GitLab/Forgejo/drone/Buildkite/local replaces only the GH-
Actions-specific pieces:

| GH Actions piece | Replacement on other CI |
|---|---|
| `actions/checkout@v4` | `git clone` |
| `actions/cache@v4` | platform cache, or skip (~1 min cold pull) |
| `actions/upload-artifact@v4` | `scp`, object-storage upload, or local inspection |

`scripts/lint.sh` and `scripts/test/run-in-vm.sh` are unchanged
across CI hosts.

## Lint scope and tool versions

- `shellcheck` on every `*.sh` tracked by git.
- `hadolint` on `Dockerfile`. Apt's hadolint lags badly; the script
  downloads a pinned release tarball with a checksum.
- `actionlint` on `.github/workflows/*.yml`. Same pinned-release
  pattern.

`scripts/lint.sh` is the single entry point. It is callable locally
and from CI with no arguments. Versions live as constants near the
top of the script.

## Local reproducibility

The repro story is "run the same script locally."

```
bash scripts/test/run-in-vm.sh fedora          # full cell
bash scripts/test/run-in-vm.sh fedora --shell  # interactive SSH after setup
bash scripts/test/run-in-vm.sh fedora \
    --cmd "bash scripts/test/scenarios/14-selinux-enforcing.sh"
                                               # one scenario
bash scripts/lint.sh                            # lint
```

Prereqs documented in `docs/ci-testing.md`:

- Linux: `sudo apt install qemu-system-x86 qemu-utils
  cloud-image-utils openssh-client rsync`.
- macOS: `brew install qemu cdrtools openssh rsync`. Slower (HVF or
  TCG, no KVM).
- Disk: ~3 GB free for the qcow2 cache.

The first run pulls and caches the distro images. Subsequent runs
boot in 1–2 min on KVM.

## Changes to the existing test suite

Kept minimal — the suite is already VM-friendly because it was
designed for an interactive VM with sudo + sysctl access.

- `scripts/test/run-all.sh`: **no change.** It already detects
  platform and walks scenarios.
- `scripts/test/scenarios/14-selinux-enforcing.sh`: **no change.**
  Currently SKIPs when SELinux isn't enabled; once Fedora's
  `enforcing=1` kicks in, it runs and passes (or fails — that's the
  point).
- `scripts/test/lib/ci.sh`: **new, optional.** Exposes
  `ci_log_phase "<name>"` for phase markers in the run log. Improves
  grep-ability; not load-bearing.

## Failure modes and how they surface

| Symptom | Phase | Postmortem artifact |
|---|---|---|
| Image redownload fails or checksum mismatch | 1 | curl output, expected vs actual sha |
| QEMU never accepts SSH within 5 min | 3 | `serial-<distro>.log` |
| Package install or runtime enable fails | 4 | `cloud-init-output-<distro>.log` |
| `dev --build` or a scenario fails inside the VM | 6 | `last-run-<distro>.log` + scenario stdout |
| In-VM test suite hangs > 45 min | 6 | partial `last-run.log`, serial console, scenario name in `last-run.log` |

All artifacts are uploaded `if: always()` so failures are debuggable
without re-running.

## Open implementation choices (deferred to plan)

These don't change the architecture; they're choices to make while
writing the plan.

- ISO tool: `cloud-localds` (Debian/Ubuntu only) vs `xorriso -as
  mkisofs` (portable). Auto-detect, prefer `cloud-localds` where
  available.
- Exact pinned cloud-image versions and sha256s for each distro.
- Linter version pins for `hadolint` and `actionlint`.
- Whether to also test on a self-hosted Hetzner runner (out of scope
  for v1; design accommodates it because the launcher is
  CI-host-agnostic).

## What this design buys us

After landing, every PR proves:

1. Lint is clean across bash, Dockerfile, and workflow YAML.
2. The container builds, boots, and applies firewall correctly on
   Fedora-with-SELinux-enforcing, Debian-stable, and Ubuntu 24.04 —
   three meaningfully different kernels and userlands.
3. **Scenario 14 (SELinux enforcing) is actually exercised** for
   the first time; it has been SKIPping on every developer machine.
4. Failures surface with phase-specific postmortem logs as build
   artifacts — debuggable without local repro.
5. Any developer can reproduce any CI cell on their laptop with a
   single command, no CI-system access required.
