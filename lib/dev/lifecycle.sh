# shellcheck shell=bash
# lib/dev/lifecycle.sh — container/volume helpers, reset, managed-container
# resolution, and rootless-podman volume ownership migration.
# Sourced by dev; not executed directly.

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

# Destructive helpers shared by the rebuild path and --reset. Both take an
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

# Resolve which workspace container the management commands target. Sets:
#   MANAGED_TARGET       = "normal" | "dind" | "pind" | "maint" | ""   (empty = none running)
#   MANAGED_NAME         = the container name (when MANAGED_TARGET is non-empty)
#   MANAGED_RUNTIME_ARGS = runtime connection args for that container's storage
# Each name is looked up in its own storage because on macOS+podman the dind/pind
# containers live in the rootful connection while normal/maint live in the
# default rootless one — a single-storage probe would miss the dind/pind container.
# shellcheck disable=SC2034  # MANAGED_NAME/MANAGED_RUNTIME_ARGS consumed by dev's management-command dispatch blocks
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
  if container_running "$MAINT_NAME" ""; then
    MANAGED_TARGET="maint"; MANAGED_NAME="$MAINT_NAME"; MANAGED_RUNTIME_ARGS=""; return
  fi
}

# Shared preamble for management commands that need a running firewall-capable
# container (--monitor, --monitor-fw, --disable-firewall, --enable-firewall).
# Exits with a clear error if nothing is running, or if the only running
# container is maintenance (which has no firewall).
require_workspace_firewall_container() {
  local op="$1"
  resolve_managed_container
  if [[ -z "$MANAGED_TARGET" ]]; then
    echo "Error: no dev container is running for this workspace (looked for ${NORMAL_NAME}, ${DIND_NAME}, ${PIND_NAME}, ${MAINT_NAME}). Start one with 'dev', 'dev --dind', 'dev --pind', or 'dev --maintenance' first." >&2
    exit 1
  fi
  if [[ "$MANAGED_TARGET" == "maint" ]]; then
    echo "Error: maintenance container ${MAINT_NAME} has no firewall — $op is meaningless in maintenance mode." >&2
    exit 1
  fi
}

# Three-way conflict guard: normal / maintenance / dind. Each pair refuses
# while the other is running for the same workspace; both would mount
# /workspace and produce surprising state. Takes an optional 3rd arg with
# extra runtime args so a non-dind invocation can still reach into the
# dind storage when checking for a running dind container.
refuse_if_running() {
  local other_name="$1" other_label="$2" extra_args="${3:-}"
  if container_running "$other_name" "$extra_args"; then
    echo "Error: ${other_label} container ${other_name} is running for this workspace." >&2
    # shellcheck disable=SC2086  # intentional word-splitting of $extra_args
    echo "       Stop it first:  $RUNTIME $extra_args stop ${other_name}" >&2
    exit 1
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

# Build and run/attach the workspace container. Terminal step of the default
# start path; either exec's into the container or, under --dry-run, prints the
# command. Reads the start-path globals assembled by dev (RUNTIME, RUNTIME_ARGS,
# CONTAINER_NAME, IMAGE_TAG, DIND, MAINTENANCE, DEFAULT_PORTS, EXTRA_PORTS,
# HOST_PORTS, CMD_ARGS, FW_DISABLED_START, DRY_RUN, GITHUB_TOKEN, …).
start_container() {
  # Allocate a TTY only when stdin AND stdout are real terminals; otherwise
  # docker rejects -it with "the input device is not a TTY" and scripted
  # invocations (CI, test runners, piped usage) fail.
  TTY_FLAGS=(-i)
  if [[ -t 0 && -t 1 ]]; then
    TTY_FLAGS=(-it)
  fi

  # Whether this invocation would create the container with --userns=keep-id
  # (rootless podman only; see the create path below). Computed up front so the
  # reuse guard and the create path agree, and recorded as the dev.keepid label
  # so a later run can tell how an existing container was created.
  EXPECT_KEEPID=false
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if $RUNTIME $RUNTIME_ARGS --version 2>/dev/null | grep -qi podman && runtime_is_rootless; then
    EXPECT_KEEPID=true
  fi

  if [[ "$DRY_RUN" == false ]]; then
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
  fi

  # shellcheck disable=SC2206  # intentional word-splitting of RUNTIME_ARGS into array
  DOCKER_CMD=($RUNTIME $RUNTIME_ARGS run "${TTY_FLAGS[@]}" --rm --name "$CONTAINER_NAME")

  # Capability needed by entrypoint to configure iptables (used in normal mode;
  # harmless when unused in maintenance mode).
  DOCKER_CMD+=(--cap-add=NET_ADMIN)

  # Rootless podman's default user-namespace mapping puts container root (uid 0)
  # at the invoking host user and shifts every other container id — including
  # vscode's baked uid/gid — into the subuid/subgid range. That breaks the
  # "vscode's baked uid == host uid" assumption from the UID/GID build args
  # above: the bind-mounted /workspace (owned by the real host user) shows up
  # as root-owned to vscode, who can't write to it, and named-volume content
  # written by vscode ends up owned by a subuid instead of the host user.
  # --userns=keep-id fixes this by mapping the invoking host user 1:1 onto the
  # matching container id instead, so vscode's baked uid lines up with the real
  # host uid again. Rootful podman and Docker don't remap ids at all, so the
  # baked uid already matches there — this only applies to rootless podman.
  KEEPID_MIGRATE=false
  if [[ "$EXPECT_KEEPID" == true ]]; then
    DOCKER_CMD+=(--userns=keep-id)
    KEEPID_MIGRATE=true
  fi
  # Record how the container was created so a later invocation's reuse guard
  # (see above) can detect a mapping mismatch and recreate instead of attaching.
  DOCKER_CMD+=(--label "dev.keepid=$EXPECT_KEEPID")

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

  if [[ "$KEEPID_MIGRATE" == true && "$DRY_RUN" == false ]]; then
    migrate_volume_for_keepid devcontainer-mise
    migrate_volume_for_keepid "$HOME_VOLUME"
    [[ "$DIND" == true ]] && migrate_volume_for_keepid devcontainer-dind
  fi

  # DinD-specific runtime knobs.
  # SYS_ADMIN is required for rootless dockerd's newuidmap to set up
  # multi-range user-namespace mappings. The kernel checks CAP_SYS_ADMIN
  # in the writer's userns chain when writing /proc/<pid>/uid_map with
  # more than one range; default docker drops this cap from the container's
  # bounding set. This is far less than --privileged: vscode is not in
  # sudoers, so the container's root caps are only reachable via setuid
  # binaries (notably newuidmap), which is exactly the path the rootlesskit
  # stack uses anyway. Without SYS_ADMIN, dockerd-rootless fails at start
  # with "newuidmap: write to uid_map failed: Operation not permitted".
  if [[ "$DIND" == true || "$PIND" == true ]]; then
    DOCKER_CMD+=(--device=/dev/fuse)
    DOCKER_CMD+=(--device=/dev/net/tun)   # slirp4netns needs tun for nested-container networking
    DOCKER_CMD+=(--cap-add=SYS_ADMIN)
    DOCKER_CMD+=(--security-opt apparmor=unconfined)
    DOCKER_CMD+=(--security-opt seccomp=unconfined)
    # systempaths=unconfined undoes Docker's default masking of /proc paths
    # (e.g. /proc/sys/kernel/*). The nested runc inside dockerd-rootless needs
    # to (re-)mount procfs in the spawned container; the default mask makes
    # that fail with "mount proc:/proc ... operation not permitted".
    DOCKER_CMD+=(--security-opt systempaths=unconfined)
    # label=disable turns off SELinux confinement for the container. On
    # SELinux hosts (Fedora — including the rootful podman-machine VM on
    # macOS), the default container_t label blocks the nested runc from
    # mounting a fresh procfs in the spawned container, surfacing as
    # `mount proc:/proc ... permission denied`. systempaths=unconfined
    # alone is not enough; SELinux denies the mount even after the proc
    # masks are removed. Silently ignored on hosts without SELinux.
    DOCKER_CMD+=(--security-opt label=disable)
    if [[ "$DIND" == true ]]; then
      DOCKER_CMD+=(-v devcontainer-dind:/home/vscode/.local/share/docker)
    else
      DOCKER_CMD+=(-v devcontainer-pind:/home/vscode/.local/share/containers)
    fi
  fi

  # Skip default ports if another dev-* container is already running (they'd collide).
  # Explicit --port requests are left alone so conflicts there still surface.
  if [[ "$DEFAULT_PORTS" == true ]]; then
    # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
    OTHER_DEV=$($RUNTIME $RUNTIME_ARGS ps --format '{{.Names}}' | grep '^dev-' | grep -vx "$CONTAINER_NAME" || true)
    if [[ -n "$OTHER_DEV" ]]; then
      echo "Note: another dev container is running ($(echo "$OTHER_DEV" | paste -sd, -)); skipping default port forwards." >&2
      DEFAULT_PORTS=false
    fi
  fi

  if [[ "$DEFAULT_PORTS" == true ]]; then
    DOCKER_CMD+=(-p 5173:5173 -p 5174:5174 -p 8080:8080 -p 2345:2345 -p 3000:3000)
  fi

  if [[ ${#EXTRA_PORTS[@]} -gt 0 ]]; then
    for port in "${EXTRA_PORTS[@]}"; do
      DOCKER_CMD+=(-p "$port:$port")
    done
  fi

  # --host-port: map host.docker.internal and pass the port list to the
  # entrypoint so firewall-init.sh can add a per-port iptables ACCEPT for
  # the host gateway. The mapping uses Docker's host-gateway sentinel,
  # resolved by the runtime to the bridge IP (Linux) or the Docker Desktop
  # host (macOS).
  if [[ ${#HOST_PORTS[@]} -gt 0 ]]; then
    DOCKER_CMD+=(--add-host=host.docker.internal:host-gateway)
    _hp_csv="$(IFS=,; echo "${HOST_PORTS[*]}")"
    DOCKER_CMD+=(-e "DEVCONTAINER_HOST_PORTS=$_hp_csv")
  fi

  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    DOCKER_CMD+=(-e GITHUB_TOKEN)
  fi

  if [[ -n "${DEV_GIT_NAME:-}" ]]; then
    DOCKER_CMD+=(-e "DEV_GIT_NAME=$DEV_GIT_NAME")
  fi
  if [[ -n "${DEV_GIT_EMAIL:-}" ]]; then
    DOCKER_CMD+=(-e "DEV_GIT_EMAIL=$DEV_GIT_EMAIL")
  fi

  # Escape hatch for hosts/test runs that need to inject extra `docker run`
  # args (e.g. --dns=8.8.8.8 on a host with broken IPv6 resolvers, or extra
  # --tmpfs / --label arguments for a CI environment). Word-split with
  # read -ra so callers can pass multiple args in a single env var.
  if [[ -n ${DEV_EXTRA_RUN_ARGS:-} ]]; then
    read -ra _DEV_EXTRA <<< "$DEV_EXTRA_RUN_ARGS"
    DOCKER_CMD+=("${_DEV_EXTRA[@]}")
  fi

  # Maintenance mode: tell entrypoint.sh to skip firewall init and grant sudo.
  # Also passes through /dev/kvm when present on the host, so developers can
  # exercise scripts/test/run-in-vm.sh (KVM-accelerated QEMU) from inside the
  # sandbox. Gracefully skipped on macOS hosts (no /dev/kvm).
  if [[ "$MAINTENANCE" == true ]]; then
    DOCKER_CMD+=(-e DEVCONTAINER_MAINTENANCE=1)
    if [[ -e /dev/kvm ]]; then
      DOCKER_CMD+=(--device=/dev/kvm)
    fi
  fi

  # DinD mode: tell entrypoint.sh to start dockerd-rootless.
  if [[ "$DIND" == true ]]; then
    DOCKER_CMD+=(-e DEVCONTAINER_DIND=1)
  fi

  # PinD mode: tell entrypoint.sh to start the rootless podman system service.
  if [[ "$PIND" == true ]]; then
    DOCKER_CMD+=(-e DEVCONTAINER_PIND=1)
  fi

  # --disable-firewall with no running container: bring the fresh container up
  # with the firewall already torn down (entrypoint still runs firewall-init.sh,
  # then firewall-disable.sh).
  if [[ "$FW_DISABLED_START" == true ]]; then
    DOCKER_CMD+=(-e DEVCONTAINER_FW_DISABLED=1)
  fi

  DOCKER_CMD+=("$IMAGE_TAG")

  if [[ ${#CMD_ARGS[@]} -gt 0 ]]; then
    DOCKER_CMD+=("${CMD_ARGS[@]}")
  else
    DOCKER_CMD+=(zsh)
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "${DOCKER_CMD[*]}"
  else
    exec "${DOCKER_CMD[@]}"
  fi
}
