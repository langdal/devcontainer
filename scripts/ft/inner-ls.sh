#!/usr/bin/env bash
# scripts/ft/inner-ls.sh — container side of `dev ft ls`.
set -euo pipefail
ft_ensure_server
exec herdr worktree list
