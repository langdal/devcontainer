# shellcheck shell=bash
# lib/dev/fta.sh — `dev fta` and the container side of feature worktrees:
# autostart with readiness, exec-env mirroring, build, attach. Split from
# ft.sh for the module line budget. Sourced by dev; not executed directly.

cmd_fta() {
  ft_kind=""
  FTA_MODE_ARGS=()
  while :; do
    case "${1:-}" in
      -cl) ft_kind=claude;   shift ;;
      -op) ft_kind=opencode; shift ;;
      -pi) ft_kind=pi;       shift ;;
      --open|--closed) FTA_MODE_ARGS=("$1"); shift ;;  # creation-time egress for the autostart
      ''|-h|--help|help) _ft_usage; exit 0 ;;
      *) break ;;
    esac
  done
  _ft_open_attach "$ft_kind" "${1:-}"
  exit 0
}

# Mirror container.sh's attach-path env: exec bypasses the entrypoint, so a
# closed-mode container's proxy trio and the dind/pind DOCKER_HOST must be
# re-injected or connections are silently dropped. Values must stay in sync
# with entrypoint.sh. Fills FTA_ENV; callers pass it to the runtime exec.
_fta_env() {
  FTA_ENV=()
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  _fta_cmode=$($RUNTIME $MANAGED_RUNTIME_ARGS exec "$MANAGED_NAME" printenv DEVCONTAINER_EGRESS 2>/dev/null || true)
  if [[ "$_fta_cmode" == closed ]]; then
    # shellcheck disable=SC2054  # commas are part of the NO_PROXY value
    FTA_ENV+=(-e HTTPS_PROXY=http://127.0.0.1:8888
              -e HTTP_PROXY=http://127.0.0.1:8888
              -e NO_PROXY=localhost,127.0.0.1,host.docker.internal)
  fi
  if [[ "$MANAGED_NAME" == "$DIND_NAME" ]]; then
    FTA_ENV+=(-e DOCKER_HOST=unix:///home/vscode/.dind-run/docker.sock
              -e XDG_RUNTIME_DIR=/home/vscode/.dind-run)
  elif [[ "$MANAGED_NAME" == "$PIND_NAME" ]]; then
    FTA_ENV+=(-e DOCKER_HOST=unix:///home/vscode/.pind-run/podman.sock
              -e XDG_RUNTIME_DIR=/home/vscode/.pind-run)
  fi
}

# Runtime exec into the managed container with the mirrored env.
_fta_exec() {
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  $RUNTIME $MANAGED_RUNTIME_ARGS exec ${FTA_ENV[@]+"${FTA_ENV[@]}"} --user vscode "$@"
}

# No container? Background dev's own start flow with `sleep infinity`. The
# entrypoint (firewall-init, base mise install) runs BEFORE exec'ing the
# command, so PID1's comm flipping to "sleep" is the completion marker: no
# repo code runs before the egress rules exist, and our build's mise cannot
# race the entrypoint's on /mise. stdin=/dev/null so prompts can't wedge it.
_ft_autostart() {
  echo "ft: no container running for this workspace — starting one in the background" >&2
  nohup "$SCRIPT_DIR/dev" exec ${FTA_MODE_ARGS[@]+"${FTA_MODE_ARGS[@]}"} -- sleep infinity </dev/null >/dev/null 2>&1 &
  _ft_waited=0
  while [[ "$_ft_waited" -lt 90 ]]; do
    resolve_managed_container
    if [[ -n "$MANAGED_TARGET" ]]; then
      # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
      _ft_c=$($RUNTIME $MANAGED_RUNTIME_ARGS exec "$MANAGED_NAME" cat /proc/1/comm 2>/dev/null || true)
      [[ "$_ft_c" == sleep* ]] && return 0
    fi
    sleep 1
    _ft_waited=$((_ft_waited + 1))
  done
  echo "Error: container not ready within 90s — a first build/approval needs a" >&2
  echo "       terminal: run 'dev up' once interactively, then retry." >&2
  exit 1
}

_ft_require_container() {
  # One container per repository: names derive from $PWD's basename, so
  # resolve from the main checkout wherever ft was invoked; the cwd also
  # scopes the autostart's /workspace mount to the main checkout.
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
  _fta_env
}

# Soft resolve for `ft -r`: container context if one is running, never starts
# anything, returns 1 when there is no engine or no container.
_fta_soft_resolve() {
  { command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; } || return 1
  detect_runtime
  _resolve_workspace_names
  MANAGED_TARGET=""
  resolve_managed_container 2>/dev/null || true
  [[ -n "$MANAGED_TARGET" && "$MANAGED_TARGET" != maint ]] || return 1
  _fta_env
}

_ft_open_attach() {
  _ft_kind="$1"
  _ft_check_name "${2:-}"
  _ft_ensure_worktree "$2"
  _ft_require_container
  _ft_cwt="/workspace/.worktrees/$2"
  # Build BEFORE the agent sees the tree: tools, 'setup' task if present,
  # daemon registration. set -e makes failures fatal; the worktree survives.
  # shellcheck disable=SC2016  # $-expansion happens container-side, by design
  _ft_build='set -e; export PATH="$HOME/.local/bin:$PATH"; mise trust >/dev/null 2>&1 || mise trust; mise install; if mise tasks ls 2>/dev/null | grep -qE "^setup([[:space:]]|$)"; then mise run setup; else echo "ft: no setup task in mise.toml — skipping the build step." >&2; fi; mise daemons register >/dev/null 2>&1 || true'
  echo "ft: building $FT_BRANCH before the agent (mise install + setup; first run can take a while)" >&2
  if ! _fta_exec -w "$_ft_cwt" "$MANAGED_NAME" sh -c "$_ft_build"; then
    echo "Error: the build failed in $_ft_cwt — fix it ('dev shell'), then re-run 'dev fta $2'." >&2
    exit 1
  fi
  if [[ -z "$_ft_kind" ]]; then
    _ft_kind="${FT_AGENT:-$(git config ft.agent 2>/dev/null || true)}"
  fi
  if [[ -z "$_ft_kind" ]]; then
    # shellcheck disable=SC2016  # $-expansion happens container-side, by design
    _ft_kind=$(_fta_exec "$MANAGED_NAME" sh -c 'PATH="$HOME/.local/bin:$PATH"; for a in claude opencode pi; do command -v "$a" >/dev/null 2>&1 && { echo "$a"; exit 0; }; done; exit 0')
  fi
  # No exec: when the agent exits (double Ctrl+C is claude's exit chord),
  # fall through to a container shell instead of the host prompt.
  if [[ -n "$_ft_kind" ]]; then
    _ft_inner="export PATH=\"\$HOME/.local/bin:\$PATH\"; cd $_ft_cwt 2>/dev/null; $_ft_kind; exec zsh"
  else
    _ft_inner="export PATH=\"\$HOME/.local/bin:\$PATH\"; cd $_ft_cwt 2>/dev/null; exec zsh"
  fi
  _ft_cmd=$(printf '%s %s exec -it %s --user vscode -w %s %s sh -c %q' \
            "$RUNTIME" "$MANAGED_RUNTIME_ARGS" "${FTA_ENV[*]-}" "$_ft_cwt" "$MANAGED_NAME" "$_ft_inner")
  # herdr IDs agents by the HOST foreground process (here: the runtime);
  # HERDR_AGENT on that wrapper is herdr's documented sandbox hint — names
  # the agent for the panel, state reads the pane's screen (the agent's UI).
  [[ -n "$_ft_kind" ]] && _ft_cmd="HERDR_AGENT=$_ft_kind $_ft_cmd"
  _ft_pane=$(_ft_tab "$2")
  if [[ -z "$_ft_pane" ]]; then
    echo "Error: dev fta needs a running host herdr session for the tab (worktree is ready)." >&2
    exit 1
  fi
  herdr pane run "$_ft_pane" "$_ft_cmd"
  if [[ -n "$_ft_kind" ]]; then
    echo "ft: $FT_BRANCH — tab attached to the container, agent: $_ft_kind"
  else
    echo "ft: $FT_BRANCH — attached; no agent binary (claude/opencode/pi): plain shell. Install one + 'dev agent add KIND'."
  fi
}
