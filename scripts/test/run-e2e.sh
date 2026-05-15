#!/usr/bin/env bash
# scripts/test/run-e2e.sh — single-command e2e runner.
#
# Designed to be the easy entry point from inside a dev container started
# with `./dev --maintenance` (or any host with passwordless sudo). Installs
# QEMU + cloud-image-utils on first run, then walks the distro matrix
# calling scripts/test/run-in-vm.sh per cell.
#
# Usage:
#   bash scripts/test/run-e2e.sh                 # all distros sequentially
#   bash scripts/test/run-e2e.sh fedora          # one distro
#   bash scripts/test/run-e2e.sh ubuntu fedora   # subset
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Default: every .conf under scripts/test/vms/. Order is alphabetical so
# the cell most likely to fail (Fedora, with SELinux enforcing) doesn't
# block earlier cells.
if [ $# -gt 0 ]; then
    DISTROS=("$@")
else
    mapfile -t DISTROS < <(find scripts/test/vms -maxdepth 1 -name '*.conf' -printf '%f\n' \
                           | sed 's/\.conf$//' | sort)
fi

ensure_prereqs() {
    local missing=()
    for t in qemu-system-x86_64 qemu-img cloud-localds; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ ${#missing[@]} -eq 0 ]; then return 0; fi
    echo "=== installing missing host tools: ${missing[*]} ==="
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Need sudo to apt install ${missing[*]} but sudo not available." >&2
        echo "Either start the dev container with --maintenance or install manually." >&2
        return 1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y --no-install-recommends \
            qemu-system-x86 qemu-utils cloud-image-utils openssh-client rsync
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y qemu-kvm qemu-img genisoimage openssh-clients rsync
    else
        echo "Unsupported package manager — install qemu + cloud-image-utils manually." >&2
        return 1
    fi
}

ensure_kvm() {
    if [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then
        echo "=== /dev/kvm not writable; attempting chmod ==="
        sudo chmod 666 /dev/kvm 2>/dev/null \
            || echo "(could not chmod; launcher will fall back to TCG)" >&2
    fi
}

ensure_prereqs || exit 1
ensure_kvm

FAILED=()
for distro in "${DISTROS[@]}"; do
    echo
    echo "############################################################"
    echo "# e2e: $distro"
    echo "############################################################"
    if ! bash scripts/test/run-in-vm.sh "$distro"; then
        FAILED+=("$distro")
    fi
done

echo
echo "############################################################"
echo "# e2e summary"
echo "############################################################"
for distro in "${DISTROS[@]}"; do
    summary="scripts/test/last-summary-$distro.log"
    if [ -f "$summary" ]; then
        pass=$(grep -c '^\[PASS\]' "$summary" 2>/dev/null || echo 0)
        fail=$(grep -c '^\[FAIL\]' "$summary" 2>/dev/null || echo 0)
        skip=$(grep -c '^\[SKIP\]' "$summary" 2>/dev/null || echo 0)
        printf "  %-8s  PASS=%-3s FAIL=%-3s SKIP=%-3s\n" "$distro" "$pass" "$fail" "$skip"
    else
        printf "  %-8s  (no summary log — launcher failed before suite ran)\n" "$distro"
    fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
    echo
    echo "Cells with non-zero launcher exit: ${FAILED[*]}"
    exit 1
fi
