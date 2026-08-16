# CI testing — local reproduction

The CI pipeline boots a fresh Fedora / Debian / Ubuntu VM in QEMU per
matrix cell and runs `scripts/test/run-all.sh` inside. The same launcher
that CI uses also runs on a developer laptop with the same arguments.

## Prerequisites

### Linux
```
sudo apt install qemu-system-x86 qemu-utils cloud-image-utils \
    openssh-client rsync shellcheck
```

`/dev/kvm` must be readable+writable by your user (group `kvm` on most
distros).

### macOS
```
brew install qemu cdrtools openssh rsync shellcheck
```

KVM is unavailable; QEMU will use HVF (Apple Silicon) or fall back to
TCG (Intel without nested virt). TCG is correct but ~10× slower.

### Disk
~3 GB free for cached qcow2 images. Cache lives at
`${XDG_CACHE_HOME:-~/.cache}/devcontainer-ci/images/<distro>/`.

### RAM
The launcher allocates 4 GiB to the VM (`-m 4096`). The in-VM suite
itself runs `--dind`, which adds another ~1-2 GiB of pressure. Plan for
~6 GiB free RAM on the host, or expect the kernel to OOM-kill QEMU
mid-run. GitHub Actions `ubuntu-24.04` runners ship 16 GiB so this is
non-issue in CI.

## Running a CI cell locally

```
bash scripts/test/run-in-vm.sh fedora       # full suite in Fedora 41
bash scripts/test/run-in-vm.sh debian       # Debian 13
bash scripts/test/run-in-vm.sh ubuntu       # Ubuntu 24.04
```

### Single-command e2e

`scripts/test/run-e2e.sh` is the easy entry point: auto-installs QEMU
the first time, ensures `/dev/kvm` is writable, walks every distro
under `scripts/test/vms/`, and prints a PASS/FAIL/SKIP summary.

```
bash scripts/test/run-e2e.sh                  # all distros
bash scripts/test/run-e2e.sh fedora           # one distro
bash scripts/test/run-e2e.sh ubuntu fedora    # subset
```

### From inside `./dev up --maint`

Maintenance containers passthrough `/dev/kvm` (when present on the host)
and have sudo + no firewall, so the same command works without leaving
the sandbox:

```
./dev up --maint
# inside the container:
bash scripts/test/run-e2e.sh
```

Normal-mode and `--dind` containers don't mount `/dev/kvm` and can't run
the launcher (would fall through to TCG, ~10× slower, impractical for
the full suite).

After the run, logs land at:
- `scripts/test/last-run-<distro>.log` — full per-scenario output
- `scripts/test/last-summary-<distro>.log` — PASS/FAIL/SKIP table
- `scripts/test/serial-<distro>.log` — kernel serial console (failures only)
- `scripts/test/cloud-init-output-<distro>.log` — cloud-init log (failures only)

## The two Linux cells

The suite runs in two configurations, and they test different things.

```bash
sudo bash scripts/test/run-all.sh     # rootful docker, all 40 scenarios
bash scripts/test/run-rootless.sh     # rootless podman, the user subset, no sudo
```

Scenarios declare the privilege they need alongside the platform they need:

```bash
# platform: linux
# privilege: root
```

`root` means the scenario changes host state — sysctls, AppArmor profiles,
package installs, device nodes — and cannot run where sudo is unavailable.
`user` means it needs only a working container runtime. Nine of the 40 are
`root`. `run-all.sh` filters on the tag via `DEV_TEST_PRIVILEGE`; unset means
"run everything", so the existing invocation is unchanged.

`run-rootless.sh` exists because every other cell is rootful, while the
project's own recommended Linux setup is rootless podman. Nothing tested that
path until it was added, which is how a `docker buildx` assumption in the test
library and two rootless-hostile behaviours in the agent-inject scenario
survived unnoticed.

### Baselines: CI is the source of truth

`.github/workflows/ci.yml` — the `vm-matrix` (Debian/Ubuntu, full 40-scenario
suite per distro), `rootless-linux` (the `user`-privilege subset under
rootless podman), and `macos-checks` jobs — is the authoritative pass/fail
signal for this project. All three gate the `ci` job; none run with
`continue-on-error` (last bootstrapped to a green run 2026-08-16, run
31938260294). For current numbers, read the job's own log/summary artifact
rather than a number written down here, since a hard-coded tally goes stale
the moment CI's environment or the scenario set changes.

A local `sudo bash scripts/test/run-all.sh` / `bash scripts/test/run-rootless.sh`
run is useful for iterating on a fix before pushing, but treat any pass/fail
tally it produces as **indicative only, not a baseline to compare against**:
it depends on host state CI doesn't share with your machine — most notably
`kernel.apparmor_restrict_unprivileged_userns` and the subuid/subgid grant,
which gate every `--dind`/`--pind` scenario and vary between hosts. Compare
the failure **set**, not just the tally, if you do compare two local runs —
a run can hit the same count with a different set. Set `GITHUB_TOKEN` before
any local run: the anonymous 60/hr GitHub API limit is shared per-IP with
everything else on the host and is usually already spent by the time a run
reaches the image-building scenarios, which fails those scenarios with no
rate-limit text in the log.

### Comparing runs

Two things will silently produce nonsense:

1. **Reading `scripts/test/last-run.log` twice.** It is shared and truncated per
   run. Capture each run to its own file, or you are comparing one run with
   itself.
2. **Running two suites concurrently.** They share one `generic-devcontainer`
   image tag, one `dev-<workspace>` container namespace and one volume
   namespace, with no isolation. Concurrent runs corrupt each other and can
   agree with each other while agreeing with nothing reproducible.

A baseline is only meaningful from a defined starting state with nothing else
touching the machine.

### macOS

There is no macOS integration cell and cannot be one on GitHub Actions: their
macOS runners are themselves VMs without nested virtualization, so
`podman machine` cannot start (confirmed 2026-08-15 — `vfkit exited
unexpectedly`). The `macos-checks` CI job therefore runs no containers. It runs
the unit suite and checks that `dev doctor` still reports on a machine where
nothing is set up. Real macOS integration coverage comes only from a manual
session on Apple Silicon.

## Debugging a single scenario

```
bash scripts/test/run-in-vm.sh fedora \
    --cmd "bash scripts/test/scenarios/14-selinux-enforcing.sh"
```

## Interactive shell inside a VM

```
bash scripts/test/run-in-vm.sh fedora --shell
```

Drops into an SSH session inside the booted VM after cloud-init
finishes. Exit the shell to tear down.

## Running lint

```
bash scripts/lint.sh
```

Runs shellcheck on all shell scripts, hadolint on `Dockerfile`, and
actionlint on `.github/workflows/*.yml`. Hadolint and actionlint
binaries are downloaded (sha256-pinned) to
`~/.cache/devcontainer-ci/bin/` on first run.

## Porting to a different CI

The launcher and lint script are self-contained. To run on GitLab CI,
Forgejo, drone, Buildkite, or a self-hosted runner: install the
prerequisites above, `git clone`, then call `bash scripts/lint.sh`
and `bash scripts/test/run-in-vm.sh <distro>`. The only GitHub-Actions-
specific pieces in `.github/workflows/ci.yml` are `actions/checkout`,
`actions/cache`, and `actions/upload-artifact` — all trivially
replaced.

## When the cache hurts

If a cached image becomes corrupt or the upstream image changes, edit
the corresponding `scripts/test/vms/<distro>.conf` to update
`IMAGE_SHA256` (and `IMAGE_URL` if the URL moved). The launcher detects
the new sha and re-downloads.
