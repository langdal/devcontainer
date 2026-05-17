#!/usr/bin/env bash
# install.sh — bootstrap the generic-devcontainer toolchain on a fresh host.
#
# Intended to be run as a one-liner:
#
#     curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash
#
# Pin to a specific release by setting REF:
#
#     REF=v1.0.0 curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash
#
# Environment variables (all optional):
#   INSTALL_DIR  Where to clone. Default: $XDG_DATA_HOME/devcontainer
#                or ~/.local/share/devcontainer.
#   REF          Git ref to check out. Default: the latest tag advertised
#                by origin (falls back to 'main' when no tags exist).
#   REPO_URL     HTTPS URL to clone from. Override only for forks.
#
# The script clones the full repo because `dev` requires its sibling files
# (Dockerfile, entrypoint.sh, firewall-init.sh, etc.) at its SCRIPT_DIR.
# Re-running upgrades the existing checkout in place.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/langdal/devcontainer.git}"
DEFAULT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/devcontainer"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"
REF="${REF:-}"

err() { echo "Error: $*" >&2; exit 1; }
log() { echo ">> $*"; }

command -v git >/dev/null 2>&1 || err "git is required."

if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    echo "Warning: neither 'docker' nor 'podman' was found on PATH."
    echo "         You will need one of them before 'dev' can build or"
    echo "         run a container. See README.md > Host requirements."
fi

# Resolve REF (default = latest stable semver tag advertised by origin).
# We use git ls-remote to avoid jq/curl-on-GitHub-API dependencies and
# the unauthenticated rate limit. `--sort=version:refname` orders
# semver-ish refs naturally, but without a versionsort.suffix hint it
# ranks `v1.0.0-rc.1` after `v1.0.0` (longer string wins on tie). Filter
# to strict `vMAJOR.MINOR.PATCH` tags so prereleases (-rc, -beta, ...)
# never become the default install target.
if [ -z "$REF" ]; then
    REF=$(git ls-remote --tags --refs --sort='version:refname' "$REPO_URL" 2>/dev/null \
          | awk -F/ '{print $NF}' \
          | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
          | tail -1)
    if [ -z "$REF" ]; then
        REF="main"
        log "no tags found at origin; falling back to ${REF}"
    else
        log "using latest tag: ${REF}"
    fi
else
    log "using REF=${REF}"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"

if [ -d "$INSTALL_DIR/.git" ]; then
    log "updating existing checkout in ${INSTALL_DIR}"
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
    git -C "$INSTALL_DIR" fetch --tags --prune origin
    # Reset any local edits so the upgrade is unambiguous. People who want
    # a customised local copy should clone manually, not via this script.
    git -C "$INSTALL_DIR" checkout --quiet --force "$REF"
else
    if [ -e "$INSTALL_DIR" ]; then
        err "${INSTALL_DIR} exists but is not a git checkout — refusing to overwrite. Move it aside or set INSTALL_DIR."
    fi
    log "cloning ${REPO_URL} into ${INSTALL_DIR}"
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
    git -C "$INSTALL_DIR" checkout --quiet "$REF"
fi

log "checked out $(git -C "$INSTALL_DIR" describe --tags --always)"

# Hand off to `dev install`, which is the canonical PATH-symlink step.
# `bash -i` is intentionally avoided — the dev install path is non-
# interactive when stdin isn't a tty (which is the case under curl|bash),
# and quietly prints a follow-up tip to add the compdef line manually.
"$INSTALL_DIR/dev" install

echo
echo "Installed. Run 'dev --help' to get started."
echo "Source tree: ${INSTALL_DIR}"
echo "Upgrade later by re-running this one-liner (or:  git -C ${INSTALL_DIR} pull && dev --build)."
