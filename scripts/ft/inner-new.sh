#!/usr/bin/env bash
# scripts/ft/inner-new.sh — container side of `dev ft new`. Piped (after
# prelude.sh) over `exec bash -s`; runs as vscode. Creates or REUSES the
# feature's branch + worktree + workspace, finishes the build, opens a
# dedicated agent tab, then starts the agent — sequenced because herdr's
# plugin hooks are async and cannot hold the agent back until setup is done.
# Agent problems never cost you the worktree: a missing binary or a failed
# start is reported and the prepared workspace is left ready (exit 0).
set -euo pipefail

name=$1; shift
kind=${FT_AGENT:-claude}
if [ "${1:-}" = "--agent" ]; then
  kind=${2:?ft: --agent needs a KIND}
  shift 2
fi
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

# Idempotent: an existing worktree is reopened, not an error — re-running ft
# on a live feature is how you get back to it (or add the agent it lacked).
if [ -d "$wt" ]; then
  echo "ft: $branch already exists at $wt — reusing it." >&2
  out=$(herdr worktree open --cwd /workspace --path "$wt" --no-focus)
else
  case $base in origin/*) git fetch --quiet origin "${base#origin/}" ;; esac
  out=$(herdr worktree create --cwd /workspace --branch "$branch" --base "$base" \
        --path "$wt" --label "$name" --no-focus)
fi
# herdr's JSON shape varies across versions; try the known spellings.
ws=$(jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' <<<"$out")
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

# A dedicated tab for the agent inside the feature's workspace, so the root
# pane stays a free shell — one tab per agent, like the classic ft layout.
if [ -n "$ws" ]; then
  tpane=""
  if tout=$(herdr tab create --workspace "$ws" --label "agent" --cwd "$wt" --no-focus 2>/dev/null); then
    tpane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$tout")
  fi
  [ -n "$tpane" ] && pane=$tpane
fi

if ! command -v "$kind" >/dev/null 2>&1; then
  echo "ft: no '$kind' executable in the container — the worktree and tab are ready, without an agent." >&2
  echo "ft: install it (credentials via 'dev agent add $kind' where supported), then:" >&2
  echo "ft:   herdr agent start <name> --kind $kind --pane ${pane:-<pane>}" >&2
  exit 0
fi

if [ -z "$pane" ]; then
  echo "ft: the worktree is ready, but herdr's reply had no pane id this script knows;" >&2
  echo "ft: start the agent by hand in its tab. The reply was:" >&2
  printf '%s\n' "$out" >&2
  exit 0
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

if ! aout=$(herdr agent start "$agent" --kind "$kind" --pane "$pane" -- "$@" 2>&1); then
  echo "ft: the worktree and tab are ready, but the agent did not start:" >&2
  printf '%s\n' "$aout" >&2
  echo "ft: if an agent already runs in that pane this is expected; otherwise attach" >&2
  echo "ft: ('dev shell', then 'herdr') and look at the tab, or retry with:" >&2
  echo "ft:   herdr agent start $agent --kind $kind --pane $pane" >&2
  exit 0
fi
echo "ft: $branch ready — worktree $wt, agent $agent ($kind)"
