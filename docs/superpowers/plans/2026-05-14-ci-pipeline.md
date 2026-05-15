# CI Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a portable QEMU-based CI test pipeline that boots a fresh Fedora / Debian / Ubuntu VM per matrix cell and runs the existing `scripts/test/run-all.sh` suite inside, with a thin GitHub Actions wrapper.

**Architecture:** One bash launcher (`scripts/test/run-in-vm.sh`) that knows how to boot a named distro in QEMU, sync the workspace in, run the test suite, and ship logs back. Distro-specific details live in `scripts/test/vms/<distro>.conf`. The GH Actions workflow installs QEMU and calls the launcher — no business logic in YAML. The launcher is the primary artifact and must work identically on any CI host or developer laptop with QEMU installed.

**Tech Stack:** bash, QEMU/KVM, cloud-init, shellcheck, hadolint, actionlint, GitHub Actions YAML. No Python, no Ruby, no extra runtime.

**Spec:** `docs/superpowers/specs/2026-05-14-ci-pipeline-design.md`

**Branch:** `feature/ci-pipeline` (already exists; commit `578b23f` has the spec).

**Working note:** All edits happen inside the `/workspace` devcontainer. The host-side end-to-end smoke test (Task 14) MUST be run on the developer's host, NOT inside this container — QEMU + KVM is not available inside the devcontainer.

---

## File map

| File | Purpose | Created by task |
|---|---|---|
| `scripts/lint.sh` | Single entry point for shellcheck + hadolint + actionlint | 1 |
| `scripts/test/run-in-vm.sh` | The launcher — main + all phase functions | 2–10 |
| `scripts/test/vms/fedora.conf` | Fedora image URL, sha256, packages, kernel cmdline | 4 |
| `scripts/test/vms/debian.conf` | Debian config | 4 |
| `scripts/test/vms/ubuntu.conf` | Ubuntu config | 4 |
| `scripts/test/unit/test-runner.sh` | Walks `test-*.sh`, prints PASS/FAIL summary | 2 |
| `scripts/test/unit/test-arg-parsing.sh` | Unit tests | 2 |
| `scripts/test/unit/test-conf-loading.sh` | Unit tests | 3 |
| `scripts/test/unit/test-pick-free-port.sh` | Unit tests | 5 |
| `scripts/test/unit/test-acquire-image.sh` | Unit tests | 6 |
| `scripts/test/unit/test-make-seed-iso.sh` | Unit tests | 8 |
| `.github/workflows/ci.yml` | Lint + VM matrix workflow | 11 |
| `docs/ci-testing.md` | Local repro instructions | 13 |

No existing files are modified.

---

## Task 1: Lint scaffolding

**Files:**
- Create: `scripts/lint.sh`

We start with lint so every subsequent file gets checked as soon as it lands. The script auto-installs pinned hadolint and actionlint binaries to `~/.cache/devcontainer-ci/bin/` on first run; shellcheck comes from the system package.

- [ ] **Step 1.1: Write `scripts/lint.sh`**

```bash
#!/usr/bin/env bash
# scripts/lint.sh — single entry point for repo linting.
# Runs: shellcheck on *.sh, hadolint on Dockerfile, actionlint on
# .github/workflows/*.yml. Pins hadolint and actionlint versions and
# fetches them on first run; shellcheck comes from the system.
set -euo pipefail

HADOLINT_VERSION="2.12.0"
HADOLINT_SHA256_LINUX_X64=""    # filled in by Step 1.2
ACTIONLINT_VERSION="1.7.7"
ACTIONLINT_SHA256_LINUX_X64=""  # filled in by Step 1.2

BIN_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/devcontainer-ci/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

uname_m=$(uname -m)
uname_s=$(uname -s | tr '[:upper:]' '[:lower:]')

ensure_hadolint() {
    if command -v hadolint >/dev/null 2>&1; then return 0; fi
    local arch_tag="x86_64"
    [ "$uname_m" = "aarch64" ] || [ "$uname_m" = "arm64" ] && arch_tag="arm64"
    local url="https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-${uname_s^}-${arch_tag}"
    echo "Fetching hadolint ${HADOLINT_VERSION}..." >&2
    curl --fail --retry 3 --retry-connrefused -L -o "$BIN_DIR/hadolint" "$url"
    if [ "$uname_s" = "linux" ] && [ "$arch_tag" = "x86_64" ]; then
        local actual
        actual=$(sha256sum "$BIN_DIR/hadolint" | awk '{print $1}')
        if [ "$actual" != "$HADOLINT_SHA256_LINUX_X64" ]; then
            echo "hadolint checksum mismatch: expected=$HADOLINT_SHA256_LINUX_X64 actual=$actual" >&2
            rm -f "$BIN_DIR/hadolint"; return 1
        fi
    fi
    chmod +x "$BIN_DIR/hadolint"
}

ensure_actionlint() {
    if command -v actionlint >/dev/null 2>&1; then return 0; fi
    local arch_tag="amd64"
    [ "$uname_m" = "aarch64" ] || [ "$uname_m" = "arm64" ] && arch_tag="arm64"
    local tarball="actionlint_${ACTIONLINT_VERSION}_${uname_s}_${arch_tag}.tar.gz"
    local url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${tarball}"
    echo "Fetching actionlint ${ACTIONLINT_VERSION}..." >&2
    local tmp; tmp=$(mktemp -d)
    curl --fail --retry 3 --retry-connrefused -L -o "$tmp/$tarball" "$url"
    if [ "$uname_s" = "linux" ] && [ "$arch_tag" = "amd64" ]; then
        local actual
        actual=$(sha256sum "$tmp/$tarball" | awk '{print $1}')
        if [ "$actual" != "$ACTIONLINT_SHA256_LINUX_X64" ]; then
            echo "actionlint checksum mismatch: expected=$ACTIONLINT_SHA256_LINUX_X64 actual=$actual" >&2
            rm -rf "$tmp"; return 1
        fi
    fi
    tar -xzf "$tmp/$tarball" -C "$tmp"
    mv "$tmp/actionlint" "$BIN_DIR/actionlint"
    chmod +x "$BIN_DIR/actionlint"
    rm -rf "$tmp"
}

if [ -z "$HADOLINT_SHA256_LINUX_X64" ] || [ -z "$ACTIONLINT_SHA256_LINUX_X64" ]; then
    echo "lint.sh: SHA256 constants are empty — see Step 1.2 of the plan." >&2
    exit 2
fi

fail=0

echo "=== shellcheck ==="
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck is required. Install via 'apt install shellcheck' or 'brew install shellcheck'." >&2
    exit 2
fi
mapfile -d '' shell_files < <(git ls-files -z '*.sh' 'dev' 'entrypoint.sh' 'firewall-init.sh' 'dind-init.sh' 2>/dev/null)
if [ ${#shell_files[@]} -gt 0 ]; then
    if ! shellcheck -x "${shell_files[@]}"; then fail=1; fi
else
    echo "(no shell files tracked yet)"
fi

echo
echo "=== hadolint ==="
ensure_hadolint
if [ -f Dockerfile ]; then
    if ! hadolint Dockerfile; then fail=1; fi
fi

echo
echo "=== actionlint ==="
if [ -d .github/workflows ] && compgen -G ".github/workflows/*.y*ml" >/dev/null; then
    ensure_actionlint
    if ! actionlint; then fail=1; fi
else
    echo "(no workflows yet)"
fi

exit "$fail"
```

- [ ] **Step 1.2: Verify and pin upstream SHA256s for hadolint + actionlint**

The two constants are empty placeholders. Fetch the canonical sha256 from each upstream release and paste it in. This is a one-time act, done before the script can run at all.

```bash
# hadolint 2.12.0 — sha256sum the actual binary we'll download.
curl --fail --retry 3 -L -sS -o /tmp/hadolint \
    "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64"
HADOLINT_SHA=$(sha256sum /tmp/hadolint | awk '{print $1}')
echo "HADOLINT_SHA256_LINUX_X64=\"$HADOLINT_SHA\""

# actionlint 1.7.7 — sha256sum the tarball.
curl --fail --retry 3 -L -sS -o /tmp/actionlint.tgz \
    "https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz"
ACTIONLINT_SHA=$(sha256sum /tmp/actionlint.tgz | awk '{print $1}')
echo "ACTIONLINT_SHA256_LINUX_X64=\"$ACTIONLINT_SHA\""

# Cross-check against upstream-published checksums (some releases ship a
# .sha256 file alongside; if present, compare).
curl --fail --retry 3 -L -sS \
    "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64.sha256" \
    2>/dev/null | head -1 || echo "(no upstream .sha256 published — relying on local hash)"

rm -f /tmp/hadolint /tmp/actionlint.tgz
```

Edit `scripts/lint.sh` and paste each sha into the corresponding constant. The script will refuse to run with empty values.

- [ ] **Step 1.3: Make executable and run**

```bash
chmod +x scripts/lint.sh
bash scripts/lint.sh
```

Expected: shellcheck section passes (it may complain about existing `dev`, `entrypoint.sh`, etc. — if so, **stop and fix those first** before continuing, because every subsequent task will keep failing lint). Hadolint section runs against `Dockerfile`; treat any errors as findings to fix in a separate commit before proceeding. Actionlint section prints `(no workflows yet)`.

- [ ] **Step 1.4: If lint reveals pre-existing issues, fix them in a SEPARATE commit first**

```bash
# Investigate each finding individually. Fix in repo-relevant ways.
# Example: shellcheck SC2086 → add quoting; SC2155 → split declare-and-assign.
# Commit each logical group:
git add <fixed-files>
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "fix(lint): <what was fixed>"
```

If lint is clean already, skip this step.

- [ ] **Step 1.5: Commit lint script**

```bash
git add scripts/lint.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "$(cat <<'EOF'
ci: add scripts/lint.sh as single lint entry point

Pins hadolint and actionlint releases by sha256 so local and CI
converge. shellcheck comes from the system package.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Launcher skeleton + unit-test harness

**Files:**
- Create: `scripts/test/run-in-vm.sh`
- Create: `scripts/test/unit/test-runner.sh`
- Create: `scripts/test/unit/test-arg-parsing.sh`

Establishes the source-guard pattern so unit tests can source the launcher without triggering main, and lands a tiny test runner.

- [ ] **Step 2.1: Write the test runner**

```bash
mkdir -p scripts/test/unit
```

Create `scripts/test/unit/test-runner.sh`:

```bash
#!/usr/bin/env bash
# scripts/test/unit/test-runner.sh — walks test-*.sh, prints summary.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0; FAILED=()
for t in "$DIR"/test-*.sh; do
    [ "$(basename "$t")" = "test-runner.sh" ] && continue
    name=$(basename "$t" .sh)
    if bash "$t" >/tmp/unit-out 2>&1; then
        echo "PASS $name"
        PASS=$((PASS+1))
    else
        echo "FAIL $name"
        cat /tmp/unit-out | sed 's/^/  /'
        FAILED+=("$name")
        FAIL=$((FAIL+1))
    fi
done
echo
echo "Unit summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2.2: Write a failing arg-parsing test**

Create `scripts/test/unit/test-arg-parsing.sh`:

```bash
#!/usr/bin/env bash
# Unit: arg parsing
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Source launcher in test mode (guard suppresses main).
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

# No args -> usage on stderr, exit non-zero.
if out=$(parse_args 2>&1); then
    echo "expected parse_args with no args to fail"; exit 1
fi
echo "$out" | grep -q 'Usage:' || { echo "expected Usage in error output"; exit 1; }

# 'fedora' alone -> DISTRO=fedora, CMD default unset.
parse_args fedora
[ "${DISTRO:-}" = "fedora" ] || { echo "DISTRO=$DISTRO"; exit 1; }
[ "${CMD:-}" = "" ] || { echo "CMD should be empty, got: $CMD"; exit 1; }
[ "${SHELL_MODE:-0}" = "0" ] || { echo "SHELL_MODE should be 0"; exit 1; }

# --cmd "..." -> CMD set.
parse_args fedora --cmd "echo hello"
[ "$CMD" = "echo hello" ] || { echo "CMD=$CMD"; exit 1; }

# --shell -> SHELL_MODE=1.
parse_args fedora --shell
[ "$SHELL_MODE" = "1" ] || { echo "SHELL_MODE=$SHELL_MODE"; exit 1; }

# Unknown flag -> fail.
if parse_args fedora --bogus 2>/dev/null; then
    echo "expected --bogus to fail"; exit 1
fi

echo "ok"
```

- [ ] **Step 2.3: Verify the test fails (launcher doesn't exist yet)**

```bash
chmod +x scripts/test/unit/test-runner.sh scripts/test/unit/test-arg-parsing.sh
bash scripts/test/unit/test-runner.sh
```

Expected: `FAIL test-arg-parsing` with "No such file or directory" referencing run-in-vm.sh.

- [ ] **Step 2.4: Write the launcher skeleton**

Create `scripts/test/run-in-vm.sh`:

```bash
#!/usr/bin/env bash
# scripts/test/run-in-vm.sh — boots a named distro in QEMU, runs a
# command (default: bash scripts/test/run-all.sh) inside, returns its
# exit code. See docs/ci-testing.md for usage and prerequisites.
#
# Source guard: setting DEV_CI_TEST_MODE=1 before sourcing this file
# suppresses main, so unit tests can call individual functions.
set -u

usage() {
    cat <<EOF
Usage: $(basename "$0") <distro> [--cmd "<command>"] [--shell]

Boots <distro> in QEMU and runs the suite inside.

Arguments:
  <distro>            One of: fedora, debian, ubuntu (matching scripts/test/vms/<distro>.conf)
  --cmd "<command>"   Command to run inside the VM (default: bash scripts/test/run-all.sh)
  --shell             After cloud-init finishes, drop to an interactive SSH shell.

Environment:
  DEV_CI_CACHE_DIR    Override image cache (default: \${XDG_CACHE_HOME:-\$HOME/.cache}/devcontainer-ci)
EOF
}

DISTRO=""
CMD=""
SHELL_MODE=0

parse_args() {
    DISTRO=""
    CMD=""
    SHELL_MODE=0
    if [ $# -eq 0 ]; then usage >&2; return 1; fi
    DISTRO="$1"; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --cmd) CMD="${2:-}"; shift 2 ;;
            --shell) SHELL_MODE=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) echo "Unknown argument: $1" >&2; usage >&2; return 1 ;;
        esac
    done
    return 0
}

main() {
    parse_args "$@" || exit $?
    echo "Launcher skeleton — DISTRO=$DISTRO CMD='$CMD' SHELL_MODE=$SHELL_MODE"
    echo "(further phases land in subsequent tasks)"
}

if [ "${DEV_CI_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
```

```bash
chmod +x scripts/test/run-in-vm.sh
```

- [ ] **Step 2.5: Run unit tests**

```bash
bash scripts/test/unit/test-runner.sh
```

Expected: `PASS test-arg-parsing`, then `Unit summary: 1 passed, 0 failed`.

- [ ] **Step 2.6: Lint**

```bash
bash scripts/lint.sh
```

Expected: clean (or pre-existing issues; new files clean).

- [ ] **Step 2.7: Commit**

```bash
git add scripts/test/run-in-vm.sh scripts/test/unit/
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "$(cat <<'EOF'
ci: launcher skeleton + unit test harness

run-in-vm.sh exposes parse_args() with a source guard so unit tests
can drive it without triggering main. test-runner.sh walks unit/test-*.sh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Conf loading

**Files:**
- Modify: `scripts/test/run-in-vm.sh` (add `load_distro_conf` function)
- Create: `scripts/test/unit/test-conf-loading.sh`

A distro conf is a plain bash file with five required variables: `IMAGE_URL`, `IMAGE_SHA256`, `CLOUD_USER`, `PACKAGES`, `PACKAGE_INSTALL_CMD`. Optional: `POST_BOOT_CMDS` — shell commands appended to cloud-init's `runcmd:` block to set up per-distro kernel/security state (e.g. `setenforce 1` for Fedora's SELinux gate). The loader sources it and validates required keys.

- [ ] **Step 3.1: Write failing test**

Create `scripts/test/unit/test-conf-loading.sh`:

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT

# Good conf -> all vars populated.
cat > "$TMPDIR/good.conf" <<'EOF'
IMAGE_URL="https://example.invalid/x.qcow2"
IMAGE_SHA256="abc123"
CLOUD_USER="fedora"
PACKAGES="docker rsync"
PACKAGE_INSTALL_CMD="dnf install -y"
POST_BOOT_CMDS="setenforce 1"
EOF

load_distro_conf "$TMPDIR/good.conf"
[ "$IMAGE_URL" = "https://example.invalid/x.qcow2" ] || { echo "IMAGE_URL=$IMAGE_URL"; exit 1; }
[ "$IMAGE_SHA256" = "abc123" ] || { echo "IMAGE_SHA256=$IMAGE_SHA256"; exit 1; }
[ "$CLOUD_USER" = "fedora" ] || exit 1
[ "$PACKAGES" = "docker rsync" ] || exit 1
[ "$PACKAGE_INSTALL_CMD" = "dnf install -y" ] || exit 1
[ "$POST_BOOT_CMDS" = "setenforce 1" ] || exit 1

# Missing required var -> fail with clear message.
cat > "$TMPDIR/bad.conf" <<'EOF'
IMAGE_URL="https://example.invalid/x.qcow2"
CLOUD_USER="fedora"
PACKAGES="docker"
PACKAGE_INSTALL_CMD="dnf install -y"
EOF
if out=$(load_distro_conf "$TMPDIR/bad.conf" 2>&1); then
    echo "expected missing IMAGE_SHA256 to fail"; exit 1
fi
echo "$out" | grep -q 'IMAGE_SHA256' || { echo "expected IMAGE_SHA256 in error: $out"; exit 1; }

# Missing optional POST_BOOT_CMDS -> ok, var is empty.
cat > "$TMPDIR/no-extra.conf" <<'EOF'
IMAGE_URL="https://example.invalid/x.qcow2"
IMAGE_SHA256="abc"
CLOUD_USER="debian"
PACKAGES="docker"
PACKAGE_INSTALL_CMD="apt install -y"
EOF
load_distro_conf "$TMPDIR/no-extra.conf"
[ -z "${POST_BOOT_CMDS:-}" ] || { echo "POST_BOOT_CMDS should be empty"; exit 1; }

# Missing file -> fail.
if load_distro_conf "$TMPDIR/nope.conf" 2>/dev/null; then
    echo "expected missing file to fail"; exit 1
fi

echo "ok"
```

- [ ] **Step 3.2: Run and verify it fails**

```bash
bash scripts/test/unit/test-runner.sh
```

Expected: `FAIL test-conf-loading` with `load_distro_conf: command not found`.

- [ ] **Step 3.3: Implement `load_distro_conf` in `scripts/test/run-in-vm.sh`**

Insert before `main()`:

```bash
load_distro_conf() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "Conf not found: $path" >&2
        return 1
    fi
    # Reset known vars so a missing required var isn't inherited.
    IMAGE_URL=""; IMAGE_SHA256=""; CLOUD_USER=""
    PACKAGES=""; PACKAGE_INSTALL_CMD=""; POST_BOOT_CMDS=""
    # shellcheck disable=SC1090
    . "$path"
    local missing=()
    [ -z "$IMAGE_URL" ] && missing+=(IMAGE_URL)
    [ -z "$IMAGE_SHA256" ] && missing+=(IMAGE_SHA256)
    [ -z "$CLOUD_USER" ] && missing+=(CLOUD_USER)
    [ -z "$PACKAGES" ] && missing+=(PACKAGES)
    [ -z "$PACKAGE_INSTALL_CMD" ] && missing+=(PACKAGE_INSTALL_CMD)
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Conf $path missing required vars: ${missing[*]}" >&2
        return 1
    fi
    return 0
}
```

- [ ] **Step 3.4: Run unit tests**

```bash
bash scripts/test/unit/test-runner.sh
```

Expected: 2 passed, 0 failed.

- [ ] **Step 3.5: Lint + commit**

```bash
bash scripts/lint.sh
git add scripts/test/run-in-vm.sh scripts/test/unit/test-conf-loading.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: launcher loads distro conf with required-var validation

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Distro conf files

**Files:**
- Create: `scripts/test/vms/fedora.conf`
- Create: `scripts/test/vms/debian.conf`
- Create: `scripts/test/vms/ubuntu.conf`

Image versions chosen for May 2026: Fedora 41 (mature, well-supported cloud images), Debian 13 (trixie, current stable), Ubuntu 24.04 LTS. Confs include the canonical upstream URLs; the engineer computes and pastes the sha256 in step 4.2.

- [ ] **Step 4.1: Write conf files with empty sha**

```bash
mkdir -p scripts/test/vms
```

Create `scripts/test/vms/fedora.conf`:

```bash
# Fedora 41 cloud image — SELinux enforcing in CI matrix.
# POST_BOOT_CMDS forces enforcing mode via cloud-init runcmd (rather than
# kernel cmdline) because the launcher boots from a disk image — there's
# no -kernel passed to QEMU, so -append would be silently ignored.
IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
IMAGE_SHA256="REPLACE_ME"
CLOUD_USER="fedora"
PACKAGES="docker docker-buildx podman jq rsync iptables-nft"
PACKAGE_INSTALL_CMD="dnf install -y --setopt=install_weak_deps=False"
POST_BOOT_CMDS="sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config && setenforce 1 || true"
```

Create `scripts/test/vms/debian.conf`:

```bash
# Debian 13 (trixie) cloud image — stable, no AppArmor by default.
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMAGE_SHA256="REPLACE_ME"
CLOUD_USER="debian"
PACKAGES="docker.io docker-buildx podman jq rsync"
PACKAGE_INSTALL_CMD="apt-get install -y --no-install-recommends"
POST_BOOT_CMDS=""
```

Create `scripts/test/vms/ubuntu.conf`:

```bash
# Ubuntu 24.04 LTS cloud image — happy-path baseline.
IMAGE_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
IMAGE_SHA256="REPLACE_ME"
CLOUD_USER="ubuntu"
PACKAGES="docker.io docker-buildx podman jq rsync"
PACKAGE_INSTALL_CMD="apt-get install -y --no-install-recommends"
POST_BOOT_CMDS=""
```

- [ ] **Step 4.2: Compute and paste sha256 for each image**

The image-acquisition function (Task 6) will refuse to run with `REPLACE_ME`. Fetch + sha each image, then paste:

```bash
for distro in fedora debian ubuntu; do
    url=$(grep '^IMAGE_URL=' scripts/test/vms/$distro.conf | cut -d'"' -f2)
    echo "=== $distro ==="
    echo "URL: $url"
    sha=$(curl --fail --retry 3 --retry-connrefused -L -sS "$url" | sha256sum | awk '{print $1}')
    echo "SHA: $sha"
    sed -i "s|^IMAGE_SHA256=.*|IMAGE_SHA256=\"$sha\"|" scripts/test/vms/$distro.conf
done
```

Verify no `REPLACE_ME` remains:

```bash
! grep -r REPLACE_ME scripts/test/vms/
```

Expected: command exits 0 (no matches).

- [ ] **Step 4.3: Lint + commit**

```bash
bash scripts/lint.sh
git add scripts/test/vms/
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: pin Fedora 41 / Debian 13 / Ubuntu 24.04 cloud images

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Free port picker

**Files:**
- Modify: `scripts/test/run-in-vm.sh` (add `pick_free_port`)
- Create: `scripts/test/unit/test-pick-free-port.sh`

- [ ] **Step 5.1: Write failing test**

Create `scripts/test/unit/test-pick-free-port.sh`:

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

# Returns a number in 10000..65000.
p=$(pick_free_port)
[[ "$p" =~ ^[0-9]+$ ]] || { echo "not numeric: $p"; exit 1; }
[ "$p" -ge 10000 ] && [ "$p" -le 65000 ] || { echo "out of range: $p"; exit 1; }

# Two consecutive calls should each return a free port (may be the same
# port if the prior one wasn't bound — that's fine).
p2=$(pick_free_port)
[[ "$p2" =~ ^[0-9]+$ ]] || exit 1

echo "ok"
```

- [ ] **Step 5.2: Verify failure**

```bash
bash scripts/test/unit/test-runner.sh
```

Expected: `FAIL test-pick-free-port`.

- [ ] **Step 5.3: Implement `pick_free_port` in `scripts/test/run-in-vm.sh`**

Insert before `main()`:

```bash
pick_free_port() {
    # Try up to 50 random ports in 10000..65000. Use `ss` if available
    # (Linux), `netstat -an` as POSIX-ish fallback (macOS).
    local port checker_cmd
    if command -v ss >/dev/null 2>&1; then
        checker_cmd="ss -tlnH"
    else
        checker_cmd="netstat -an"
    fi
    for _ in $(seq 1 50); do
        port=$((RANDOM % 55001 + 10000))
        if ! $checker_cmd 2>/dev/null | grep -qE "[.:]$port[[:space:]]+"; then
            echo "$port"
            return 0
        fi
    done
    echo "Could not find a free port after 50 attempts" >&2
    return 1
}
```

- [ ] **Step 5.4: Run + commit**

```bash
bash scripts/test/unit/test-runner.sh   # 3 passed
bash scripts/lint.sh
git add scripts/test/run-in-vm.sh scripts/test/unit/test-pick-free-port.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: pick_free_port helper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Image acquisition

**Files:**
- Modify: `scripts/test/run-in-vm.sh` (add `acquire_image`)
- Create: `scripts/test/unit/test-acquire-image.sh`

`acquire_image` is cache-aware: if the cached file matches the expected sha, return its path; otherwise download, verify, atomically move into the cache.

- [ ] **Step 6.1: Write failing test (uses a local file: URL so the test is hermetic)**

Create `scripts/test/unit/test-acquire-image.sh`:

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
DEV_CI_CACHE_DIR="$TMPDIR/cache"
export DEV_CI_CACHE_DIR

# Source: a small file we control.
echo "hello qemu world" > "$TMPDIR/src.qcow2"
sha=$(sha256sum "$TMPDIR/src.qcow2" | awk '{print $1}')

# First call: cache miss, downloads.
out=$(acquire_image "file://$TMPDIR/src.qcow2" "$sha" "testdistro")
[ -f "$out" ] || { echo "no output path"; exit 1; }
diff "$out" "$TMPDIR/src.qcow2" || { echo "content mismatch"; exit 1; }

# Second call: cache hit, no download. Make the source unreadable to prove
# the cache was used.
chmod 000 "$TMPDIR/src.qcow2"
out2=$(acquire_image "file://$TMPDIR/src.qcow2" "$sha" "testdistro")
[ "$out" = "$out2" ] || { echo "cache miss on hot path"; exit 1; }
chmod 644 "$TMPDIR/src.qcow2"

# Wrong sha -> fail.
if acquire_image "file://$TMPDIR/src.qcow2" "deadbeef" "testdistro2" 2>/dev/null; then
    echo "expected sha mismatch to fail"; exit 1
fi

# REPLACE_ME -> fail loudly.
if out=$(acquire_image "file://$TMPDIR/src.qcow2" "REPLACE_ME" "x" 2>&1); then
    echo "expected REPLACE_ME to fail"; exit 1
fi
echo "$out" | grep -q REPLACE_ME || { echo "expected REPLACE_ME message"; exit 1; }

echo "ok"
```

- [ ] **Step 6.2: Verify failure**

```bash
bash scripts/test/unit/test-runner.sh   # FAIL test-acquire-image
```

- [ ] **Step 6.3: Implement `acquire_image`**

Insert in `scripts/test/run-in-vm.sh` before `main()`:

```bash
acquire_image() {
    local url="$1" want_sha="$2" distro="$3"
    if [ "$want_sha" = "REPLACE_ME" ]; then
        echo "Distro conf for $distro has IMAGE_SHA256=REPLACE_ME; fill it in." >&2
        return 1
    fi
    local cache_root="${DEV_CI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/devcontainer-ci}"
    local cache_dir="$cache_root/images/$distro"
    local out="$cache_dir/$want_sha.qcow2"
    mkdir -p "$cache_dir"
    if [ -f "$out" ]; then
        local actual
        actual=$(sha256sum "$out" | awk '{print $1}')
        if [ "$actual" = "$want_sha" ]; then
            echo "$out"
            return 0
        fi
        echo "Cached file sha mismatch; redownloading: $out" >&2
        rm -f "$out"
    fi
    local tmp="$out.partial"
    curl --fail --retry 3 --retry-connrefused -L -sS -o "$tmp" "$url" >&2 || {
        rm -f "$tmp"; return 1
    }
    local actual
    actual=$(sha256sum "$tmp" | awk '{print $1}')
    if [ "$actual" != "$want_sha" ]; then
        echo "Downloaded image sha mismatch for $distro: expected=$want_sha actual=$actual" >&2
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"
    echo "$out"
}
```

- [ ] **Step 6.4: Run + commit**

```bash
bash scripts/test/unit/test-runner.sh   # 4 passed
bash scripts/lint.sh
git add scripts/test/run-in-vm.sh scripts/test/unit/test-acquire-image.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: acquire_image with sha-pinned cache

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: SSH key generation

**Files:**
- Modify: `scripts/test/run-in-vm.sh` (add `generate_ephemeral_ssh_key`)

Trivial enough to skip a unit test; integration test covers it (Task 10).

- [ ] **Step 7.1: Add function**

Insert in `scripts/test/run-in-vm.sh` before `main()`:

```bash
generate_ephemeral_ssh_key() {
    # Writes private key to $1, public key to $1.pub. Caller's responsibility
    # to clean up; trap usually handles via $RUN_DIR removal.
    local out="$1"
    ssh-keygen -t ed25519 -N '' -C "devcontainer-ci-$(date +%s)" -f "$out" >/dev/null
}
```

- [ ] **Step 7.2: Sanity smoke**

```bash
TMP=$(mktemp -d)
DEV_CI_TEST_MODE=1 . scripts/test/run-in-vm.sh
generate_ephemeral_ssh_key "$TMP/k"
[ -f "$TMP/k" ] && [ -f "$TMP/k.pub" ] && echo OK
rm -rf "$TMP"
```

Expected: `OK`.

- [ ] **Step 7.3: Commit**

```bash
bash scripts/lint.sh
git add scripts/test/run-in-vm.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: generate_ephemeral_ssh_key

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Cloud-init seed ISO generation

**Files:**
- Modify: `scripts/test/run-in-vm.sh` (add `make_seed_iso`)
- Create: `scripts/test/unit/test-make-seed-iso.sh`

`make_seed_iso` writes `user-data` and `meta-data` to a temp dir, then assembles an ISO using whichever tool is available: `cloud-localds` (preferred — Debian/Ubuntu) → `xorriso` → `mkisofs` / `genisoimage`. The function takes the path to write the ISO and the path to a directory holding `user-data` + `meta-data`.

- [ ] **Step 8.1: Write failing test**

Create `scripts/test/unit/test-make-seed-iso.sh`:

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

if ! command -v xorriso >/dev/null 2>&1 \
    && ! command -v mkisofs >/dev/null 2>&1 \
    && ! command -v genisoimage >/dev/null 2>&1 \
    && ! command -v cloud-localds >/dev/null 2>&1; then
    echo "skip: no ISO tool installed"
    exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/seed"
cat > "$TMP/seed/user-data" <<'EOF'
#cloud-config
hostname: test
EOF
cat > "$TMP/seed/meta-data" <<EOF
instance-id: test
local-hostname: test
EOF

make_seed_iso "$TMP/seed.iso" "$TMP/seed"
[ -s "$TMP/seed.iso" ] || { echo "iso empty"; exit 1; }
file "$TMP/seed.iso" | grep -qiE 'ISO 9660|UDF' || {
    echo "not an ISO: $(file "$TMP/seed.iso")"; exit 1
}

echo "ok"
```

- [ ] **Step 8.2: Verify failure**

```bash
bash scripts/test/unit/test-runner.sh   # FAIL test-make-seed-iso
```

- [ ] **Step 8.3: Implement `make_seed_iso`**

Insert before `main()`:

```bash
make_seed_iso() {
    local out="$1" seed_dir="$2"
    if [ ! -f "$seed_dir/user-data" ] || [ ! -f "$seed_dir/meta-data" ]; then
        echo "seed dir must contain user-data and meta-data" >&2
        return 1
    fi
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$out" "$seed_dir/user-data" "$seed_dir/meta-data"
        return $?
    fi
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -output "$out" -volid CIDATA -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data" 2>/dev/null
        return $?
    fi
    if command -v mkisofs >/dev/null 2>&1; then
        mkisofs -output "$out" -volid CIDATA -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data" 2>/dev/null
        return $?
    fi
    if command -v genisoimage >/dev/null 2>&1; then
        genisoimage -output "$out" -volid CIDATA -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data" 2>/dev/null
        return $?
    fi
    echo "Need one of: cloud-localds, xorriso, mkisofs, genisoimage" >&2
    return 1
}
```

- [ ] **Step 8.4: Run + commit**

```bash
bash scripts/test/unit/test-runner.sh   # 5 passed (or skips if no ISO tool)
bash scripts/lint.sh
git add scripts/test/run-in-vm.sh scripts/test/unit/test-make-seed-iso.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: make_seed_iso with cloud-localds/xorriso/mkisofs fallback

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Cloud-init user-data builder

**Files:**
- Modify: `scripts/test/run-in-vm.sh` (add `render_user_data`, `render_meta_data`)

These render the cloud-init YAML used by `make_seed_iso`. Pure functions: input is values, output is text on stdout.

- [ ] **Step 9.1: Add functions**

Insert before `main()` in `scripts/test/run-in-vm.sh`:

```bash
render_user_data() {
    # Args: cloud_user, ssh_public_key_text, package_install_cmd, packages, post_boot_cmds
    local cloud_user="$1" pubkey="$2" install_cmd="$3" packages="$4" post_boot="${5:-}"
    cat <<EOF
#cloud-config
hostname: devcontainer-ci
manage_etc_hosts: true
users:
  - name: ${cloud_user}
    groups: [wheel, sudo, docker]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
package_update: true
packages: []
runcmd:
  - ${install_cmd} ${packages}
  - systemctl enable --now docker || true
  - systemctl enable --now containerd || true
  - usermod -aG docker ${cloud_user} || true
EOF
    if [ -n "$post_boot" ]; then
        # Embed POST_BOOT_CMDS as a single shell line in runcmd. Quoting:
        # cloud-init parses YAML, so we use the bracketed list form to
        # avoid having to escape the shell command for YAML.
        printf '  - [bash, -c, %s]\n' "$(printf '%s' "$post_boot" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
    fi
}

render_meta_data() {
    cat <<EOF
instance-id: devcontainer-ci-$(date +%s)
local-hostname: devcontainer-ci
EOF
}
```

- [ ] **Step 9.2: Sanity smoke**

```bash
DEV_CI_TEST_MODE=1 . scripts/test/run-in-vm.sh
render_user_data fedora "ssh-ed25519 AAAA..." "dnf install -y" "docker rsync" "setenforce 1" \
    | tail -10
```

Expected: ends with a `runcmd:` block that includes `- [bash, -c, 'setenforce 1']` as the final entry.

- [ ] **Step 9.3: Commit**

```bash
bash scripts/lint.sh
git add scripts/test/run-in-vm.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: render_user_data + render_meta_data for cloud-init

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Full launcher main + integration (boot → run → cleanup)

**Files:**
- Modify: `scripts/test/run-in-vm.sh` (rewrite `main()` to wire all phases)

This is the integration step. The previous tasks shipped the building blocks. Now `main()` orchestrates them.

- [ ] **Step 10.1: Add detection + helper functions**

Insert in `scripts/test/run-in-vm.sh` before `main()`:

```bash
detect_accel() {
    if [ -w /dev/kvm ]; then echo kvm; return; fi
    if qemu-system-x86_64 -accel help 2>&1 | grep -qi hvf; then echo hvf; return; fi
    echo tcg
}

require_host_tools() {
    local missing=()
    for t in qemu-system-x86_64 qemu-img ssh scp rsync curl ssh-keygen sha256sum; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    # ISO tool — make_seed_iso checks too, but better to fail early.
    if ! command -v cloud-localds >/dev/null 2>&1 \
        && ! command -v xorriso >/dev/null 2>&1 \
        && ! command -v mkisofs >/dev/null 2>&1 \
        && ! command -v genisoimage >/dev/null 2>&1; then
        missing+=("cloud-localds|xorriso|mkisofs|genisoimage")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required host tools: ${missing[*]}" >&2
        echo "Linux: apt install qemu-system-x86 qemu-utils cloud-image-utils openssh-client rsync" >&2
        echo "macOS: brew install qemu cdrtools openssh rsync" >&2
        return 1
    fi
    return 0
}

ssh_in() {
    # Run a command in the VM. All args after $1 are the remote command.
    local port="$1"; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" \
        -p "$port" "$CLOUD_USER@127.0.0.1" "$@"
}

ssh_in_tty() {
    # Same as ssh_in but forces a TTY (-t) — needed when the in-VM command
    # invokes tools that detect tty (the existing test scenarios use $(tty)
    # in places). Calling ssh_in with "-t" would treat -t as a remote command,
    # so we need this separate wrapper.
    local port="$1"; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -t -i "$RUN_DIR/id_ed25519" \
        -p "$port" "$CLOUD_USER@127.0.0.1" "$@"
}

wait_for_ssh() {
    # Call ssh directly (NOT via ssh_in) so we can add -o ConnectTimeout=5
    # as an ssh option rather than a remote command.
    local port="$1" deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=5 -i "$RUN_DIR/id_ed25519" \
            -p "$port" "$CLOUD_USER@127.0.0.1" true 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    echo "VM did not accept SSH within 5 min" >&2
    return 1
}

log_phase() {
    echo
    echo "=== [phase] $* ==="
}
```

- [ ] **Step 10.2: Rewrite `main()` to orchestrate phases**

Replace the existing `main()` stub:

```bash
main() {
    parse_args "$@" || exit $?
    require_host_tools || exit 1

    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local conf="$REPO_ROOT/scripts/test/vms/$DISTRO.conf"
    load_distro_conf "$conf" || exit 1

    RUN_DIR=$(mktemp -d -t devcontainer-ci-XXXXXX)
    SSH_PORT=$(pick_free_port)
    ACCEL=$(detect_accel)

    cleanup() {
        local rc=$?
        if [ -f "$RUN_DIR/vm.pid" ]; then
            local pid; pid=$(cat "$RUN_DIR/vm.pid" 2>/dev/null || true)
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        fi
        # Always copy logs back to host workspace if they exist on the VM.
        if [ -n "${SSH_PORT:-}" ] && [ -f "$RUN_DIR/id_ed25519" ]; then
            for f in last-run.log last-summary.log; do
                scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
                    "$CLOUD_USER@127.0.0.1:/workspace/scripts/test/$f" \
                    "$REPO_ROOT/scripts/test/${f%.log}-$DISTRO.log" 2>/dev/null || true
            done
        fi
        if [ "$rc" -ne 0 ]; then
            [ -f "$RUN_DIR/serial.log" ] \
                && cp "$RUN_DIR/serial.log" "$REPO_ROOT/scripts/test/serial-$DISTRO.log" 2>/dev/null || true
            [ -f "$RUN_DIR/cloud-init-output.log" ] \
                && cp "$RUN_DIR/cloud-init-output.log" \
                "$REPO_ROOT/scripts/test/cloud-init-output-$DISTRO.log" 2>/dev/null || true
        fi
        rm -rf "$RUN_DIR"
        exit "$rc"
    }
    trap cleanup EXIT INT TERM

    log_phase "1/8 acquire image ($DISTRO)"
    BASE_IMAGE=$(acquire_image "$IMAGE_URL" "$IMAGE_SHA256" "$DISTRO") || exit 1

    log_phase "2/8 generate cloud-init seed"
    generate_ephemeral_ssh_key "$RUN_DIR/id_ed25519"
    PUBKEY=$(cat "$RUN_DIR/id_ed25519.pub")
    mkdir -p "$RUN_DIR/seed"
    render_user_data "$CLOUD_USER" "$PUBKEY" "$PACKAGE_INSTALL_CMD" "$PACKAGES" "$POST_BOOT_CMDS" \
        > "$RUN_DIR/seed/user-data"
    render_meta_data > "$RUN_DIR/seed/meta-data"
    make_seed_iso "$RUN_DIR/seed.iso" "$RUN_DIR/seed" || exit 1

    log_phase "3/8 boot QEMU (accel=$ACCEL, port=$SSH_PORT)"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$RUN_DIR/overlay.qcow2" >/dev/null
    local cpu_flag="host"
    [ "$ACCEL" = "tcg" ] && cpu_flag="max"
    # Note: per-distro kernel state (e.g. SELinux enforcing) is applied via
    # POST_BOOT_CMDS in cloud-init's runcmd, NOT via -append. QEMU's -append
    # is silently ignored when booting from a disk image (no -kernel passed),
    # which would mask the SELinux gate.
    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -machine q35,accel=$ACCEL \
        -cpu $cpu_flag \
        -smp 4 -m 4096 \
        -drive file="$RUN_DIR/overlay.qcow2",if=virtio \
        -drive file="$RUN_DIR/seed.iso",if=virtio,format=raw \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
        -device virtio-net-pci,netdev=n0 \
        -display none -daemonize \
        -pidfile "$RUN_DIR/vm.pid" \
        -serial file:"$RUN_DIR/serial.log"
    wait_for_ssh "$SSH_PORT" || exit 1

    log_phase "4/8 wait for cloud-init"
    if ! ssh_in "$SSH_PORT" 'sudo cloud-init status --wait'; then
        echo "cloud-init failed; fetching output log" >&2
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
            "$CLOUD_USER@127.0.0.1:/var/log/cloud-init-output.log" \
            "$RUN_DIR/cloud-init-output.log" 2>/dev/null || true
        exit 1
    fi

    log_phase "5/8 sync workspace"
    ssh_in "$SSH_PORT" 'sudo mkdir -p /workspace && sudo chown -R '"$CLOUD_USER:$CLOUD_USER"' /workspace'
    rsync -az --delete \
        --exclude '.git' \
        --exclude 'scripts/test/last-*.log' \
        --exclude 'scripts/test/serial-*.log' \
        --exclude 'scripts/test/cloud-init-output-*.log' \
        -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $RUN_DIR/id_ed25519 -p $SSH_PORT" \
        "$REPO_ROOT/" "$CLOUD_USER@127.0.0.1:/workspace/"

    log_phase "6/8 exec command"
    local in_vm_cmd="${CMD:-bash scripts/test/run-all.sh}"
    if [ "$SHELL_MODE" = "1" ]; then
        echo "Dropping to interactive shell. Exit when done." >&2
        ssh_in "$SSH_PORT"
        exit 0
    fi
    set +e
    ssh_in_tty "$SSH_PORT" "cd /workspace && $in_vm_cmd"
    local in_vm_rc=$?
    set -e

    log_phase "7/8 retrieve logs"
    # Trap also retrieves; explicit copy here makes the path well-known.
    for f in last-run.log last-summary.log; do
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
            "$CLOUD_USER@127.0.0.1:/workspace/scripts/test/$f" \
            "$REPO_ROOT/scripts/test/${f%.log}-$DISTRO.log" 2>/dev/null || true
    done

    log_phase "8/8 teardown"
    # cleanup trap handles VM kill + temp dir removal.
    exit $in_vm_rc
}
```

- [ ] **Step 10.3: Lint**

```bash
bash scripts/lint.sh
```

If shellcheck reports SC2086 or SC2046 in places they're intentional (the `$ACCEL`, `$SSH_PORT`, `$kernel_append` expansions in the qemu command), add targeted `# shellcheck disable=SC2086` comments. Re-run until clean.

- [ ] **Step 10.4: Run unit tests**

```bash
bash scripts/test/unit/test-runner.sh
```

Expected: 5 passed (no new unit test added in this task).

- [ ] **Step 10.5: Commit**

```bash
git add scripts/test/run-in-vm.sh
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "$(cat <<'EOF'
ci: wire launcher phases into main()

Eight-phase orchestration: image acquire, seed gen, boot, cloud-init
wait, workspace sync, exec, retrieve, teardown. Trap-based cleanup
copies last-run/last-summary back to host and serial.log/cloud-init-
output.log on failure.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 11.1: Write the workflow**

```bash
mkdir -p .github/workflows
```

Create `.github/workflows/ci.yml`:

```yaml
name: ci

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Run lint
        run: bash scripts/lint.sh

  vm-matrix:
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    strategy:
      fail-fast: false
      matrix:
        distro: [fedora, debian, ubuntu]
    steps:
      - uses: actions/checkout@v4

      - name: Install QEMU + tools
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            qemu-system-x86 qemu-utils cloud-image-utils \
            openssh-client rsync

      - name: Verify KVM
        run: |
          if [ -w /dev/kvm ]; then
            echo "KVM available: $(ls -l /dev/kvm)"
          else
            echo "KVM NOT writable; falling back to TCG (slow)."
            ls -l /dev/kvm || true
          fi

      - name: Restore image cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/devcontainer-ci/images/${{ matrix.distro }}
          key: vm-image-${{ matrix.distro }}-${{ hashFiles(format('scripts/test/vms/{0}.conf', matrix.distro)) }}

      - name: Run suite in ${{ matrix.distro }} VM
        run: bash scripts/test/run-in-vm.sh ${{ matrix.distro }}

      - name: Upload run logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: logs-${{ matrix.distro }}
          path: |
            scripts/test/last-run-${{ matrix.distro }}.log
            scripts/test/last-summary-${{ matrix.distro }}.log
            scripts/test/serial-${{ matrix.distro }}.log
            scripts/test/cloud-init-output-${{ matrix.distro }}.log
          if-no-files-found: ignore
```

- [ ] **Step 11.2: Lint the workflow**

```bash
bash scripts/lint.sh
```

Expected: actionlint reports nothing on the new workflow. If it does, fix and re-run.

- [ ] **Step 11.3: Commit**

```bash
git add .github/workflows/ci.yml
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "$(cat <<'EOF'
ci: GitHub Actions workflow (lint + QEMU matrix)

Two jobs on ubuntu-24.04: lint runs scripts/lint.sh in parallel with
the vm-matrix job, which boots Fedora/Debian/Ubuntu in QEMU via
scripts/test/run-in-vm.sh. fail-fast off so a single-distro failure
doesn't cancel the others.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: .gitignore for CI artifacts

**Files:**
- Modify: `.gitignore`

The launcher writes log files into `scripts/test/last-run-*.log`, `last-summary-*.log`, `serial-*.log`, `cloud-init-output-*.log`. These must not get committed.

- [ ] **Step 12.1: Inspect current .gitignore**

```bash
cat .gitignore
```

- [ ] **Step 12.2: Append CI artifact patterns**

Use `Edit` to append (preserving existing content):

Patterns to add at the end of `.gitignore`:

```
# CI artifacts (written by scripts/test/run-in-vm.sh)
scripts/test/last-run-*.log
scripts/test/last-summary-*.log
scripts/test/serial-*.log
scripts/test/cloud-init-output-*.log
```

- [ ] **Step 12.3: Commit**

```bash
git add .gitignore
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "ci: ignore per-distro test logs

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Docs

**Files:**
- Create: `docs/ci-testing.md`

- [ ] **Step 13.1: Write the doc**

Create `docs/ci-testing.md`:

```markdown
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

## Running a CI cell locally

```
bash scripts/test/run-in-vm.sh fedora       # full suite in Fedora 41
bash scripts/test/run-in-vm.sh debian       # Debian 13
bash scripts/test/run-in-vm.sh ubuntu       # Ubuntu 24.04
```

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
```

- [ ] **Step 13.2: Commit**

```bash
git add docs/ci-testing.md
git -c user.name="Jakob Langdal" -c user.email="jakob.langdal@alexandra.dk" commit -m "docs: local CI reproduction guide

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Host-side end-to-end smoke test

**Files:** none (verification only)

**Important:** This task CANNOT run inside the devcontainer — it needs `/dev/kvm` and QEMU. **Run these commands on the developer's host** (Linux laptop or workstation), not inside `./dev`.

- [ ] **Step 14.1: Install host prerequisites (Linux)**

```bash
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils cloud-image-utils \
    openssh-client rsync shellcheck
```

Verify KVM is usable:

```bash
ls -l /dev/kvm
# expect: crw-rw---- 1 root kvm ... — your user must be in the 'kvm' group
groups | grep -q kvm || sudo usermod -aG kvm "$USER"  # then re-login
```

- [ ] **Step 14.2: Run lint on the host**

```bash
cd /path/to/repo
bash scripts/lint.sh
```

Expected: clean exit (0).

- [ ] **Step 14.3: Run the Ubuntu cell end-to-end**

Ubuntu first because it's the most likely happy path. Expect 15–25 minutes wall-clock on KVM.

```bash
bash scripts/test/run-in-vm.sh ubuntu
```

Expected:
- Phase markers print in order: `1/8 acquire image` … `8/8 teardown`.
- Final exit code 0.
- `scripts/test/last-summary-ubuntu.log` contains a PASS/FAIL table from `run-all.sh`.
- All scenarios PASS or SKIP. No FAIL.

If a scenario fails: investigate `scripts/test/last-run-ubuntu.log` for the scenario output; if it's a real bug in the existing suite or the `dev` script, file it but do NOT block CI bringup — the same failure would happen on a developer's VM. The point of CI is to surface real failures.

- [ ] **Step 14.4: Run the Fedora cell — the new coverage**

```bash
bash scripts/test/run-in-vm.sh fedora
```

Expected:
- Scenario `14-selinux-enforcing.sh` runs (not SKIP) and PASSes.
- All other scenarios PASS or SKIP as appropriate.

This is the primary new value of the entire CI work. If 14 SKIPs on Fedora, something is wrong with `POST_BOOT_CMDS` not running or SELinux not flipping to enforcing — check `getenforce` over `--shell`, and inspect `cloud-init-output-fedora.log`.

- [ ] **Step 14.5: Run the Debian cell**

```bash
bash scripts/test/run-in-vm.sh debian
```

Expected:
- AppArmor scenarios SKIP gracefully (Debian has no AppArmor by default).
- All non-AppArmor scenarios PASS or SKIP.

- [ ] **Step 14.6: Test `--shell` mode briefly**

```bash
bash scripts/test/run-in-vm.sh ubuntu --shell
# In the VM SSH shell:
docker version
exit
```

Expected: Docker version prints, shell exits, launcher tears down cleanly with exit 0.

- [ ] **Step 14.7: Document any deviations**

If any cell fails or behaves unexpectedly, capture the symptom and the relevant log excerpt and bring it back to the Plan-execution session for triage.

---

## Task 15: Open PR

**Files:** none

- [ ] **Step 15.1: Push the branch**

```bash
git push -u origin feature/ci-pipeline
```

- [ ] **Step 15.2: Open the PR**

```bash
gh pr create --title "ci: portable QEMU-based test pipeline (Fedora/Debian/Ubuntu matrix)" --body "$(cat <<'EOF'
## Summary
- Adds `scripts/test/run-in-vm.sh`: portable launcher that boots a fresh Fedora 41 / Debian 13 / Ubuntu 24.04 VM in QEMU and runs `scripts/test/run-all.sh` inside.
- Adds `scripts/lint.sh`: single entry point for shellcheck + hadolint + actionlint, with sha256-pinned tool releases.
- Adds `.github/workflows/ci.yml`: lint job + parallel 3-distro QEMU matrix.
- Adds `docs/ci-testing.md`: local repro guide.
- First time `scenarios/14-selinux-enforcing.sh` is actually exercised in CI (Fedora cell with `enforcing=1`).

## Test plan
- [ ] CI's `lint` job passes.
- [ ] CI's `vm-matrix` job passes on all three distros.
- [ ] Manual local repro: `bash scripts/test/run-in-vm.sh ubuntu` exits 0 on a developer host with KVM.
- [ ] `scenarios/14-selinux-enforcing.sh` reports PASS (not SKIP) in the Fedora cell.

Spec: `docs/superpowers/specs/2026-05-14-ci-pipeline-design.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 15.3: Watch the first CI run**

```bash
gh pr checks --watch
```

Expected: `lint` finishes in ~1 min, green. `vm-matrix (fedora|debian|ubuntu)` runs ~20–30 min each in parallel, all green.

If a cell fails, download artifacts:

```bash
gh run download <run-id> --name logs-<distro>
```

Inspect `last-run-<distro>.log` for the first FAIL line.

---

## Spec coverage check

| Spec section | Tasks |
|---|---|
| Goal: verify container-creation end-to-end | 10–15 |
| Launcher contract (inputs, exit code, side effects) | 2, 10 |
| Required host tools | 10 (require_host_tools) |
| Acceleration policy (kvm/hvf/tcg) | 10 (detect_accel) |
| Distro config format | 3, 4 |
| 8-phase lifecycle with timeouts | 10 |
| Checksum-pinned images | 6 |
| Read-only base + COW overlay | 10 (qemu-img create -b) |
| Ephemeral SSH key per run | 7, 10 |
| User-mode networking, single forwarded port | 5, 10 |
| Headless, daemonized, PID-tracked | 10 |
| Workspace transfer with .git exclude | 10 |
| Lint job (shellcheck/hadolint/actionlint) | 1, 11 |
| VM matrix job, fail-fast off, log artifacts | 11 |
| Portability surface | 13 (docs) |
| Local repro: same script | 13 (docs) |
| Existing suite untouched | (verified by absence of edits) |
