#!/usr/bin/env bash
# scripts/ft/inner-rm.sh — container side of `dev ft rm`. Stops the feature's
# in-container daemons, removes the herdr worktree (tab included), and deletes
# the branch only when it is merged into the base. -f discards everything.
set -euo pipefail

force=0
[ "${1:-}" = -f ] && { force=1; shift; }
name=$1
base=${FT_BASE:-origin/main}
branch="feat/$name"
wt="/workspace/.worktrees/$name"

cd /workspace
if [ -d "$wt" ]; then
  (cd "$wt" && mise daemons stop >/dev/null 2>&1) || true
fi

ws=""
if command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  ft_ensure_server || exit 1
  ws=$(herdr worktree list 2>/dev/null \
       | jq -r --arg b "$branch" '.result.worktrees[]?
           | select(.branch == $b)
           | (.workspace_id // .workspace.workspace_id // empty)' | head -n1)
fi

if [ -n "$ws" ]; then
  if [ "$force" = 1 ]; then
    herdr worktree remove --workspace "$ws" --force
  else
    herdr worktree remove --workspace "$ws"
  fi
elif [ -d "$wt" ]; then
  echo "ft: herdr does not list $branch; removing the git worktree directly." >&2
  if [ "$force" = 1 ]; then
    git worktree remove --force "$wt"
  else
    git worktree remove "$wt"
  fi
else
  git worktree prune
fi

if git show-ref --verify --quiet "refs/heads/$branch"; then
  if [ "$force" = 1 ] || git merge-base --is-ancestor "$branch" "$base"; then
    git branch -D "$branch"
  else
    echo "ft: branch $branch kept (not merged into $base) — 'dev ft rm -f $name' discards it." >&2
  fi
fi
