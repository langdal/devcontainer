#!/usr/bin/env bash
# scripts/lint.sh — single entry point for repo linting.
# Runs: shellcheck on *.sh, hadolint on Dockerfile, actionlint on
# .github/workflows/*.yml. Pins hadolint and actionlint versions and
# fetches them on first run; shellcheck comes from the system.
set -euo pipefail

HADOLINT_VERSION="2.14.0"
ACTIONLINT_VERSION="1.7.12"

# Every platform is pinned, not just the one the CI box happens to be.
# Verification used to run on linux/amd64 only, on the stated grounds that
# "macOS lacks sha256sum" -- macOS has shasum -a 256, so the effect was that
# the one platform a developer is most likely to run this on installed an
# executable into ~/.cache on TLS alone. Values come from upstream's own
# .sha256 sidecars and checksums.txt, fetched 2026-08-16; the two that already
# existed were re-checked against upstream and matched.
#
# Case, not an associative array: macOS runs bash 3.2. Returning empty for an
# unknown platform is what makes the callers fail closed.
_hadolint_sha256() {
    case "$1" in
        linux-x86_64) echo 6bf226944684f56c84dd014e8b979d27425c0148f61b3bd99bcc6f39e9dc5a47 ;;
        linux-arm64)  echo 331f1d3511b84a4f1e3d18d52fec284723e4019552f4f47b19322a53ce9a40ed ;;
        macos-x86_64) echo 2b69a853433f1eca522ffb921cd490bd1321424d03331fd8390f93b7fb4a02e9 ;;
        macos-arm64)  echo 3625e2e9f43dcfe7bd38738a5f5520ed50ce39ed28485266e6803dd7bc197b10 ;;
        *)            echo "" ;;
    esac
}
_actionlint_sha256() {
    case "$1" in
        linux_amd64)  echo 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
        linux_arm64)  echo 325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
        darwin_amd64) echo 5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
        darwin_arm64) echo aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
        *)            echo "" ;;
    esac
}

# sha256sum on Linux, shasum -a 256 on macOS. Returns non-zero when neither
# exists so the caller refuses rather than silently skipping the check.
_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

# Verify $1 (a file) against $2 (the expected digest). Any doubt -- unknown
# platform, no digest tool, mismatch -- deletes the download and fails.
_verify_or_die() {
    local file="$1" want="$2" what="$3" actual
    if [ -z "$want" ]; then
        echo "$what: no pinned checksum for this platform; refusing to install an unverified binary." >&2
        rm -f "$file"; return 1
    fi
    if ! actual=$(_sha256_file "$file"); then
        echo "$what: neither sha256sum nor shasum found; refusing to install an unverified binary." >&2
        rm -f "$file"; return 1
    fi
    if [ "$actual" != "$want" ]; then
        echo "$what checksum mismatch: expected=$want actual=$actual" >&2
        rm -f "$file"; return 1
    fi
}

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
    # hadolint 2.14.0 publishes lowercase asset names and spells macOS "macos",
    # not "Darwin" -- verified against the release manifest. The previous
    # ${uname_s^} produced "Darwin"/"Linux" and would have 404'd on BOTH
    # platforms; it went unnoticed because this repo's mise.toml installs
    # hadolint, so the command -v short-circuit above means the download path
    # never runs on a set-up host. It runs on a fresh one.
    local os_tag="$uname_s"
    [ "$os_tag" = "darwin" ] && os_tag="macos"
    local url="https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-${os_tag}-${arch_tag}"
    echo "Fetching hadolint ${HADOLINT_VERSION}..." >&2
    curl --fail --retry 3 --retry-connrefused -L -o "$BIN_DIR/hadolint" "$url"
    _verify_or_die "$BIN_DIR/hadolint" "$(_hadolint_sha256 "${os_tag}-${arch_tag}")" hadolint || return 1
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
    if ! _verify_or_die "$tmp/$tarball" "$(_actionlint_sha256 "${uname_s}_${arch_tag}")" actionlint; then
        rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tmp/$tarball" -C "$tmp"
    mv "$tmp/actionlint" "$BIN_DIR/actionlint"
    chmod +x "$BIN_DIR/actionlint"
    rm -rf "$tmp"
}

if [ -z "$(_hadolint_sha256 linux-x86_64)" ] || [ -z "$(_actionlint_sha256 linux_amd64)" ]; then
    echo "lint.sh: SHA256 pins are empty — refusing to fetch unverified binaries." >&2
    exit 2
fi

fail=0

echo "=== shellcheck ==="
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck is required. Install via 'apt install shellcheck' or 'brew install shellcheck'." >&2
    exit 2
fi
# Not mapfile: this script is itself host-side and must run under macOS's
# bash 3.2, which has no mapfile/readarray. See the bash 3.2 section below.
shell_files=()
while IFS= read -r -d '' f; do shell_files+=("$f"); done \
    < <(git ls-files -z '*.sh' 'dev' 'entrypoint.sh' 'firewall-init.sh' 'dind-init.sh' 2>/dev/null)
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

echo
echo "=== line budgets ==="
over=0
[ "$(wc -l < dev)" -le 190 ] || { echo "dev exceeds 190 lines"; over=1; }
for f in lib/dev/*.sh; do
    case "$f" in
        # agent.sh sanctioned over 300: further split breaks scenario 48's
        # direct sourcing of this module. Give it its own, higher budget.
        lib/dev/agent.sh) budget=550 ;;
        *) budget=300 ;;
    esac
    [ "$(wc -l < "$f")" -le "$budget" ] || { echo "$f exceeds $budget lines"; over=1; }
done
[ "$over" -eq 0 ] || fail=1

echo
echo "=== bash 3.2 portability (host-side files) ==="
# macOS still ships bash 3.2 as /bin/bash, and `dev` plus the test harness run
# there directly. Constructs added in bash 4+ do not fail loudly: `declare -A`
# errors once and then every subscripted write is silently reinterpreted as
# arithmetic, so a snapshot/restore helper quietly restores nothing. That is
# exactly how it reached a Mac unnoticed on 2026-08-16.
#
# Scope is host-side only. entrypoint.sh, firewall-init.sh, dind-init.sh and
# scripts/verify-*.sh run inside the container against bash 5, so bash 4+
# constructs are legitimate there.
#
# THIS FILE IS IN SCOPE. An earlier revision left it out on the theory that a
# linter holding these patterns as literals would flag itself -- and a real
# `${uname_s^}` in ensure_hadolint promptly survived the rule and broke
# hadolint on the first Mac to run it. The literals are marked with
# lint-b32-allow instead, so the file polices itself.
b32_files=()
for f in dev lib/dev/*.sh scripts/lint.sh scripts/test/lib/*.sh \
         scripts/test/unit/*.sh scripts/test/scenarios/*.sh scripts/test/*.sh; do
    case "$f" in
        # Linux-only by construction: drives QEMU distro VMs through apt/dnf
        # and GNU `find -printf`, none of which exist on macOS. It cannot run
        # there at all, so bash 4+ constructs are legitimate.
        scripts/test/run-e2e.sh) continue ;;
    esac
    [ -f "$f" ] && b32_files+=("$f")
done
# shellcheck disable=SC2016  # single quotes intended: these are regexes, not expansions
b32_re='declare -A|typeset -A|local -A|declare -n|local -n|readarray|mapfile|;;&|&>>|\[\[ -v |\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,\}|\^\})'  # lint-b32-allow
if [ ${#b32_files[@]} -gt 0 ] \
   && grep -nE "$b32_re" "${b32_files[@]}" 2>/dev/null \
      | grep -v 'lint-b32-allow' | grep -v '^[^:]*:[0-9]*: *#'; then
    echo "^^ bash 4+ construct in a host-side file — macOS runs bash 3.2" >&2
    fail=1
else
    echo "ok (${#b32_files[@]} host-side files)"
fi

exit "$fail"
