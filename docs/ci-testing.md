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

### From inside `./dev --maintenance`

Maintenance containers passthrough `/dev/kvm` (when present on the host)
and have sudo + no firewall, so the same command works without leaving
the sandbox:

```
./dev --maintenance
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
