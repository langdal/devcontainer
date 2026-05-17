#!/usr/bin/env bash
# scripts/lint.sh — single entry point for repo linting.
# Runs: shellcheck on *.sh, hadolint on Dockerfile, actionlint on
# .github/workflows/*.yml. Pins hadolint and actionlint versions and
# fetches them on first run; shellcheck comes from the system.
set -euo pipefail

HADOLINT_VERSION="2.14.0"
HADOLINT_SHA256_LINUX_X64="6bf226944684f56c84dd014e8b979d27425c0148f61b3bd99bcc6f39e9dc5a47"
ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256_LINUX_X64="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"

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
    case "$uname_m" in
        aarch64|arm64) arch_tag="arm64" ;;
    esac
    local url="https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-${uname_s^}-${arch_tag}"
    echo "Fetching hadolint ${HADOLINT_VERSION}..." >&2
    curl --fail --retry 3 --retry-connrefused -L -o "$BIN_DIR/hadolint" "$url"
    # Verification only on linux/amd64; macOS lacks sha256sum (uses shasum -a 256). Other targets trust TLS + signed releases.
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
    case "$uname_m" in
        aarch64|arm64) arch_tag="arm64" ;;
    esac
    local tarball="actionlint_${ACTIONLINT_VERSION}_${uname_s}_${arch_tag}.tar.gz"
    local url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${tarball}"
    echo "Fetching actionlint ${ACTIONLINT_VERSION}..." >&2
    local tmp; tmp=$(mktemp -d)
    curl --fail --retry 3 --retry-connrefused -L -o "$tmp/$tarball" "$url"
    # Verification only on linux/amd64; macOS lacks sha256sum (uses shasum -a 256). Other targets trust TLS + signed releases.
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
