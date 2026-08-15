# shellcheck shell=bash
# lib/dev/lifecycle.sh — start_container: the terminal step of the start flow.
# Decides between reusing an existing container (container.sh's
# attach_existing_container) and creating a fresh one, assembles the runtime's
# `run` command, and either execs it or prints it under --dry-run.
# Sourced by dev; not executed directly.

# Build and run/attach the workspace container. Terminal step of the default
# start path; either exec's into the container or, under --dry-run, prints the
# command. Reads the start-path globals assembled by cmd_start (RUNTIME,
# RUNTIME_ARGS, CONTAINER_NAME, IMAGE_TAG, DIND, MAINTENANCE, DEFAULT_PORTS,
# EXTRA_PORTS, HOST_PORTS, CMD_ARGS, FW_DISABLED_START, DRY_RUN, GITHUB_TOKEN, …).
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

  # Reuse an existing container when there is one (never returns if it
  # attaches); no-op under --dry-run.
  attach_existing_container

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
    # shellcheck disable=SC2034  # consumed by append_volume_mounts in lib/dev/volumes.sh
    KEEPID_MIGRATE=true
  fi
  # Record how the container was created so a later invocation's reuse guard
  # (see above) can detect a mapping mismatch and recreate instead of attaching.
  DOCKER_CMD+=(--label "dev.keepid=$EXPECT_KEEPID")

  # Workspace bind mount, named volumes, approved-allowlist mount, and the
  # one-time keep-id ownership migration (lib/dev/volumes.sh).
  append_volume_mounts

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
    append_nested_engine_volume
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
