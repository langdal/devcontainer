# shellcheck shell=bash
# lib/dev/up.sh — the shared start flow behind `dev up` / `dev exec` /
# `dev shell`: flag parsing, mode-conflict guard, host preflights, workspace
# name resolution, image build check, and the container start itself.
# Sourced by dev; not executed directly.

# cmd_start [start-options...] [-- CMD ...]
# The shared flag engine for `dev up`/`dev exec`/`dev shell`: those verb arms
# in `dev` translate their own spellings (--maint, --open, --) and call this
# with the remaining arguments. There is no other route in — bare `dev` and
# flag-first invocations are rejected by the router in `dev`.
# Assignments here are deliberately global (consumed by start_container and
# the lib/dev/* helpers); do not make them local.
cmd_start() {
  while [[ $# -gt 0 ]]; do
    case $1 in
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
        # first token, so e.g. `dev --dry-run --help` reaches here instead.
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
  # run before detect_runtime/preflight_subid_grant below so this error wins
  # over the (also-fatal) --dind subid preflight when both flags are given
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

  preflight_apparmor_userns

  detect_runtime
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
  # shellcheck disable=SC2034  # consumed by preflight_subid_grant() in lib/dev/preflight.sh
  DIND_MIN_SUBIDS=165535 # ids beyond id 0; namespace size = subids + 1
  preflight_subid_grant

  # Host identity. Used to (a) bake correct UID/GID into the image at
  # build time, and (b) detect when an existing image was built for a
  # different user.
  # shellcheck disable=SC2034  # consumed by refuse_root_uid/image.sh's runtime_build/check_image_uid_match and migrate_volume_for_keepid in lib/dev/lifecycle.sh
  HOST_UID=$(id -u)
  # shellcheck disable=SC2034  # consumed by runtime_build/check_image_uid_match in lib/dev/image.sh
  HOST_GID=$(id -g)
  refuse_root_uid

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

  WORKSPACE_BASENAME="$(basename "$(pwd)")"
  NORMAL_NAME="dev-${WORKSPACE_BASENAME}"
  MAINT_NAME="dev-${WORKSPACE_BASENAME}-maint"
  DIND_NAME="dev-${WORKSPACE_BASENAME}-dind"
  PIND_NAME="dev-${WORKSPACE_BASENAME}-pind"
  _resolve_home_volume

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
    # shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
    CONTAINER_NAME="$NORMAL_NAME"
  fi

  ensure_state_dir
  check_github_token
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
