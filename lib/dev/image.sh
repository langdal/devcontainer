# shellcheck shell=bash
# lib/dev/image.sh — image build + UID/version label checks + rebuild cleanup.
# Sourced by dev; not executed directly.

# Build a runtime-appropriate 'build' command. Docker uses buildx; podman
# uses its built-in build. Args after the network/tag are passed through.
runtime_build() {
  local tag="$1"; shift
  local target="$1"; shift   # may be empty string; only docker/podman with --target use it
  local context="$1"; shift
  local extra=()
  if [[ -n "$target" ]]; then
    extra+=(--target "$target")
  fi
  extra+=(--build-arg "USER_UID=$HOST_UID" --build-arg "USER_GID=$HOST_GID")
  extra+=(--build-arg "DEV_VERSION=$VERSION")
  # Pass GITHUB_TOKEN as a BuildKit secret so `mise install` can hit the
  # GitHub API authenticated. Secrets are not persisted in image layers.
  # Both docker buildx and podman build accept --secret id=...,env=...
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    extra+=(--secret "id=github_token,env=GITHUB_TOKEN")
  fi
  if [[ "$RUNTIME" == "docker" ]]; then
    # buildx is mandatory for docker: this image's Dockerfile uses BuildKit
    # features (RUN --mount=type=secret, --secret) that the legacy builder
    # cannot parse, and modern docker (>=23.0) has no built-in BuildKit
    # without the plugin. Without buildx, `docker buildx build` is parsed as
    # a top-level `docker` invocation and fails with an opaque
    # "unknown flag: --network"; check up front and explain the real fix.
    if ! docker buildx version >/dev/null 2>&1; then
      echo "Error: 'docker buildx' is required to build the dev image, but it is not installed." >&2
      echo "       The Dockerfile uses BuildKit features (RUN --mount=type=secret) that the" >&2
      echo "       legacy builder cannot handle, so buildx is mandatory." >&2
      echo "       Install it:" >&2
      echo "         - Debian/Ubuntu:  sudo apt-get install docker-buildx-plugin" >&2
      echo "         - other:          https://docs.docker.com/go/buildx/" >&2
      echo "       Or, if podman is available, force it with:  DEV_RUNTIME=podman ./dev" >&2
      exit 1
    fi
    docker buildx build --network=host "${extra[@]}" -t "$tag" "$context"
  else
    # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
    podman $RUNTIME_ARGS build --network=host "${extra[@]}" -t "$tag" "$context"
  fi
}

# Remove the workspace's container (running or stopped) and the named
# volumes for the current invocation's image variant. Used after the
# user accepts the rebuild prompt; the rebuild path that follows
# replaces the image and the next container start re-populates the
# volumes from the freshly-built image.
cleanup_for_rebuild() {
  local container="$1" with_dind="$2"
  remove_container_if_exists "$container" "$RUNTIME_ARGS"
  local vols=(devcontainer-mise "$HOME_VOLUME")
  if [[ "$with_dind" == true ]]; then
    vols+=(devcontainer-dind)
  fi
  local v
  for v in "${vols[@]}"; do
    remove_volume_if_exists "$v" "$RUNTIME_ARGS"
  done
}

# Compare host UID/GID to the labels on $IMAGE_TAG. On a clean match (or
# image absent), return 0. On mismatch, either prompt-and-rebuild
# (interactive) or print a diagnostic and exit 1 (non-interactive). The
# explicit `--build` flag and `--dry-run` make this advisory rather than
# fatal — the build branch will still rebuild with the right args.
# Sets the global IMAGE_EXISTS so the build path below can skip a separate
# `images -q` probe.
check_image_uid_match() {
  local tag="$1"
  local labels img_uid img_gid
  # Single inspect retrieves all three labels we care about; IMAGE_VERSION
  # is stashed for check_image_version_match so it doesn't re-inspect.
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if ! labels=$($RUNTIME $RUNTIME_ARGS image inspect "$tag" \
      --format '{{ index .Config.Labels "dev.uid" }} {{ index .Config.Labels "dev.gid" }} {{ index .Config.Labels "dev.version" }}' \
      2>/dev/null); then
    IMAGE_EXISTS=false
    IMAGE_VERSION=""
    return 0
  fi
  IMAGE_EXISTS=true
  read -r img_uid img_gid IMAGE_VERSION <<< "$labels"
  if [[ -n "$img_uid" && -n "$img_gid" \
        && "$img_uid" == "$HOST_UID" && "$img_gid" == "$HOST_GID" ]]; then
    return 0
  fi
  local img_id="${img_uid:-?}:${img_gid:-?}"
  if [[ "$FORCE_BUILD" == true ]]; then
    echo "Note: image $tag built for UID:GID $img_id; rebuilding for $HOST_UID:$HOST_GID." >&2
    cleanup_for_rebuild "$CONTAINER_NAME" "$DIND"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "Would rebuild $tag for UID:GID $HOST_UID:$HOST_GID (current labels: $img_id)" >&2
    return 0
  fi
  if [[ "${DEV_ASSUME_YES:-0}" == "1" ]]; then
    echo "Note: image $tag built for UID:GID $img_id; DEV_ASSUME_YES set, rebuilding for $HOST_UID:$HOST_GID." >&2
    cleanup_for_rebuild "$CONTAINER_NAME" "$DIND"
    FORCE_BUILD=true
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: image $tag was built for UID:GID $img_id, but you are $HOST_UID:$HOST_GID." >&2
    echo "       Run 'dev --build' to rebuild for UID:GID $HOST_UID:$HOST_GID." >&2
    exit 1
  fi
  echo "Image $tag was built for UID:GID $img_id, but you are $HOST_UID:$HOST_GID." >&2
  local vol_list="devcontainer-mise, $HOME_VOLUME"
  if [[ "$DIND" == true ]]; then
    vol_list="${vol_list}, devcontainer-dind"
  fi
  local reply
  read -r -p "Rebuild image and remove volumes (${vol_list})? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      cleanup_for_rebuild "$CONTAINER_NAME" "$DIND"
      FORCE_BUILD=true
      ;;
    *)
      echo "Aborted." >&2
      exit 1
      ;;
  esac
}

# Compare the dev-script's $VERSION to the image's dev.version label.
# Unlike the UID check this is advisory: a stale image still works, so
# declining the prompt continues with the existing image. Sets
# FORCE_BUILD=true only when the user (or DEV_ASSUME_YES) opts in.
# Volumes are NOT wiped — they're version-agnostic.
check_image_version_match() {
  local tag="$1"
  if [[ "$IMAGE_EXISTS" != true ]]; then
    return 0
  fi
  if [[ "$FORCE_BUILD" == true ]]; then
    return 0
  fi
  # IMAGE_VERSION was populated by check_image_uid_match's inspect call.
  if [[ "$IMAGE_VERSION" == "$VERSION" ]]; then
    return 0
  fi
  local img_label="${IMAGE_VERSION:-<missing>}"
  if [[ "$DRY_RUN" == true ]]; then
    echo "Would rebuild $tag for dev version $VERSION (image label: $img_label)" >&2
    return 0
  fi
  if [[ "${DEV_ASSUME_YES:-0}" == "1" ]]; then
    echo "Note: image $tag built with dev version $img_label; DEV_ASSUME_YES set, rebuilding for $VERSION." >&2
    FORCE_BUILD=true
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Note: image $tag built with dev version $img_label; current dev script is $VERSION. Run 'dev --build' to rebuild." >&2
    return 0
  fi
  echo "Image $tag was built with dev version $img_label; current dev script is $VERSION." >&2
  local reply
  read -r -p "Rebuild image? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      FORCE_BUILD=true
      ;;
    *)
      echo "Continuing with existing image. Run 'dev --build' later to rebuild." >&2
      ;;
  esac
}
