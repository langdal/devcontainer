#!/usr/bin/env bash
# scripts/ft/inner-new.sh — container side of `dev ft new`. Piped over
# `exec bash -s` by lib/dev/ft.sh; runs as vscode inside the container.
# Creates branch + worktree + herdr tab, finishes the build, then starts the
# agent — the ordering is the point: herdr's own plugin hooks are async and
# cannot hold the agent back until setup completes.
set -euo pipefail

name=$1; shift
base=${FT_BASE:-origin/main}
branch="feat/$name"
wt="/workspace/.worktrees/$name"

ft_ensure_server
command -v jq >/dev/null 2>&1 || {
  echo "ft: jq is missing from the image — rebuild with 'dev up --build'." >&2; exit 1; }
command -v mise >/dev/null 2>&1 || {
  echo "ft: mise is missing — this image predates the mise bake; rebuild." >&2; exit 1; }

cd /workspace
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "ft: /workspace is not a git repository." >&2; exit 1; }

# Keep worktrees invisible to `git status` even on branches whose .gitignore
# predates them: clone-wide exclude, never committed.
ex=.git/info/exclude
grep -qx '.worktrees/' "$ex" 2>/dev/null || echo '.worktrees/' >> "$ex"

case $base in origin/*) git fetch --quiet origin "${base#origin/}" ;; esac

out=$(herdr worktree create --cwd /workspace --branch "$branch" --base "$base" \
      --path "$wt" --label "$name" --no-focus)
# herdr's JSON shape varies across versions; try the known spellings.
pane=$(jq -r '.result.root_pane.pane_id
              // .result.workspace.root_pane.pane_id
              // .result.pane_id // empty' <<<"$out")

cd "$wt"
mise trust >/dev/null 2>&1 || mise trust
mise install
if mise tasks ls 2>/dev/null | awk '{print $1}' | grep -qx setup; then
  mise run setup
else
  echo "ft: no 'setup' task in mise.toml — skipping the build step." >&2
fi
mise daemons register >/dev/null 2>&1 \
  || echo "ft: 'mise daemons register' skipped (no daemons configured, or experimental off)." >&2

if [ -z "$pane" ]; then
  echo "ft: worktree is ready but herdr's reply had no pane id this script knows;" >&2
  echo "ft: start the agent by hand in the new tab. The reply was:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# Agent names: documented as [a-z][a-z0-9_-]{0,31} — lowercase, 32 chars max,
# unique among live agents. "feat_" guarantees the leading [a-z].
slug=$(printf '%s' "feat_$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
agent=$(printf '%s' "$slug" | cut -c1-32)
n=2
while herdr agent list 2>/dev/null \
      | jq -e --arg a "$agent" '.result.agents[]? | select(.name == $a)' >/dev/null; do
  agent="$(printf '%s' "$slug" | cut -c1-$((32 - ${#n} - 1)))-$n"
  n=$((n + 1))
done
herdr agent start "$agent" --kind claude --pane "$pane" -- "$@"
echo "ft: $branch ready — worktree $wt, agent $agent"
