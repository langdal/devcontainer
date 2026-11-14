# shellcheck shell=bash
# lib/dev/ft.sh — `dev ft` / `dev fta`: feature worktrees with host-herdr tabs.
# The herdr you use is the HOST one: `dev ft NAME` creates (or reuses) the
# feature branch + worktree under <repo>/.worktrees/ and opens a herdr tab
# whose shell sits in it; `dev fta NAME` additionally auto-starts this
# workspace's container headless and runs, inside that tab, an interactive
# exec into the container at the worktree — launching an agent found there
# (claude/opencode/pi), or a plain shell when none is installed. Nothing
# herdr-related runs inside the container. Sourced by dev; not executed
# directly. Host deps: git >= 2.48 (worktree.useRelativePaths) and jq.

cmd_ft() {
  case "${1:-}" in
    -l)  _ft_list ;;
    -r)  shift; _ft_remove 0 "${1:-}" ;;
    -rf) shift; _ft_remove 1 "${1:-}" ;;
    ''|-h|--help|help) _ft_usage ;;
    -*)
      echo "Error: dev ft: unknown flag '${1}' (-l, -r NAME, -rf NAME, or NAME)" >&2
      exit 1
      ;;
    *)   _ft_open "$@" ;;
  esac
  exit 0
}

cmd_fta() {
  ft_kind=""
  case "${1:-}" in
    -cl) ft_kind=claude;   shift ;;
    -op) ft_kind=opencode; shift ;;
    -pi) ft_kind=pi;       shift ;;
    ''|-h|--help|help) _ft_usage; exit 0 ;;
  esac
  _ft_open_attach "$ft_kind" "${1:-}"
  exit 0
}

_ft_usage() {
  cat <<'EOF'
Usage: dev ft NAME | dev ft -l | dev ft -r NAME | dev ft -rf NAME
       dev fta [-cl|-op|-pi] NAME

  ft NAME      Create branch feat/NAME off origin/main (FT_BASE or
               'git config ft.base' overrides) with a worktree at
               .worktrees/NAME — reused if it exists — and open a host
               herdr tab cd'd into it.
  fta NAME     Same, then: start this workspace's container headless if
               needed, build the worktree to completion (mise install +
               the 'setup' task), attach the tab into it, and start
               the agent found there (claude, opencode, or pi; a plain
               shell when none is installed). -cl/-op/-pi pick explicitly;
               FT_AGENT or 'git config ft.agent' set a default.
  ft -l        List the repo's worktrees and branches.
  ft -r NAME   Remove worktree, tab and branch — refuses uncommitted or
               unpushed work and running mise daemons. Branch is deleted
               only when merged into the base.
  ft -rf NAME  Force: stop daemons, discard everything.

Tabs need a running host herdr session; without one, ft still prepares
the worktree and says so.
EOF
}

# The repo's MAIN checkout, even when invoked from inside a worktree (where
# --show-toplevel would return the worktree) or a subdirectory. Everything
# hangs off this: the .worktrees/ layout, and the one-container-per-repository
# invariant below.
_ft_repo_root() {
  _ft_g=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [[ -z "$_ft_g" || ! -d "$_ft_g" ]]; then
    echo "Error: dev ft: run it from inside a git repository." >&2
    exit 1
  fi
  printf '%s' "${_ft_g%/.git}"
}

_ft_base() {
  _ft_b="${FT_BASE:-$(git config ft.base 2>/dev/null || true)}"
  printf '%s' "${_ft_b:-origin/main}"
}

_ft_check_name() {
  if [[ -z "${1:-}" ]]; then
    echo "Error: dev ft: a feature NAME is required." >&2; exit 1
  fi
  if ! [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: dev ft: NAME must match [A-Za-z0-9][A-Za-z0-9._-]* (got '$1')." >&2; exit 1
  fi
}

# Create the branch + worktree with plain host git when missing; reuse
# otherwise. Sets FT_ROOT, FT_BRANCH, FT_WT.
_ft_ensure_worktree() {
  FT_ROOT=$(_ft_repo_root)
  FT_BRANCH="feat/$1"
  FT_WT="$FT_ROOT/.worktrees/$1"
  # Clone-wide exclude so worktrees never show as untracked, even on branches
  # whose .gitignore predates them.
  grep -qx '.worktrees/' "$FT_ROOT/.git/info/exclude" 2>/dev/null \
    || echo '.worktrees/' >> "$FT_ROOT/.git/info/exclude"
  if [[ -d "$FT_WT" ]]; then
    echo "ft: $FT_BRANCH already exists at $FT_WT — reusing it." >&2
    return 0
  fi
  _ft_b=$(_ft_base)
  case "$_ft_b" in origin/*) git -C "$FT_ROOT" fetch --quiet origin "${_ft_b#origin/}" ;; esac
  if git -C "$FT_ROOT" show-ref --verify --quiet "refs/heads/$FT_BRANCH"; then
    git -C "$FT_ROOT" worktree add "$FT_WT" "$FT_BRANCH"
  else
    git -C "$FT_ROOT" worktree add --no-track "$FT_WT" -b "$FT_BRANCH" "$_ft_b"
  fi
}

# Open a host herdr tab at the worktree; prints the pane id, or nothing when
# no herdr session is reachable (the worktree is still ready).
_ft_tab() {
  command -v jq >/dev/null 2>&1 \
    || { echo "Error: dev ft: jq is required on the host." >&2; exit 1; }
  if ! command -v herdr >/dev/null 2>&1; then
    echo "ft: no herdr on the host PATH — worktree ready at $FT_WT, tab skipped." >&2
    return 0
  fi
  if _ft_out=$(herdr tab create --label "$1" --cwd "$FT_WT" --focus 2>&1); then
    jq -r '.result.root_pane.pane_id // empty' <<<"$_ft_out"
  else
    echo "ft: could not open a herdr tab (is a herdr session running?) — worktree ready at $FT_WT." >&2
    printf '%s\n' "$_ft_out" >&2
  fi
}

_ft_open() {
  _ft_check_name "${1:-}"
  _ft_ensure_worktree "$1"
  _ft_pane=$(_ft_tab "$1")
  [[ -n "$_ft_pane" ]] && echo "ft: $FT_BRANCH — tab open at $FT_WT"
}

# No container? Start one headless and keep going — dev's own start flow with
# `sleep infinity` as the command, backgrounded: it outlives this invocation
# and every shell; `dev shell` attaches, `dev down` stops it. stdin is
# /dev/null so a cold start cannot wedge on a prompt; the interactive cases
# (first build, allowlist approval, rebuild offer) time out with a pointer.
_ft_autostart() {
  echo "ft: no container running for this workspace — starting one in the background" >&2
  nohup "$SCRIPT_DIR/dev" exec -- sleep infinity </dev/null >/dev/null 2>&1 &
  _ft_waited=0
  while [[ "$_ft_waited" -lt 60 ]]; do
    resolve_managed_container
    [[ -n "$MANAGED_TARGET" ]] && return 0
    sleep 1
    _ft_waited=$((_ft_waited + 1))
  done
  echo "Error: the container did not come up within 60s. A first image build, an" >&2
  echo "       allowlist approval, or a rebuild offer needs a terminal: run" >&2
  echo "       'dev up' once interactively, then retry." >&2
  exit 1
}

_ft_require_container() {
  # One container per repository: dev derives the container name from the
  # basename of $PWD, so resolve from the repo's main checkout regardless of
  # where ft was invoked (a worktree, a subdirectory). This cwd also carries
  # into the backgrounded autostart, which mounts it as /workspace — the main
  # checkout, never a worktree.
  cd "${FT_ROOT:-$(_ft_repo_root)}" || exit 1
  detect_runtime
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  NEEDS_ENGINE=true
  ensure_runtime_ready
  _resolve_workspace_names
  resolve_managed_container
  [[ -z "$MANAGED_TARGET" ]] && _ft_autostart
  if [[ "$MANAGED_TARGET" == "maint" ]]; then
    echo "Error: ${MAINT_NAME} is a maintenance container (sudo, no firewall) — not a place for agents. 'dev up' starts the normal one." >&2
    exit 1
  fi
}

_ft_open_attach() {
  _ft_kind="$1"
  _ft_check_name "${2:-}"
  _ft_ensure_worktree "$2"
  _ft_require_container
  _ft_cwt="/workspace/.worktrees/$2"
  # Build to completion BEFORE the agent sees the tree — the classic ft
  # guarantee: tools, the committed 'setup' task when one exists, daemon
  # registration. Fatal on failure; the worktree survives for fixing.
  # shellcheck disable=SC2016  # $-expansion happens container-side, by design
  _ft_build='export PATH="$HOME/.local/bin:$PATH"; mise trust >/dev/null 2>&1 || mise trust; mise install; if mise tasks ls 2>/dev/null | grep -qE "^setup([[:space:]]|$)"; then mise run setup; else echo "ft: no setup task in mise.toml — skipping the build step." >&2; fi; mise daemons register >/dev/null 2>&1 || true'
  echo "ft: building $FT_BRANCH before the agent (mise install + setup; first run can take a while)" >&2
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  if ! $RUNTIME $MANAGED_RUNTIME_ARGS exec --user vscode -w "$_ft_cwt" "$MANAGED_NAME" sh -c "$_ft_build"; then
    echo "Error: the build failed in $_ft_cwt — fix it ('dev shell'), then re-run 'dev fta $2'." >&2
    exit 1
  fi
  if [[ -z "$_ft_kind" ]]; then
    _ft_kind="${FT_AGENT:-$(git config ft.agent 2>/dev/null || true)}"
  fi
  if [[ -z "$_ft_kind" ]]; then
    # shellcheck disable=SC2086,SC2016  # arg word-splitting intended; $-expansion happens container-side
    _ft_kind=$($RUNTIME $MANAGED_RUNTIME_ARGS exec --user vscode "$MANAGED_NAME" \
      sh -c 'PATH="$HOME/.local/bin:$PATH"; for a in claude opencode pi; do command -v "$a" >/dev/null 2>&1 && { echo "$a"; exit 0; }; done; exit 0')
  fi
  # Do not exec the agent: when it exits (double Ctrl+C is claude's exit
  # chord), fall through to an interactive shell IN the container at the
  # worktree, instead of tearing the whole attach down to the host prompt.
  if [[ -n "$_ft_kind" ]]; then
    _ft_inner="export PATH=\"\$HOME/.local/bin:\$PATH\"; cd $_ft_cwt 2>/dev/null; $_ft_kind; exec zsh"
  else
    _ft_inner="export PATH=\"\$HOME/.local/bin:\$PATH\"; cd $_ft_cwt 2>/dev/null; exec zsh"
  fi
  _ft_cmd=$(printf '%s %s exec -it --user vscode -w %s %s sh -c %q' \
            "$RUNTIME" "$MANAGED_RUNTIME_ARGS" "$_ft_cwt" "$MANAGED_NAME" "$_ft_inner")
  _ft_pane=$(_ft_tab "$2")
  if [[ -z "$_ft_pane" ]]; then
    echo "Error: dev fta needs a running host herdr session for the tab (worktree is ready)." >&2
    exit 1
  fi
  herdr pane run "$_ft_pane" "$_ft_cmd"
  if [[ -n "$_ft_kind" ]]; then
    echo "ft: $FT_BRANCH — tab attached to the container, agent: $_ft_kind"
  else
    echo "ft: $FT_BRANCH — tab attached to the container; no agent binary found"
    echo "ft: (claude/opencode/pi) — plain shell. Install one and 'dev agent add KIND'."
  fi
}

_ft_list() {
  _ft_root=$(_ft_repo_root)
  exec git -C "$_ft_root" worktree list
}

_ft_remove() {
  _ft_force="$1"
  _ft_check_name "${2:-}"
  _ft_root=$(_ft_repo_root)
  _ft_branch="feat/$2"
  _ft_wt="$_ft_root/.worktrees/$2"
  _ft_b=$(_ft_base)
  # Close this feature's host herdr tabs first (same label ft opened them with).
  if command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    for _ft_t in $(herdr tab list 2>/dev/null \
                   | jq -r --arg l "$2" '.result.tabs[]? | select(.label == $l) | .tab_id'); do
      herdr tab close "$_ft_t" >/dev/null 2>&1 || true
    done
  fi
  if [[ -d "$_ft_wt" ]]; then
    if [[ "$_ft_force" = 0 ]]; then
      if [[ -n "$(git -C "$_ft_wt" status --porcelain 2>/dev/null)" ]]; then
        echo "Error: $_ft_wt has uncommitted changes (commit/push, or -rf to discard)." >&2; exit 1
      fi
      _ft_up="origin/$_ft_branch"
      git -C "$_ft_root" show-ref --verify --quiet "refs/remotes/$_ft_up" || _ft_up="$_ft_b"
      if [[ "$(git -C "$_ft_root" rev-list --count "$_ft_up..$_ft_branch" 2>/dev/null)" != 0 ]]; then
        echo "Error: $_ft_branch has commits not on $_ft_up (push, or -rf to discard)." >&2; exit 1
      fi
      if command -v mise >/dev/null 2>&1 \
         && (cd "$_ft_wt" && mise daemons ls 2>/dev/null | grep -Eiq 'running|starting'); then
        echo "Error: servers are still running in $_ft_wt ('mise daemons stop', or -rf)." >&2; exit 1
      fi
      git -C "$_ft_root" worktree remove "$_ft_wt"
    else
      if command -v mise >/dev/null 2>&1; then
        (cd "$_ft_wt" && mise daemons stop >/dev/null 2>&1) || true
      fi
      git -C "$_ft_root" worktree remove --force "$_ft_wt"
    fi
  else
    git -C "$_ft_root" worktree prune
  fi
  if git -C "$_ft_root" show-ref --verify --quiet "refs/heads/$_ft_branch"; then
    if [[ "$_ft_force" = 1 ]] || git -C "$_ft_root" merge-base --is-ancestor "$_ft_branch" "$_ft_b"; then
      git -C "$_ft_root" branch -D "$_ft_branch"
    else
      echo "ft: worktree removed; branch $_ft_branch kept (not merged into $_ft_b — 'dev ft -rf $2' discards it)." >&2
    fi
  else
    echo "ft: branch $_ft_branch already gone."
  fi
}
