# shellcheck shell=bash
# lib/dev/ft.sh — `dev ft`: feature worktrees with host-herdr tabs. The herdr
# you use is the HOST one: `dev ft NAME` creates (or reuses) the feature
# branch + worktree under <repo>/.worktrees/ and opens a tab whose shell sits
# in it; the container side (`dev fta`) lives in lib/dev/fta.sh. Host deps:
# git >= 2.48 (relative worktree pointers) and jq. Sourced by dev.

cmd_ft() {
  case "${1:-}" in
    -l)  _ft_list ;;
    -r)  shift; _ft_remove 0 "${1:-}" ;;
    -rf) shift; _ft_remove 1 "${1:-}" ;;
    ''|-h|--help|help) _ft_usage ;;
    --completions) _ft_completions ;;
    -*)
      echo "Error: dev ft: unknown flag '${1}' (-l, -r NAME, -rf NAME, or NAME)" >&2
      exit 1
      ;;
    *)   _ft_open "$@" ;;
  esac
  exit 0
}

_ft_usage() {
  cat <<'EOF'
Usage: dev ft NAME | dev ft -l | dev ft -r NAME | dev ft -rf NAME
       dev fta [-cl|-op|-pi] [--open|--closed] NAME

  ft NAME      Create branch feat/NAME off origin/main (FT_BASE or
               'git config ft.base' overrides) with a worktree at
               .worktrees/NAME — reused if it exists — and open a host
               herdr tab cd'd into it.
  fta NAME     Same, then: start this workspace's container headless if
               needed (--open/--closed set the egress mode when it is
               CREATED here), build the worktree to completion (mise
               install + the 'setup' task), attach the tab into it, and
               start the agent found there (claude, opencode, or pi; a
               plain shell when none). -cl/-op/-pi pick explicitly;
               FT_AGENT or 'git config ft.agent' set a default.
  ft -l        List the repo's worktrees and branches.
  ft -r NAME   Remove worktree, tab and branch — refuses uncommitted or
               unpushed work and running mise daemons (host AND
               container) BEFORE touching the tab. Branch is deleted
               only when merged into the base.
  ft -rf NAME  Force: stop daemons on both sides, discard everything.

Tabs need a running host herdr session; worktrees are prepared either way.
EOF
}

# ft/fta completion (names + flags), bash-compatible (zsh: bashcompinit).
# Eval BELOW dev install's compdef line:  eval "$(dev ft --completions)"
_ft_completions() {
  cat <<'EOF'
_dev_ft_complete() {
  local cur root
  [ "${COMP_WORDS[1]}" = ft ] || [ "${COMP_WORDS[1]}" = fta ] || return 0
  cur=${COMP_WORDS[COMP_CWORD]}
  case "$cur" in
    -*) COMPREPLY=($(compgen -W "-l -r -rf -cl -op -pi --open --closed" -- "$cur")); return 0 ;;
  esac
  root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  root=${root%/.git}
  COMPREPLY=($(compgen -W "$(ls "$root/.worktrees" 2>/dev/null)" -- "$cur"))
}
complete -F _dev_ft_complete dev
EOF
}

# The repo's MAIN checkout even from inside a worktree (--show-toplevel would
# return the worktree): anchors .worktrees/ and one-container-per-repo.
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

# Create branch + worktree with host git, or reuse. Sets FT_ROOT/BRANCH/WT.
# Worktree pointers must be RELATIVE or git inside the container fails on the
# host-absolute gitdir path: set the config (a no-op before git 2.48) and
# verify the created pointer, warning loudly when it came out absolute.
_ft_ensure_worktree() {
  FT_ROOT=$(_ft_repo_root)
  FT_BRANCH="feat/$1"
  FT_WT="$FT_ROOT/.worktrees/$1"
  grep -qx '.worktrees/' "$FT_ROOT/.git/info/exclude" 2>/dev/null \
    || echo '.worktrees/' >> "$FT_ROOT/.git/info/exclude"
  if [[ -d "$FT_WT" ]]; then
    echo "ft: $FT_BRANCH already exists at $FT_WT — reusing it." >&2
    return 0
  fi
  git -C "$FT_ROOT" config worktree.useRelativePaths true 2>/dev/null || true
  _ft_b=$(_ft_base)
  case "$_ft_b" in origin/*) git -C "$FT_ROOT" fetch --quiet origin "${_ft_b#origin/}" ;; esac
  if git -C "$FT_ROOT" show-ref --verify --quiet "refs/heads/$FT_BRANCH"; then
    git -C "$FT_ROOT" worktree add "$FT_WT" "$FT_BRANCH"
  else
    git -C "$FT_ROOT" worktree add --no-track "$FT_WT" -b "$FT_BRANCH" "$_ft_b"
  fi
  if grep -q '^gitdir: /' "$FT_WT/.git" 2>/dev/null; then
    echo "ft: WARNING — the worktree's .git pointer is an absolute host path;" >&2
    echo "ft: git inside the container will fail there. Upgrade host git to" >&2
    echo "ft: >= 2.48 (worktree.useRelativePaths) and recreate the worktree." >&2
  fi
}

# Host herdr tab at the worktree; prints pane id, or nothing without a
# session. Records the tab id under .git/ft-tabs/<name> so removal closes
# exactly the tabs ft opened — not same-labelled tabs from other repos.
_ft_tab() {
  command -v jq >/dev/null 2>&1 \
    || { echo "Error: dev ft: jq is required on the host." >&2; exit 1; }
  if ! command -v herdr >/dev/null 2>&1; then
    echo "ft: no herdr on the host PATH — worktree ready at $FT_WT, tab skipped." >&2
    return 0
  fi
  if _ft_out=$(herdr tab create --label "$1" --cwd "$FT_WT" --focus 2>&1); then
    _ft_tid=$(jq -r '.result.tab.tab_id // empty' <<<"$_ft_out")
    if [[ -n "$_ft_tid" ]]; then
      mkdir -p "$FT_ROOT/.git/ft-tabs"
      echo "$_ft_tid" >> "$FT_ROOT/.git/ft-tabs/$1"
    fi
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
  if [[ -n "$_ft_pane" ]]; then
    echo "ft: $FT_BRANCH — tab open at $FT_WT"
    echo "ft: (build-free: 'mise run setup' there before host dev servers; 'dev fta $1' builds the container side)"
  fi
}

_ft_list() {
  _ft_root=$(_ft_repo_root)
  exec git -C "$_ft_root" worktree list
}

# Close the tabs ft recorded for this feature. Others first; a tab we are
# running inside (HERDR_TAB_ID) is deferred to FT_SELF_TAB so the caller can
# close it LAST — after the removal work is done, not before.
_ft_close_tabs() {
  FT_SELF_TAB=""
  _ft_f="$_ft_root/.git/ft-tabs/$1"
  [[ -f "$_ft_f" ]] || return 0
  if command -v herdr >/dev/null 2>&1; then
    while IFS= read -r _ft_t; do
      [[ -n "$_ft_t" ]] || continue
      if [[ "$_ft_t" == "${HERDR_TAB_ID:-}" ]]; then
        FT_SELF_TAB="$_ft_t"
        continue
      fi
      herdr tab close "$_ft_t" >/dev/null 2>&1 || true
    done < "$_ft_f"
  fi
  rm -f "$_ft_f"
}

_ft_remove() {
  _ft_force="$1"
  _ft_check_name "${2:-}"
  _ft_root=$(_ft_repo_root)
  _ft_branch="feat/$2"
  _ft_wt="$_ft_root/.worktrees/$2"
  _ft_cwt="/workspace/.worktrees/$2"
  _ft_b=$(_ft_base)
  cd "$_ft_root" || exit 1
  _ft_have_ct=0
  _fta_soft_resolve && _ft_have_ct=1
  if [[ -d "$_ft_wt" ]]; then
    if [[ "$_ft_force" = 0 ]]; then
      # Every refusal check runs BEFORE any tab is touched.
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
        echo "Error: host-side servers are still running in $_ft_wt ('mise daemons stop', or -rf)." >&2; exit 1
      fi
      if [[ "$_ft_have_ct" = 1 ]] \
         && _fta_exec -w "$_ft_cwt" "$MANAGED_NAME" sh -c 'command -v mise >/dev/null 2>&1 && mise daemons ls 2>/dev/null | grep -Eiq "running|starting"' 2>/dev/null; then
        echo "Error: container-side servers are still running in $_ft_cwt (stop them, or -rf)." >&2; exit 1
      fi
    else
      if command -v mise >/dev/null 2>&1; then
        (cd "$_ft_wt" && mise daemons stop >/dev/null 2>&1) || true
      fi
      if [[ "$_ft_have_ct" = 1 ]]; then
        _fta_exec -w "$_ft_cwt" "$MANAGED_NAME" sh -c 'command -v mise >/dev/null 2>&1 && mise daemons stop >/dev/null 2>&1; true' 2>/dev/null || true
      fi
    fi
    _ft_close_tabs "$2"
    if [[ "$_ft_force" = 1 ]]; then
      git -C "$_ft_root" worktree remove --force "$_ft_wt"
    else
      git -C "$_ft_root" worktree remove "$_ft_wt"
    fi
  else
    _ft_close_tabs "$2"
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
  # Self-tab last: closing it ends this process, so the work above is done.
  if [[ -n "${FT_SELF_TAB:-}" ]] && command -v herdr >/dev/null 2>&1; then
    herdr tab close "$FT_SELF_TAB" >/dev/null 2>&1 || true
  fi
}
