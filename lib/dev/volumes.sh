# shellcheck shell=bash
# lib/dev/volumes.sh — named-volume concerns: home-volume naming, the volume
# mounts of the start flow, the one-time rootless-podman ownership migration,
# and `dev reset` (which removes this workspace's containers and prompts per
# volume). Sourced by dev; not executed directly.

# Resolve the home volume name. Per-workspace by default so one project's
# SSH keys / git creds / shell history are not exposed to the agent in
# another project's container. DEV_SHARED_HOME=1 keeps the legacy single
# volume. mise (tool cache) and dind (image cache) stay shared regardless.
# Basename only (matches the dev-<dir> container-name convention and its
# documented basename-collision caveat).
_resolve_home_volume() {
  if [[ "${DEV_SHARED_HOME:-}" == "1" ]]; then
    HOME_VOLUME="devcontainer-home"
  else
    HOME_VOLUME="devcontainer-home-${WORKSPACE_BASENAME}"
  fi
}

# Named volumes populated before --userns=keep-id was added are owned
# on-disk by the old mapping's subuid, not the host user, so vscode (now
# mapped 1:1 to the host user) can no longer write into them. Re-chown once;
# checking the volume's raw owner against $HOST_UID makes this a no-op on
# every run after the first. `podman unshare` runs the chown inside the
# same default (non-keep-id) mapping the volume was written under, where
# container id 0 is the invoking host user — chowning to 0:0 there writes
# the real host UID/GID onto the raw files.
migrate_volume_for_keepid() {
  local vol="$1" mountpoint raw_owner
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  mountpoint=$($RUNTIME $RUNTIME_ARGS volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null) || return 0
  [[ -d "$mountpoint" ]] || return 0
  raw_owner=$(stat -c '%u' "$mountpoint" 2>/dev/null) || return 0
  [[ "$raw_owner" == "$HOST_UID" ]] && return 0
  echo "Migrating $vol ownership for --userns=keep-id (one-time)..." >&2
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS unshare chown -R 0:0 "$mountpoint"
}

# Append the workspace bind mount and the named volumes to DOCKER_CMD, and run
# the one-time keep-id ownership migration for the volumes about to be mounted.
# Called by start_container (lib/dev/lifecycle.sh) while it assembles the run
# command; reads DOCKER_CMD/KEEPID_MIGRATE/MOUNT_PROJECT_ALLOWLIST/DRY_RUN.
append_volume_mounts() {
  DOCKER_CMD+=(-v "$(pwd):/workspace")
  DOCKER_CMD+=(-v devcontainer-mise:/mise)
  DOCKER_CMD+=(-v "$HOME_VOLUME":/home/vscode)

  # Approved project allowlist: mount the state dir read-only. firewall-init.sh
  # reads allowlist.approved from here, never from the agent-writable workspace.
  # The env signal lets entrypoint.sh tell "mise install failed because a tool's
  # download host was blocked by an unapproved allowlist" apart from other
  # failures, and point the user at the approval step instead of leaving the
  # tool silently missing from PATH.
  if [[ "$MOUNT_PROJECT_ALLOWLIST" == true ]]; then
    DOCKER_CMD+=(-v "$STATE_DIR:/etc/devcontainer/project:ro")
    DOCKER_CMD+=(-e DEVCONTAINER_PROJECT_ALLOWLIST=applied)
  fi

  # `if` rather than the original `[[ … ]] && migrate…` one-liner: as the last
  # statement of a function that idiom would return 1 whenever DIND is false
  # and abort the caller under `set -e`. Same effect, no trailing-status trap.
  if [[ "$KEEPID_MIGRATE" == true && "$DRY_RUN" == false ]]; then
    migrate_volume_for_keepid devcontainer-mise
    migrate_volume_for_keepid "$HOME_VOLUME"
    if [[ "$DIND" == true ]]; then
      migrate_volume_for_keepid devcontainer-dind
    fi
  fi
}

# Append the nested engine's image-cache volume (dind and pind keep their
# stores in different paths, and only one of the two is ever mounted).
append_nested_engine_volume() {
  if [[ "$DIND" == true ]]; then
    DOCKER_CMD+=(-v devcontainer-dind:/home/vscode/.local/share/docker)
  else
    DOCKER_CMD+=(-v devcontainer-pind:/home/vscode/.local/share/containers)
  fi
}

# Destructive helper shared by the rebuild path and `dev reset` (its container
# counterpart, remove_container_if_exists, lives in container.sh). Takes an
# explicit connection-args string ($2) rather than defaulting — callers
# operating across storages (macOS+podman dind lives in the rootful
# connection while normal/maint live in the default rootless one) need to
# pass the right args per item, so an implicit global default would hide bugs.
remove_volume_if_exists() {
  local name="$1" args="$2"
  # shellcheck disable=SC2086  # intentional word-splitting of $args
  if ! $RUNTIME $args volume inspect "$name" >/dev/null 2>&1; then
    return 0
  fi
  echo "Removing volume ${name}…" >&2
  # shellcheck disable=SC2086  # intentional word-splitting of $args
  if ! $RUNTIME $args volume rm "$name" >/dev/null 2>&1; then
    echo "Error: failed to remove volume ${name}." >&2
    exit 1
  fi
}

# --reset: remove this workspace's container(s) and prompt per existing
# named volume. The mise and dind volumes are global (shared across all
# dev workspaces); the home volume is per-workspace by default
# (devcontainer-home-<dir>, shared only under DEV_SHARED_HOME=1) — each
# prompt makes the blast radius explicit either way. Containers are
# removed unconditionally — that's the point of --reset; the volumes
# carry user state (home dir, mise tool cache, dind image cache) and
# deserve a decision each. Honours DEV_ASSUME_YES for non-interactive
# runs.
reset_workspace() {
  local -a containers=() containers_args=()
  if container_exists "$NORMAL_NAME" ""; then
    containers+=("$NORMAL_NAME"); containers_args+=("")
  fi
  if container_exists "$MAINT_NAME" ""; then
    containers+=("$MAINT_NAME"); containers_args+=("")
  fi
  if container_exists "$DIND_NAME" "$DIND_RUNTIME_ARGS"; then
    containers+=("$DIND_NAME"); containers_args+=("$DIND_RUNTIME_ARGS")
  fi
  if container_exists "$PIND_NAME" "$DIND_RUNTIME_ARGS"; then
    containers+=("$PIND_NAME"); containers_args+=("$DIND_RUNTIME_ARGS")
  fi

  # mise/home volumes live in the default (rootless) storage for normal/maint.
  # On macOS+podman a --dind/--pind run mounts them from the *rootful*
  # connection instead, so a separate copy of both exists there too; reset
  # must clean both or a dind/pind home volume (with injected creds) survives.
  # DIND_RUNTIME_ARGS is empty on every other host, so the extra probe is
  # skipped there and the volume is never listed twice.
  local -a volumes=() volumes_args=()
  local v
  for v in devcontainer-mise "$HOME_VOLUME"; do
    if $RUNTIME volume inspect "$v" >/dev/null 2>&1; then
      volumes+=("$v"); volumes_args+=("")
    fi
  done
  if [[ -n "$DIND_RUNTIME_ARGS" ]]; then
    for v in devcontainer-mise "$HOME_VOLUME"; do
      # shellcheck disable=SC2086  # intentional word-splitting of DIND_RUNTIME_ARGS
      if $RUNTIME $DIND_RUNTIME_ARGS volume inspect "$v" >/dev/null 2>&1; then
        volumes+=("$v"); volumes_args+=("$DIND_RUNTIME_ARGS")
      fi
    done
  fi
  # shellcheck disable=SC2086  # intentional word-splitting of DIND_RUNTIME_ARGS
  if $RUNTIME $DIND_RUNTIME_ARGS volume inspect devcontainer-dind >/dev/null 2>&1; then
    volumes+=("devcontainer-dind"); volumes_args+=("$DIND_RUNTIME_ARGS")
  fi
  # shellcheck disable=SC2086  # intentional word-splitting of DIND_RUNTIME_ARGS
  if $RUNTIME $DIND_RUNTIME_ARGS volume inspect devcontainer-pind >/dev/null 2>&1; then
    volumes+=("devcontainer-pind"); volumes_args+=("$DIND_RUNTIME_ARGS")
  fi

  if [[ ${#containers[@]} -eq 0 && ${#volumes[@]} -eq 0 ]]; then
    echo "Nothing to reset for this workspace (no dev containers or named volumes found)."
    return 0
  fi

  local i
  for i in "${!containers[@]}"; do
    remove_container_if_exists "${containers[$i]}" "${containers_args[$i]}"
  done

  local assume_yes="${DEV_ASSUME_YES:-0}"
  local interactive=true
  [[ -t 0 ]] || interactive=false
  local name args reply label
  for i in "${!volumes[@]}"; do
    name="${volumes[$i]}"; args="${volumes_args[$i]}"
    # On macOS+podman the same volume name can exist in both the rootless and
    # rootful connections; label the rootful one so the two prompts are
    # distinguishable (args is empty for rootless / on every non-macOS host).
    label="$name"
    [[ -n "$args" ]] && label="$name [rootful/dind-pind storage]"
    if [[ "$assume_yes" == "1" ]]; then
      reply=y
      echo "DEV_ASSUME_YES set — removing volume ${label}." >&2
    elif [[ "$interactive" != true ]]; then
      echo "Skipping volume ${label} (non-interactive; set DEV_ASSUME_YES=1 to remove)." >&2
      continue
    else
      read -r -p "Remove volume ${label}? [y/N] " reply
    fi
    case "$reply" in
      y|Y|yes|YES)
        remove_volume_if_exists "$name" "$args"
        ;;
      *)
        echo "Kept volume ${label}." >&2
        ;;
    esac
  done
}
