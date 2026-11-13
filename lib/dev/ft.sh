# shellcheck shell=bash
# lib/dev/ft.sh — `dev ft {new,rm,ls,sync,enable,disable,shell-init}`: feature
# workspaces for parallel coding agents. One git worktree per feature under
# /workspace/.worktrees/<name>, a herdr workspace/tab for it, a build step
# (`mise run setup`) that completes BEFORE the agent starts, and an opt-in
# stdio-SSH path (`enable`) so a host herdr window can aggregate containers
# via `herdr machine add` — no listener, no published port, no root daemon.
# Everything here is opt-in: no existing verb or default changes. The
# container-side halves live in scripts/ft/*.sh and are piped over exec, so
# nothing needs injecting into home volumes. Sourced by dev; not executed
# directly.

# Upstream repo for `dev ft sync`'s mise ubi install of herdr inside the
# container. Overridable for forks/mirrors.
FT_HERDR_REPO="${FT_HERDR_REPO:-herdrdev/herdr}"

# cmd_ft <action> [args]: the `dev ft` verb. Validates the action and
# dispatches; each handler exits on its own.
cmd_ft() {
  ft_action="${1:-}"
  case "$ft_action" in
    new|rm|ls|sync|enable|disable|shell-init) shift ;;
    ''|-h|--help|help) _ft_usage; exit 0 ;;
    *)
      echo "Error: dev ft: expected an action (new|rm|ls|sync|enable|disable|shell-init), got '${ft_action:-<none>}'" >&2
      echo "Run 'dev --help' for usage information" >&2
      exit 1
      ;;
  esac
  case "$ft_action" in
    new)        _ft_new "$@" ;;
    rm)         _ft_rm "$@" ;;
    ls)         _ft_ls "$@" ;;
    sync)       _ft_sync "$@" ;;
    enable)     _ft_enable "$@" ;;
    disable)    _ft_disable "$@" ;;
    shell-init) _ft_shell_init "$@" ;;
  esac
  exit 0
}

_ft_usage() {
  cat <<'EOF'
Usage: dev ft <action> [args]

Feature workspaces: one worktree + herdr tab + agent per feature, inside
this workspace's running dev container.

  new NAME [-- AGENT_ARGS...]  Branch feat/NAME off origin/main (FT_BASE
                               or 'git config ft.base' overrides, e.g.
                               'main' for a repo with no remote), worktree
                               at .worktrees/NAME,
                               herdr tab, 'mise run setup', then the agent.
  rm [-f] NAME                 Stop daemons, remove worktree + tab; delete
                               the branch only if merged. -f discards work.
  ls                           herdr's worktree listing for this container.
  sync                         Install the host herdr's exact version into
                               the container (FT_HERDR_REPO overrides the
                               GitHub repo used by mise's ubi backend).
  enable [--write]             One-time per repo: generate the container's
                               ssh host key + sshd_config, authorize your
                               public key, and print (or --write) the
                               ~/.ssh/config ProxyCommand stanza for
                               'herdr machine add'. The toggle ON.
  disable                      Remove that ssh material. The toggle OFF.
  shell-init                   Print shell helpers (ft/ftcd/ftls/ftrm/
                               ftsync + completion) for your rc file:
                               eval "$(dev ft shell-init)"

Starts this workspace's container headless when none is running ('dev
shell' attaches to it; 'dev down' stops it). Needs herdr inside the
container: 'dev ft sync' once. 'enable' is the only step that touches SSH;
without it nothing listens and nothing is reachable.
EOF
}

# No container? Start one headless and keep going — parity with `dev exec`,
# which also cold-starts. The keep-alive is dev's own start flow with
# `sleep infinity` as the command, backgrounded: the container outlives this
# dev invocation (and any attached shell), `dev shell` attaches to it later,
# and `dev down` stops it. stdin is /dev/null so a cold start cannot block on
# a prompt; the cases that need one (first image build, a project-allowlist
# approval, a rebuild offer) need a real terminal — the timeout message
# points there.
_ft_autostart() {
  echo "ft: no container running for this workspace — starting one in the background" >&2
  echo "ft: ('dev shell' attaches to it; 'dev down' stops it)" >&2
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

# Shared preamble: resolve this workspace's container, auto-starting a
# headless one when nothing runs. ft works against normal/dind/pind (they all
# mount /workspace); maintenance is refused — it has sudo and no firewall,
# the wrong place for an agent.
_ft_require_container() {
  detect_runtime
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  NEEDS_ENGINE=true
  ensure_runtime_ready
  _resolve_workspace_names
  resolve_managed_container
  if [[ -z "$MANAGED_TARGET" ]]; then
    _ft_autostart
  fi
  if [[ "$MANAGED_TARGET" == "maint" ]]; then
    echo "Error: ${MAINT_NAME} is a maintenance container (sudo, no firewall) — not a place to run agents. Start the normal container with 'dev up'." >&2
    exit 1
  fi
}

# Run one container-side script from scripts/ft/ with stdin as the transport:
# no file ever needs copying into the image or a home volume, and the script
# version always matches this checkout of dev. Args after the script name are
# passed through to it. FT_BASE crosses the boundary explicitly — exec starts
# a fresh environment, so the host's value (or the repo's `git config
# ft.base`, for a per-repo default) is forwarded as --env; otherwise the
# container-side default (origin/main) applies.
_ft_exec_script() {
  _ft_script="$SCRIPT_DIR/scripts/ft/$1"; shift
  if [[ ! -f "$_ft_script" ]]; then
    echo "Error: dev ft: missing $_ft_script — partial checkout?" >&2
    exit 1
  fi
  _ft_base="${FT_BASE:-$(git config ft.base 2>/dev/null || true)}"
  _ft_env=()
  [[ -n "$_ft_base" ]] && _ft_env=(--env "FT_BASE=$_ft_base")
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  $RUNTIME $MANAGED_RUNTIME_ARGS exec -i --user vscode ${_ft_env[@]+"${_ft_env[@]}"} "$MANAGED_NAME" \
    bash -s -- "$@" < "$_ft_script"
}

# Feature names become branch suffixes, directory names and (inside) agent
# names; keep them to one safe charset up front so every consumer agrees.
_ft_check_name() {
  if [[ -z "${1:-}" ]]; then
    echo "Error: dev ft: a feature NAME is required." >&2
    exit 1
  fi
  if ! [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: dev ft: NAME must match [A-Za-z0-9][A-Za-z0-9._-]* (got '$1')." >&2
    exit 1
  fi
}

_ft_new() {
  _ft_check_name "${1:-}"
  _ft_require_container
  _ft_exec_script inner-new.sh "$@"
}

_ft_rm() {
  _ft_name_arg="${1:-}"
  [[ "$_ft_name_arg" == "-f" ]] && _ft_name_arg="${2:-}"
  _ft_check_name "$_ft_name_arg"
  _ft_require_container
  _ft_exec_script inner-rm.sh "$@"
}

_ft_ls() {
  _ft_require_container
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec --user vscode "$MANAGED_NAME" herdr worktree list
}

_ft_sync() {
  if ! command -v herdr >/dev/null 2>&1; then
    echo "Error: dev ft sync: no 'herdr' on the host PATH — it mirrors the HOST client's version into the container." >&2
    exit 1
  fi
  _ft_ver="$(herdr --version 2>/dev/null | tr -dc '0-9.')"
  if [[ -z "$_ft_ver" ]]; then
    echo "Error: dev ft sync: could not parse a version from 'herdr --version'." >&2
    exit 1
  fi
  _ft_require_container
  _ft_exec_script inner-sync.sh "$_ft_ver" "$FT_HERDR_REPO"
}

# The opt-in toggle. Generates per-workspace ssh material inside the home
# volume (host-key fingerprint therefore survives rebuilds; 'dev reset'
# regenerates it) and authorizes the host user's public key. Nothing starts:
# the printed ProxyCommand spawns a per-session `sshd -i` as vscode, over the
# runtime's exec, only for the duration of each connection.
_ft_enable() {
  _ft_write=false
  [[ "${1:-}" == "--write" ]] && _ft_write=true
  _ft_pub=""
  for _ft_k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [[ -f "$_ft_k" ]] && { _ft_pub="$(cat "$_ft_k")"; break; }
  done
  if [[ -z "$_ft_pub" ]]; then
    echo "Error: dev ft enable: no ~/.ssh/id_ed25519.pub or id_rsa.pub found — create a keypair first (ssh-keygen -t ed25519)." >&2
    exit 1
  fi
  _ft_require_container
  _ft_exec_script inner-enable.sh "$_ft_pub"
  _ft_host="dev-${WORKSPACE_BASENAME}"
  _ft_stanza="Host ${_ft_host}
  User vscode
  ProxyCommand ${RUNTIME}${MANAGED_RUNTIME_ARGS:+ ${MANAGED_RUNTIME_ARGS}} exec -i --user vscode ${MANAGED_NAME} /usr/sbin/sshd -i -f /home/vscode/.ssh/sshd_config"
  if [[ "$_ft_write" == true ]]; then
    if grep -q "^Host ${_ft_host}\$" "$HOME/.ssh/config" 2>/dev/null; then
      echo "ft enable: ~/.ssh/config already has 'Host ${_ft_host}' — left untouched."
    else
      mkdir -p "$HOME/.ssh"
      printf '\n%s\n' "$_ft_stanza" >> "$HOME/.ssh/config"
      echo "ft enable: appended 'Host ${_ft_host}' to ~/.ssh/config."
    fi
  else
    echo
    echo "Add to ~/.ssh/config (or re-run with --write):"
    echo
    printf '%s\n' "$_ft_stanza"
  fi
  echo
  echo "Then, once:  ssh ${_ft_host} herdr --version     # accepts the host key"
  echo "             herdr machine add ${_ft_host} --label ${WORKSPACE_BASENAME}"
}

_ft_disable() {
  _ft_require_container
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  $RUNTIME $MANAGED_RUNTIME_ARGS exec --user vscode "$MANAGED_NAME" \
    rm -f /home/vscode/.ssh/sshd_config /home/vscode/.ssh/host_ed25519 /home/vscode/.ssh/host_ed25519.pub
  echo "ft disable: ssh material removed from the container."
  echo "Remember to drop the 'Host dev-${WORKSPACE_BASENAME}' stanza from ~/.ssh/config"
  echo "and 'herdr machine rm' the entry if you registered one."
}

# Shell helpers for the host rc file. ftcd must be a shell function (it cd's),
# so these cannot be dev subcommands; everything else is a thin wrapper. zsh
# users need bashcompinit loaded before the eval for the completion to bind.
_ft_shell_init() {
  cat <<'EOF'
ft()     { dev ft new "$@"; }
ftls()   { dev ft ls "$@"; }
ftrm()   { dev ft rm "$@"; }
ftsync() { dev ft sync "$@"; }
ftcd() {
  local _root
  _root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo 'ftcd: not inside a git repository' >&2; return 1; }
  if [ -n "${1:-}" ]; then cd "$_root/.worktrees/$1"; else cd "$_root"; fi
}
_ft_complete() {
  local _root
  _root=$(git rev-parse --show-toplevel 2>/dev/null) || return
  COMPREPLY=($(compgen -W "$(ls "$_root/.worktrees" 2>/dev/null)" -- "${COMP_WORDS[COMP_CWORD]}"))
}
if command -v complete >/dev/null 2>&1; then
  complete -F _ft_complete ftcd ftrm 2>/dev/null || true
fi
EOF
}
