#!/usr/bin/env bash
# scripts/ft/inner-sync.sh — container side of `dev ft sync`. Installs the
# host client's exact herdr version via mise's ubi backend (GitHub releases;
# allowlisted in closed mode) and symlinks the real binary into ~/.local/bin
# so non-interactive SSH — which `herdr machine add` rides — finds it without
# mise's shims on PATH. Cached machine-wide in the shared mise volume.
set -euo pipefail

v=$1
repo=${2:-herdrdev/herdr}

command -v mise >/dev/null 2>&1 || {
  echo "ft sync: mise is missing in the container — rebuild the image." >&2; exit 1; }

mise use -g "ubi:${repo}@${v}"
mkdir -p "$HOME/.local/bin"
ln -sf "$(mise which herdr)" "$HOME/.local/bin/herdr"
echo "ft sync: herdr ${v} installed ($("$HOME/.local/bin/herdr" --version 2>/dev/null || echo 'version check failed'))"
