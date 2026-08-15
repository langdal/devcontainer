# shellcheck shell=bash
# lib/dev/container.sh — container identity and state: workspace name
# resolution, existence/running predicates, the mode-conflict guard, the
# management-command target lookup, and the reuse/attach half of the start
# flow. Sourced by dev; not executed directly.

# Container state predicates. Default to the current connection
# (RUNTIME_ARGS); pass an explicit connection in $2 to probe a different
# storage (e.g. DIND_RUNTIME_ARGS to look across the rootful connection on
# macOS+podman).
container_running() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME ${2-$RUNTIME_ARGS} ps -q -f name="^$1\$" | grep -q .
}
container_exists() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME ${2-$RUNTIME_ARGS} ps -aq -f name="^$1\$" | grep -q .
}
# Value of a label on container $1, or "<no value>" if the label is absent.
container_label() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null
}

# Destructive helper shared by the rebuild path and `dev reset` (its volume
# counterpart, remove_volume_if_exists, lives in volumes.sh). Takes an
# explicit connection-args string ($2) rather than defaulting — callers
# operating across storages (macOS+podman dind lives in the rootful
# connection while normal/maint live in the default rootless one) need to
# pass the right args per item, so an implicit global default would hide bugs.
remove_container_if_exists() {
  local name="$1" args="$2"
  if ! container_exists "$name" "$args"; then
    return 0
  fi
  echo "Removing container ${name}…" >&2
  # shellcheck disable=SC2086  # intentional word-splitting of $args
  if ! $RUNTIME $args rm -f "$name" >/dev/null 2>&1; then
    echo "Error: failed to remove container ${name}." >&2
    exit 1
  fi
}

# Resolve the workspace's four container names + the dind storage connection
# args. Shared by the management verbs (reset/down/status/fw/agent/dotfile,
# which need it standalone) and the start flow (cmd_start in lib/dev/up.sh).
# Must run after detect_runtime: the dind-storage split keys off $RUNTIME.
_resolve_workspace_names() {
  if [[ "$(uname -s)" == "Darwin" && "$RUNTIME" == "podman" ]]; then
    DIND_RUNTIME_ARGS="--connection=podman-machine-default-root"
  fi
  WORKSPACE_BASENAME="$(basename "$(pwd)")"
  NORMAL_NAME="dev-${WORKSPACE_BASENAME}"
  MAINT_NAME="dev-${WORKSPACE_BASENAME}-maint"
  DIND_NAME="dev-${WORKSPACE_BASENAME}-dind"
  PIND_NAME="dev-${WORKSPACE_BASENAME}-pind"
  _resolve_home_volume
}

# Pick this invocation's CONTAINER_NAME from the mode flags and refuse to
# start while a conflicting mode is running for the same workspace (four-way:
# normal / maintenance / dind / pind). Both would mount /workspace and produce
# surprising state. Called by cmd_start once the names are resolved.
resolve_container_name_and_guard() {
  if [[ "$DIND" == true ]]; then
    refuse_if_running "$NORMAL_NAME" "normal"
    refuse_if_running "$MAINT_NAME" "maintenance"
    refuse_if_running "$PIND_NAME" "pind" "$DIND_RUNTIME_ARGS"
    CONTAINER_NAME="$DIND_NAME"
  elif [[ "$PIND" == true ]]; then
    CONTAINER_NAME="$PIND_NAME"
    refuse_if_running "$NORMAL_NAME" "normal"
    refuse_if_running "$MAINT_NAME" "maintenance"
    refuse_if_running "$DIND_NAME" "dind" "$DIND_RUNTIME_ARGS"
  elif [[ "$MAINTENANCE" == true ]]; then
    refuse_if_running "$NORMAL_NAME" "normal"
    refuse_if_running "$DIND_NAME" "dind" "$DIND_RUNTIME_ARGS"
    refuse_if_running "$PIND_NAME" "pind" "$DIND_RUNTIME_ARGS"
    CONTAINER_NAME="$MAINT_NAME"
  else
    refuse_if_running "$MAINT_NAME" "maintenance"
    refuse_if_running "$DIND_NAME" "dind" "$DIND_RUNTIME_ARGS"
    refuse_if_running "$PIND_NAME" "pind" "$DIND_RUNTIME_ARGS"
    CONTAINER_NAME="$NORMAL_NAME"
  fi
}

# One arm of the conflict guard above: refuse while $1 is running. Takes an
# optional 3rd arg with extra runtime args so a non-dind invocation can still
# reach into the dind storage when checking for a running dind container.
refuse_if_running() {
  local other_name="$1" other_label="$2" extra_args="${3:-}"
  if container_running "$other_name" "$extra_args"; then
    echo "Error: ${other_label} container ${other_name} is running for this workspace." >&2
    # shellcheck disable=SC2086  # intentional word-splitting of $extra_args
    echo "       Stop it first:  $RUNTIME $extra_args stop ${other_name}" >&2
    exit 1
  fi
}

# Resolve which workspace container the management commands target. Sets:
#   MANAGED_TARGET       = "normal" | "dind" | "pind" | "maint" | ""   (empty = none running)
#   MANAGED_NAME         = the container name (when MANAGED_TARGET is non-empty)
#   MANAGED_RUNTIME_ARGS = runtime connection args for that container's storage
# Each name is looked up in its own storage because on macOS+podman the dind/pind
# containers live in the rootful connection while normal/maint live in the
# default rootless one — a single-storage probe would miss the dind/pind container.
resolve_managed_container() {
  MANAGED_TARGET=""
  MANAGED_NAME=""
  MANAGED_RUNTIME_ARGS=""
  if container_running "$NORMAL_NAME" ""; then
    MANAGED_TARGET="normal"; MANAGED_NAME="$NORMAL_NAME"; MANAGED_RUNTIME_ARGS=""; return
  fi
  if container_running "$DIND_NAME" "$DIND_RUNTIME_ARGS"; then
    MANAGED_TARGET="dind"; MANAGED_NAME="$DIND_NAME"; MANAGED_RUNTIME_ARGS="$DIND_RUNTIME_ARGS"; return
  fi
  if container_running "$PIND_NAME" "$DIND_RUNTIME_ARGS"; then
    MANAGED_TARGET="pind"; MANAGED_NAME="$PIND_NAME"; MANAGED_RUNTIME_ARGS="$DIND_RUNTIME_ARGS"; return
  fi
  # shellcheck disable=SC2034  # MANAGED_NAME/MANAGED_RUNTIME_ARGS are consumed by lib/dev/fw.sh
  if container_running "$MAINT_NAME" ""; then
    MANAGED_TARGET="maint"; MANAGED_NAME="$MAINT_NAME"; MANAGED_RUNTIME_ARGS=""; return
  fi
}

# Shared preamble for management commands that need a running firewall-capable
# container ('dev fw log', 'dev fw drops', 'dev fw on'). Exits with a clear
# error if nothing is running, or if the only running container is maintenance
# (which has no firewall).
require_workspace_firewall_container() {
  local op="$1"
  resolve_managed_container
  if [[ -z "$MANAGED_TARGET" ]]; then
    echo "Error: no dev container is running for this workspace (looked for ${NORMAL_NAME}, ${DIND_NAME}, ${PIND_NAME}, ${MAINT_NAME}). Start one with 'dev up', 'dev up --dind', 'dev up --pind', or 'dev up --maint' first." >&2
    exit 1
  fi
  if [[ "$MANAGED_TARGET" == "maint" ]]; then
    echo "Error: maintenance container ${MAINT_NAME} has no firewall — $op is meaningless in maintenance mode." >&2
    exit 1
  fi
}

# Reuse this workspace's existing container instead of creating a new one:
# start it if stopped, then exec into it. Never returns when it attaches;
# returns to start_container (lib/dev/lifecycle.sh) when there is nothing to
# reuse, or immediately under --dry-run (which only prints the create command).
# Reads EXPECT_KEEPID/TTY_FLAGS/CONTAINER_NAME/CMD_ARGS as set by its caller.
attach_existing_container() {
  [[ "$DRY_RUN" == false ]] || return 0

  # `dev shell` attaches only — it must never create a container.
  if [[ "${SHELL_ONLY:-false}" == true ]] && ! container_running "$CONTAINER_NAME"; then
    echo "Error: nothing running for this workspace — 'dev up' starts one." >&2
    exit 1
  fi
  # The image's USER is root because entrypoint.sh needs root to run
  # firewall-init.sh / dind-init.sh and only afterwards drops to vscode via
  # `gosu vscode`. `docker exec` bypasses the entrypoint and uses the image's
  # configured User, so without --user the second terminal would land as
  # root. Pin to vscode to match the first terminal.
  attach=false
  if container_exists "$CONTAINER_NAME"; then
    if [[ "$EXPECT_KEEPID" == true ]] \
       && [[ "$(container_label "$CONTAINER_NAME" dev.keepid)" != "true" ]]; then
      # The existing container predates --userns=keep-id (older dev version,
      # or created before this label existed). Reusing it via `exec` would
      # leave vscode's uid mapped so it cannot write /mise or $HOME under
      # rootless podman -- the "java/JAVA_HOME missing after an upgrade" trap.
      # Recreate it with the correct mapping instead of attaching.
      echo "Recreating $CONTAINER_NAME: it was created without --userns=keep-id" >&2
      echo "  (older dev version or different runtime). Reusing it would leave vscode" >&2
      echo "  unable to write /mise and \$HOME under rootless podman." >&2
      # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
      $RUNTIME $RUNTIME_ARGS rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    elif container_running "$CONTAINER_NAME"; then
      echo "Attaching to running container $CONTAINER_NAME..."
      attach=true
    else
      echo "Starting stopped container $CONTAINER_NAME..."
      # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
      $RUNTIME $RUNTIME_ARGS start "$CONTAINER_NAME"
      attach=true
    fi
  fi
  if [[ "$attach" == true ]]; then
    # `exec` bypasses the entrypoint, so the attached process inherits
    # neither the proxy env nor the nested-engine env that the container's
    # original process tree got (and /etc/profile.d only covers login
    # shells — a plain `dev -- npm install` is not one). Without this a
    # command in an attached session connects directly, the kernel silently
    # drops the packets, and the tool appears to hang. Mirror the
    # entrypoint's exports here; values must stay in sync with entrypoint.sh.
    EXEC_ENV=()
    if [[ "$CONTAINER_NAME" != "$MAINT_NAME" ]]; then
      # shellcheck disable=SC2054  # commas are part of the NO_PROXY value, not element separators
      EXEC_ENV+=(-e HTTPS_PROXY=http://127.0.0.1:8888
                 -e HTTP_PROXY=http://127.0.0.1:8888
                 -e NO_PROXY=localhost,127.0.0.1,host.docker.internal)
    fi
    if [[ "$CONTAINER_NAME" == "$DIND_NAME" ]]; then
      EXEC_ENV+=(-e DOCKER_HOST=unix:///home/vscode/.dind-run/docker.sock
                 -e XDG_RUNTIME_DIR=/home/vscode/.dind-run)
    elif [[ "$CONTAINER_NAME" == "$PIND_NAME" ]]; then
      EXEC_ENV+=(-e DOCKER_HOST=unix:///home/vscode/.pind-run/podman.sock
                 -e XDG_RUNTIME_DIR=/home/vscode/.pind-run)
    fi
    # ${arr[@]+...} guards the empty-array case (maintenance mode) against
    # set -u on bash 3.2 (macOS).
    if [[ ${#CMD_ARGS[@]} -gt 0 ]]; then
      # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
      exec $RUNTIME $RUNTIME_ARGS exec --user vscode ${EXEC_ENV[@]+"${EXEC_ENV[@]}"} "${TTY_FLAGS[@]}" "$CONTAINER_NAME" "${CMD_ARGS[@]}"
    else
      # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
      exec $RUNTIME $RUNTIME_ARGS exec --user vscode ${EXEC_ENV[@]+"${EXEC_ENV[@]}"} "${TTY_FLAGS[@]}" "$CONTAINER_NAME" zsh
    fi
  fi
}
