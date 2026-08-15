# shellcheck shell=bash
# lib/dev/inject.sh — the shared host->home-volume injection machinery behind
# `dev agent add` and `dev dotfile add`: target-storage routing plus the
# helper-container tar-copy that writes into the workspace home volume as
# vscode. Sourced by dev; not executed directly.

# resolve_agent_storage <want_dind> <want_pind>: shared storage routing for the
# `dev agent` and `dev dotfile` subcommands, both of which inject host files
# into the workspace home volume via a helper container. Runs runtime detection
# + workspace-name resolution, then selects IMAGE_TAG + RUNTIME_ARGS for the
# target home-volume storage and sets HOST_UID. On macOS+podman, where a
# dind/pind container's home volume lives in a *separate* rootful podman
# connection, it auto-detects a running dind/pind container when neither flag
# was given (an explicit flag always wins) and, when nothing is running, warns
# if the workspace has rootful storage so files don't land where the container
# can't see them. Elsewhere DIND_RUNTIME_ARGS is empty and the split is a no-op.
resolve_agent_storage() {
  local want_dind="$1" want_pind="$2"
  detect_runtime
  ensure_runtime_ready
  _resolve_workspace_names
  if [[ "$want_dind" != true && "$want_pind" != true && -n "$DIND_RUNTIME_ARGS" ]]; then
    resolve_managed_container
    case "$MANAGED_TARGET" in
      dind) want_dind=true
            echo "Detected running ${DIND_NAME}; targeting its (dind) storage." >&2 ;;
      pind) want_pind=true
            echo "Detected running ${PIND_NAME}; targeting its (pind) storage." >&2 ;;
      *)    # Nothing dind/pind running: default to rootless storage. If this
            # workspace nonetheless has a rootful home volume, it has been used
            # in dind/pind mode — warn so files don't silently miss it.
            # shellcheck disable=SC2086  # intentional word-splitting of DIND_RUNTIME_ARGS
            if [[ -z "$MANAGED_TARGET" ]] \
               && $RUNTIME $DIND_RUNTIME_ARGS volume inspect "$HOME_VOLUME" >/dev/null 2>&1; then
              echo "Note: this workspace also has dind/pind storage (separate rootful connection)." >&2
              echo "      For a 'dev up --dind'/'dev up --pind' container, re-run with the matching flag so" >&2
              echo "      the files reach that container's home volume." >&2
            fi ;;
    esac
  fi
  # Select the image variant + runtime connection the target container uses.
  if [[ "$want_dind" == true ]]; then
    IMAGE_TAG="${IMAGE_NAME}:dind"; RUNTIME_ARGS="$DIND_RUNTIME_ARGS"
  elif [[ "$want_pind" == true ]]; then
    IMAGE_TAG="${IMAGE_NAME}:pind"; RUNTIME_ARGS="$DIND_RUNTIME_ARGS"
  else
    IMAGE_TAG="$IMAGE_NAME"
  fi
  # shellcheck disable=SC2034  # consumed by migrate_volume_for_keepid in lib/dev/volumes.sh
  HOST_UID=$(id -u)
}

# _agent_keepid: prints "true" when this runtime would create the workspace
# container with --userns=keep-id (rootless podman only), matching the logic
# in start_container. Otherwise "false".
_agent_keepid() {
  if engine_is_podman && runtime_is_rootless; then
    echo true
  else
    echo false
  fi
}

# _agent_require_image: fail clearly if the helper image is not built yet.
# The agent helpers (copy/probe/rm) all run this image; the dev agent path
# never builds it (unlike the start path), so check before any helper run.
_agent_require_image() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if ! $RUNTIME $RUNTIME_ARGS image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Error: image '$IMAGE_TAG' is not built yet. Run './dev up --build' (or start the container once with './dev up') first." >&2
    exit 1
  fi
}

# _agent_volume_exists: 0 if the workspace home volume exists.
_agent_volume_exists() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS volume inspect "$HOME_VOLUME" >/dev/null 2>&1
}

# _stage_and_extract <label_prefix>: read TSV lines (SRC_ABS \t DEST_REL \t
# MODE) on stdin, stage them into a temp dir (dereferencing symlinks, so links
# pointing outside the copied tree become real files), then extract them into
# the workspace home volume through a short-lived helper container running as
# vscode with the same --userns=keep-id args the real container uses — so
# ownership is correct on Docker, rootful podman, and rootless podman alike.
# MODE "0600" tightens that dest to 600 after extraction (secrets); any other
# value preserves the staged perms. Prints "<prefix>+ <dest>" per copied entry
# (and warnings on broken symlinks). Returns the helper's exit code. Shared by
# `dev agent add` (via _agent_copy_into_volume) and `dev dotfile add`.
_stage_and_extract() {
  local prefix="$1"
  _agent_require_image

  local staging
  staging="$(mktemp -d)"
  local -a secret_dests=()
  local src dest mode
  while IFS=$'\t' read -r src dest mode; do
    [[ -n "$src" ]] || continue
    mkdir -p "$staging/$(dirname "$dest")"
    if [[ -d "$src" ]]; then
      mkdir -p "$staging/$dest"
      # -R recurse, -L dereference: links pointing outside the copied tree
      # become real files. Broken links make cp non-zero; warn, don't abort.
      if ! cp -RL "$src/." "$staging/$dest/" 2>/dev/null; then
        echo "${prefix}warning: some entries under ${dest} were skipped (broken symlinks?)" >&2
      fi
    else
      if ! cp -L "$src" "$staging/$dest" 2>/dev/null; then
        echo "${prefix}warning: skipped ${dest} (broken symlink?)" >&2
        continue
      fi
    fi
    echo "${prefix}+ ${dest}"
    [[ "$mode" == 0600 ]] && secret_dests+=("$dest")
  done

  # Ensure the volume exists; under keep-id also make sure it is owned by the
  # host user before we write (reuses volumes.sh's one-time migration).
  # Create only when missing: `docker volume create` is idempotent, but
  # `podman volume create` errors ("volume already exists") on an existing
  # volume, which under set -e would abort before the copy ever runs.
  local keepid
  keepid="$(_agent_keepid)"
  if ! _agent_volume_exists; then
    # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
    $RUNTIME $RUNTIME_ARGS volume create "$HOME_VOLUME" >/dev/null
  fi
  [[ "$keepid" == true ]] && migrate_volume_for_keepid "$HOME_VOLUME"

  # Remote command: extract, then tighten secret modes. Quote each dest.
  local remote='cd /home/vscode && tar -xf -'
  if [[ ${#secret_dests[@]} -gt 0 ]]; then
    remote+=' && chmod 600'
    local d
    for d in "${secret_dests[@]}"; do
      remote+=" $(printf '%q' "$d")"
    done
  fi

  local -a keepid_args=()
  [[ "$keepid" == true ]] && keepid_args=(--userns=keep-id)

  # On macOS the host tar is bsdtar, which stores each file's macOS xattrs
  # (notably com.apple.provenance) as LIBARCHIVE.xattr.* extended headers plus
  # an AppleDouble copy. GNU tar inside the container doesn't know that keyword
  # and prints a warning per file ("Ignoring unknown extended header keyword
  # ..."). Strip both at creation so the stream is clean; these flags are
  # bsdtar-only (GNU tar lacks --no-mac-metadata and never emits these anyway).
  local -a tar_args=()
  if tar --version 2>/dev/null | grep -qi bsdtar; then
    tar_args+=(--no-xattrs --no-mac-metadata)
  fi

  local rc=0
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  tar "${tar_args[@]+"${tar_args[@]}"}" -C "$staging" -cf - . \
    | $RUNTIME $RUNTIME_ARGS run --rm -i \
        ${keepid_args[@]+"${keepid_args[@]}"} -u vscode \
        -v "$HOME_VOLUME":/home/vscode \
        --entrypoint sh "$IMAGE_TAG" -c "$remote" \
    || rc=$?
  rm -rf "$staging"
  return $rc
}
