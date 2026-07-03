#!/usr/bin/env bash
# Unit: per-workspace home volume name in the dry-run docker command.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "no container runtime on PATH"; exit 1; }
WORK=$(mktemp -d); mkdir -p "$WORK/myproj"; trap 'rm -rf "$WORK"' EXIT
dev() { (cd "$WORK/myproj" && env -u DEV_SHARED_HOME "$@" "$ROOT/dev" --dry-run -- echo hi </dev/null 2>&1); }

# 1. Default: per-workspace home volume named after the dir basename.
# (DEV_SHARED_HOME is explicitly unset above so an inherited ambient
# value can't flip this assertion.)
out=$(dev)
echo "$out" | grep -q -- '-v devcontainer-home-myproj:/home/vscode' \
    || { echo "default home volume not per-workspace: $out"; exit 1; }
# mise + (no dind here) stay shared/unchanged.
echo "$out" | grep -q -- '-v devcontainer-mise:/mise' \
    || { echo "mise volume changed unexpectedly: $out"; exit 1; }

# 2. DEV_SHARED_HOME=1 selects the legacy shared name.
out=$(dev DEV_SHARED_HOME=1)
echo "$out" | grep -q -- '-v devcontainer-home:/home/vscode' \
    || { echo "DEV_SHARED_HOME did not select legacy name: $out"; exit 1; }
echo "$out" | grep -q -- '-v devcontainer-home-myproj:/home/vscode' \
    && { echo "DEV_SHARED_HOME still used per-workspace name: $out"; exit 1; }

# 3. Host git identity is forwarded as DEV_GIT_NAME/DEV_GIT_EMAIL env when set.
# Use a throwaway $HOME with a known gitconfig so the assertion is
# deterministic and independent of the sandbox's real git identity.
# GIT_CONFIG_GLOBAL/XDG_CONFIG_HOME are unset so an inherited ambient value
# can't point git at a config file outside the throwaway $HOME.
# Single quotes below are intentional: $ROOT is deliberately broken out and
# expanded on the host side, while $HOME must expand later, inside the
# inner bash -c, against the env it was just given.
# shellcheck disable=SC2016
out=$( cd "$WORK/myproj" && env -u GIT_CONFIG_GLOBAL -u XDG_CONFIG_HOME HOME="$WORK/fakehome" bash -c '
    mkdir -p "$HOME"
    git config --global user.name "Test User"
    git config --global user.email "t@example.com"
    "'"$ROOT"'/dev" --dry-run -- echo hi </dev/null 2>&1' )
echo "$out" | grep -q -- '-e DEV_GIT_NAME' \
    || { echo "git name not forwarded: $out"; exit 1; }
echo "$out" | grep -q -- '-e DEV_GIT_EMAIL' \
    || { echo "git email not forwarded: $out"; exit 1; }

echo ok
