# shellcheck shell=bash
# lib/dev/up.sh — the shared start flow behind `dev up` / `dev exec` /
# `dev shell`: flag parsing, mode-conflict guard, host preflights, workspace
# name resolution, image build check, and the container start itself.
# Sourced by dev; not executed directly.

# cmd_up [options...]: the `dev up` verb. Translates this verb's own spellings
# (--maint, --open) into the shared start flow's and rejects a command payload,
# then hands off to cmd_start.
cmd_up() {
  UP_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --maint) UP_ARGS+=(--maintenance); shift ;;
      --open|--closed) UP_ARGS+=("$1"); shift ;;
      --)
        echo "Error: 'dev up' does not take a command; use 'dev exec' -- CMD [ARGS...]." >&2
        exit 2 ;;
      *) UP_ARGS+=("$1"); shift ;;
    esac
  done
  cmd_start ${UP_ARGS[@]+"${UP_ARGS[@]}"}
  exit $?
}

# cmd_exec [options...] -- CMD [ARGS...]: the `dev exec` verb. Same translation
# as cmd_up, but `--` is mandatory: without a command this would silently become
# an interactive attach.
cmd_exec() {
  EXEC_ARGS=(); _saw_ddash=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --maint) EXEC_ARGS+=(--maintenance); shift ;;
      --open|--closed) EXEC_ARGS+=("$1"); shift ;;
      --)      _saw_ddash=true
               # $# counts the `--` itself, so 1 means nothing follows it.
               # Without this guard `dev exec --` would cold-start and attach
               # an interactive zsh, contradicting `-- CMD [ARGS...]`.
               if [[ $# -eq 1 ]]; then
                 echo "Error: 'dev exec' requires a command after '--'." >&2
                 exit 2
               fi
               EXEC_ARGS+=("$@"); break ;;
      *)       EXEC_ARGS+=("$1"); shift ;;
    esac
  done
  if [[ "$_saw_ddash" != true ]]; then
    echo "Error: 'dev exec' requires '-- CMD [ARGS...]'." >&2
    exit 2
  fi
  unset _saw_ddash
  cmd_start ${EXEC_ARGS[@]+"${EXEC_ARGS[@]}"}
  exit $?
}


# cmd_start [start-options...] [-- CMD ...]
# The shared flag engine for `dev up`/`dev exec`/`dev shell`: those verb arms
# in `dev` translate their own spellings (--maint, --open, --) and call this
# with the remaining arguments. There is no other route in — bare `dev` and
# flag-first invocations are rejected by the router in `dev`.
# Assignments here are deliberately global (consumed by start_container and
# the lib/dev/* helpers); do not make them local.
cmd_start() {
  # Precedence: explicit --open/--closed (below) > DEV_EGRESS > default open.
  case "${DEV_EGRESS:-open}" in
    open|closed) EGRESS_MODE="${DEV_EGRESS:-open}" ;;
    *) echo "Error: DEV_EGRESS must be 'open' or 'closed', got '$DEV_EGRESS'" >&2; exit 2 ;;
  esac

  _EGRESS_MODE_EXPLICIT=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --open)
        EGRESS_MODE=open
        _EGRESS_MODE_EXPLICIT=true
        shift
        ;;
      --closed)
        # shellcheck disable=SC2034  # consumed by start_container (lib/dev/lifecycle.sh)
        EGRESS_MODE=closed
        _EGRESS_MODE_EXPLICIT=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --build)
        FORCE_BUILD=true
        shift
        ;;
      --port)
        if [[ -z ${2:-} ]]; then
          echo "Error: --port requires a port number" >&2
          exit 1
        fi
        EXTRA_PORTS+=("$2")
        shift 2
        ;;
      --host-port)
        if [[ -z ${2:-} ]]; then
          echo "Error: --host-port requires a port number" >&2
          exit 1
        fi
        if ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "Error: --host-port expects a numeric port, got '$2'" >&2
          exit 1
        fi
        HOST_PORTS+=("$2")
        shift 2
        ;;
      --default-ports)
        # shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
        DEFAULT_PORTS=true
        shift
        ;;
      --maintenance)
        MAINTENANCE=true
        shift
        ;;
      --dind)
        DIND=true
        shift
        ;;
      --pind)
        PIND=true
        shift
        ;;
      --help)
        # Position-independent: the router only matches --help as the very
        # first token, so e.g. `dev up --dry-run --help` reaches here instead.
        usage
        exit 0
        ;;
      --version)
        # Position-independent counterpart to the router's first-token --version.
        echo "dev $(resolve_dev_version)"
        exit 0
        ;;
      --)
        shift
        # shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
        CMD_ARGS=("$@")
        break
        ;;
      *)
        echo "Error: Unknown option: $1" >&2
        echo "Run 'dev --help' for usage information" >&2
        exit 1
        ;;
    esac
  done

  # Restored mode-conflict guard: --dind, --pind, and --maintenance are
  # mutually exclusive (four-way: normal / maintenance / dind / pind). Must
  # run before the blocking checks below so this error wins over the
  # (also-fatal) --dind subid-grant check when both flags are given
  # together.
  if [[ "$DIND" == true && "$MAINTENANCE" == true ]]; then
    echo "Error: --dind and --maintenance are mutually exclusive." >&2
    exit 1
  fi
  if [[ "$PIND" == true && "$MAINTENANCE" == true ]]; then
    echo "Error: --pind and --maintenance are mutually exclusive." >&2
    exit 1
  fi
  if [[ "$PIND" == true && "$DIND" == true ]]; then
    echo "Error: --pind and --dind are mutually exclusive." >&2
    exit 1
  fi
  # Maintenance mode never runs the firewall at all, so egress mode is
  # irrelevant there — warn (not error) when the caller explicitly asked for
  # one, and continue with maintenance's usual no-firewall behavior.
  if [[ "$MAINTENANCE" == true && "${_EGRESS_MODE_EXPLICIT:-false}" == true ]]; then
    echo "Warning: egress mode is ignored in maintenance mode (no firewall runs)." >&2
  fi

  # block-if-nested checks apply only to --dind/--pind.
  # shellcheck disable=SC2034  # consumed by checks_select in lib/dev/checks.sh
  NESTED=false
  # shellcheck disable=SC2034  # consumed by checks_select in lib/dev/checks.sh
  [[ "$DIND" == true || "$PIND" == true ]] && NESTED=true
  run_blocking_checks 0

  detect_runtime
  # The start path creates or attaches a container: it needs a live engine.
  # --dry-run only prints the command, so it does not.
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  NEEDS_ENGINE=true
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  [[ "$DRY_RUN" == true ]] && NEEDS_ENGINE=false
  ensure_runtime_ready

  # Resolve the dind storage location once detect_runtime has settled on a
  # binary. macOS+podman is the only host where dind has to leave the default
  # (rootless) connection; everywhere else the dind container lives in the
  # same context as normal/maint.
  if [[ "$(uname -s)" == "Darwin" && "$RUNTIME" == "podman" ]]; then
    DIND_RUNTIME_ARGS="--connection=podman-machine-default-root"
  fi

  # Under a ROOTLESS runtime the dind container's user namespace only spans
  # as many IDs as the host grants this user in /etc/subuid + /etc/subgid
  # (typically 65536, so container ids 0-65536). rootless dockerd inside the
  # container must map the image's baked vscode subuid range — container ids
  # 100000-165535 — so the namespace has to span at least 165536 ids or
  # rootlesskit dies ~15s in with "newuidmap: write to uid_map failed:
  # Operation not permitted" (the kernel cannot map the extent down to a
  # real id). Rootful runtimes are unaffected: the container sits in the
  # initial user namespace where every id exists. Check the grant up front
  # and refuse with a remediation instead.
  #
  # The 165536 floor is the image contract: Dockerfile writes
  # "vscode:100000:65536" into the image's /etc/subuid, and 100000+65536
  # container ids must exist for rootless dockerd's two-line map.
  # shellcheck disable=SC2034  # consumed by _chk_subid_grant() in lib/dev/checks-catalog.sh
  DIND_MIN_SUBIDS=165535 # ids beyond id 0; namespace size = subids + 1
  run_blocking_checks 1

  # Host identity. Feeds resolve_image_ids (lib/dev/ids.sh), which decides the
  # uid/gid the image is built for and the --userns=keep-id form, and
  # migrate_volume_for_keepid, which compares a volume's on-disk owner against
  # the real host user.
  # shellcheck disable=SC2034  # consumed by resolve_image_ids in lib/dev/ids.sh and migrate_volume_for_keepid in lib/dev/volumes.sh
  HOST_UID=$(id -u)
  # shellcheck disable=SC2034  # consumed by resolve_image_ids in lib/dev/ids.sh
  HOST_GID=$(id -g)

  # Read the host's git identity so a fresh per-workspace home volume gets a
  # usable identity without manual setup. Empty when the host has none; the
  # entrypoint only seeds these when the container has no identity yet.
  # shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
  DEV_GIT_NAME="$(git config --get user.name 2>/dev/null || true)"
  # shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
  DEV_GIT_EMAIL="$(git config --get user.email 2>/dev/null || true)"

  # In --dind mode, use the :dind image variant. RUNTIME_ARGS routes all
  # subsequent runtime commands at the dind storage (see DIND_RUNTIME_ARGS).
  # --pind reuses the same DIND_RUNTIME_ARGS/RUNTIME_ARGS routing below (its
  # own rootless-podman-in-podman path needs the same macOS rootful-connection
  # override).
  if [[ "$DIND" == true ]]; then
    IMAGE_TAG="${IMAGE_NAME}:dind"
    BUILD_TARGET="dind"
    RUNTIME_ARGS="$DIND_RUNTIME_ARGS"
  else
    IMAGE_TAG="$IMAGE_NAME"
    BUILD_TARGET="base"
  fi
  if [[ "$PIND" == true ]]; then
    IMAGE_TAG="${IMAGE_NAME}:pind"
    BUILD_TARGET="pind"
    RUNTIME_ARGS="$DIND_RUNTIME_ARGS"
  fi

  # Workspace container names + home volume, then this invocation's
  # CONTAINER_NAME and the four-way mode-conflict guard (lib/dev/container.sh).
  # _resolve_workspace_names re-applies the macOS+podman dind-storage override
  # set above; the assignment is idempotent.
  _resolve_workspace_names
  resolve_container_name_and_guard

  ensure_state_dir
  resolve_github_token
  approve_project_allowlist

  # Compare host UID/GID and dev-script version to the labels on $IMAGE_TAG.
  # UID mismatch is fatal (mounted volumes are owned by the old UID), so
  # the UID check runs first and short-circuits the version check via
  # FORCE_BUILD when it triggers a rebuild. Version mismatch is advisory:
  # the image still works, it's just stale.
  check_image_uid_match "$IMAGE_TAG"
  if [[ "$FORCE_BUILD" != true ]]; then
    check_image_version_match "$IMAGE_TAG"
  fi

  if [[ "$FORCE_BUILD" == true ]] || [[ "$IMAGE_EXISTS" == false ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "Would build image: $RUNTIME $RUNTIME_ARGS build --network=host --target $BUILD_TARGET -t $IMAGE_TAG $SCRIPT_DIR"
    else
      echo "Building image $IMAGE_TAG (target: $BUILD_TARGET)..."
      runtime_build "$IMAGE_TAG" "$BUILD_TARGET" "$SCRIPT_DIR"
    fi
  fi

  # One-time heads-up: isolated home is now the default. If this workspace has
  # no per-workspace home volume yet but a legacy shared one exists, the user is
  # transitioning — the old volume is left untouched.
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if [[ "$DRY_RUN" != true && "${DEV_SHARED_HOME:-}" != "1" ]] \
     && ! $RUNTIME $RUNTIME_ARGS volume inspect "$HOME_VOLUME" >/dev/null 2>&1 \
     && $RUNTIME $RUNTIME_ARGS volume inspect devcontainer-home >/dev/null 2>&1; then
    echo "Note: dev now uses a per-workspace home volume ($HOME_VOLUME) by default." >&2
    echo "      Your old shared 'devcontainer-home' volume is untouched; set" >&2
    echo "      DEV_SHARED_HOME=1 to keep using it for this workspace." >&2
  fi

  start_container
}
