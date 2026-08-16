# shellcheck shell=bash
# lib/dev/dotfile.sh — `dev dotfile {add,rm}` handlers. Copy an arbitrary host
# file or directory into this workspace's home volume, mirroring its path
# relative to $HOME (e.g. ~/.config/nvim -> ~/.config/nvim in the container),
# dereferencing symlinks. A one-way snapshot, same mechanism and storage
# routing as `dev agent`: never a host mount, never baked into an image.
#
# Reuses inject.sh's _stage_and_extract + volume helpers (_agent_require_image,
# _agent_keepid, _agent_volume_exists) and volumes.sh's migrate_volume_for_keepid.
# The dispatch in `dev` has already set IMAGE_TAG / RUNTIME_ARGS / HOST_UID for
# the target storage via resolve_agent_storage. Sourced by dev; not executed
# directly.

# cmd_dotfile <action> [args]: the `dev dotfile` verb (also reachable as
# `dev dotfiles`). Validates the action, pulls out the storage-routing flags,
# and calls the matching handler.
cmd_dotfile() {
  dotfile_action="${1:-}"
  case "$dotfile_action" in
    add|rm) shift ;;
    ''|-h|--help|help) _dotfile_usage; exit 0 ;;
    *)
      echo "Error: dev dotfile: expected an action (add|rm), got '${dotfile_action:-<none>}'" >&2
      echo "Run 'dev --help' for usage information" >&2
      exit 1
      ;;
  esac
  # Pull out --dind/--pind (storage routing, same semantics as `dev agent`)
  # so they apply regardless of position; leave everything else (paths and
  # add's --secret) for the action handler.
  DOTFILE_DIND=false
  DOTFILE_PIND=false
  dotfile_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dind) DOTFILE_DIND=true; shift ;;
      --pind) DOTFILE_PIND=true; shift ;;
      *) dotfile_args+=("$1"); shift ;;
    esac
  done
  if [[ "$DOTFILE_DIND" == true && "$DOTFILE_PIND" == true ]]; then
    echo "Error: dev dotfile: --dind and --pind are mutually exclusive." >&2
    exit 1
  fi
  # The handlers validate their path args before calling resolve_agent_storage
  # themselves, so a bad path fails without the storage-detection hint. Pass
  # the storage flags through for that deferred resolution.
  set -- ${dotfile_args[@]+"${dotfile_args[@]}"}
  case "$dotfile_action" in
    add) _dotfile_add "$DOTFILE_DIND" "$DOTFILE_PIND" "$@" ;;
    rm)  _dotfile_rm  "$DOTFILE_DIND" "$DOTFILE_PIND" "$@" ;;
  esac
  exit 0
}

# _dotfile_abs <path>: resolve <path> to an absolute path. Expands a leading ~
# (belt-and-suspenders: the shell already does this for unquoted args) and
# prefixes the cwd for a relative path. The final component's symlink is NOT
# resolved — the dest mirrors the path as given, under $HOME; symlink *contents*
# are dereferenced later at copy time. Trailing slashes are stripped.
_dotfile_abs() {
  local p="$1"
  # Match a literal leading tilde in the argument (present only when the user
  # quoted it — an unquoted ~ is already expanded by their shell) and expand it.
  # shellcheck disable=SC2088  # these are match patterns, not tilde expansion
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  [[ "$p" == /* ]] || p="$(pwd)/$p"
  while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
  printf '%s\n' "$p"
}

# _dotfile_dest_rel <abs_path>: print <abs_path> relative to $HOME, or return 2
# if it is not under $HOME. Refuses $HOME itself (would map to an empty dest).
_dotfile_dest_rel() {
  local abs="$1" home="${HOME%/}"
  case "$abs" in
    "$home"/?*) printf '%s\n' "${abs#"$home"/}" ;;
    *)          return 2 ;;
  esac
}

# _dotfile_map <path>: echo the volume-relative dest for <path>, or exit 1 with
# a clear message if it is outside $HOME or resolves to an unsafe location
# (empty, ".", or containing ".." segments that could escape the home tree).
_dotfile_map() {
  local p="$1" abs dest
  abs="$(_dotfile_abs "$p")"
  if ! dest="$(_dotfile_dest_rel "$abs")"; then
    echo "Error: '$p' is not under \$HOME ($HOME); dotfiles must live under your home directory." >&2
    exit 1
  fi
  case "$dest" in
    ""|"."|..|../*|*/../*|*/..)
      echo "Error: refusing unsafe destination for '$p' (resolves to '$dest')." >&2
      exit 1 ;;
  esac
  printf '%s\n' "$dest"
}

_dotfile_usage() {
  cat <<'EOF'
Usage: dev dotfile add [--secret] <path>...   Copy a host file/dir into this
                                              workspace's home volume
       dev dotfile rm  <path>...              Remove it from the home volume

Copies an arbitrary file or directory from your host into this workspace's
per-workspace home volume, mirroring its path relative to $HOME — e.g.
'dev dotfile add ~/.config/nvim' lands at ~/.config/nvim in the container.
Symlinks are dereferenced (their contents are copied as real files). One-way
snapshot — never a host mount, never baked into an image. Re-run 'add' to
refresh; 'dev dotfile rm <path>' or 'dev reset' to remove.

  --secret        chmod 600 the copied paths in the volume (for files that
                  hold tokens/keys).
  --dind|--pind   Target a dind/pind container's storage (auto-detected from a
                  running container on macOS+podman; same as 'dev agent').
EOF
}

# _dotfile_add <want_dind> <want_pind> [--secret] <path>...
# want_dind/want_pind are the storage flags parsed by the dispatch; they are
# forwarded to resolve_agent_storage only AFTER argument validation, so bad
# input fails cleanly without the storage auto-detection hint muddying it.
_dotfile_add() {
  local want_dind="$1" want_pind="$2"; shift 2
  local secret=false
  local -a raw=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --secret) secret=true; shift ;;
      --) shift ;;
      -*) echo "Error: dev dotfile add: unknown option: $1" >&2; exit 1 ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  [[ ${#raw[@]} -gt 0 ]] || {
    echo "Error: dev dotfile add: path required (e.g. 'dev dotfile add ~/.config/nvim')" >&2
    exit 1
  }

  local mode="-"
  [[ "$secret" == true ]] && mode="0600"

  # Validate first (uses $HOME only, no runtime): build the
  # SRC_ABS \t DEST_REL \t MODE stream for _stage_and_extract, failing fast on a
  # missing source or an out-of-$HOME/unsafe path before we resolve storage.
  local -a tsv=()
  local p abs dest
  for p in "${raw[@]}"; do
    abs="$(_dotfile_abs "$p")"
    if [[ ! -e "$abs" ]]; then
      echo "Error: no such file or directory: '$p' ($abs)" >&2
      exit 1
    fi
    dest="$(_dotfile_map "$p")"
    tsv+=("$(printf '%s\t%s\t%s' "$abs" "$dest" "$mode")")
  done

  # Args are valid — now resolve the target storage (may print a hint) and copy.
  resolve_agent_storage "$want_dind" "$want_pind"

  local rc=0
  printf '%s\n' "${tsv[@]}" | _stage_and_extract "  " || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "Error: failed to copy one or more dotfiles into ${HOME_VOLUME}." >&2
    exit 1
  fi
  echo "Done. Injected into ${HOME_VOLUME}. Re-run 'dev dotfile add' to refresh;"
  echo "'dev dotfile rm <path>' or 'dev reset' to remove."
}

# _dotfile_rm <want_dind> <want_pind> <path>...
# Like _dotfile_add, validation runs before resolve_agent_storage so bad input
# fails without the storage-detection hint.
_dotfile_rm() {
  local want_dind="$1" want_pind="$2"; shift 2
  local -a raw=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift ;;
      -*) echo "Error: dev dotfile rm: unknown option: $1" >&2; exit 1 ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  [[ ${#raw[@]} -gt 0 ]] || {
    echo "Error: dev dotfile rm: path required (e.g. 'dev dotfile rm ~/.config/nvim')" >&2
    exit 1
  }

  # Validate/map paths first (uses $HOME only, no runtime).
  local -a dests=()
  local p
  for p in "${raw[@]}"; do
    dests+=("$(_dotfile_map "$p")")
  done

  # Args are valid — resolve storage (may print a hint), then remove.
  resolve_agent_storage "$want_dind" "$want_pind"

  if ! _agent_volume_exists; then
    echo "No home volume (${HOME_VOLUME}) for this workspace — nothing to remove."
    return 0
  fi
  _agent_require_image

  if [[ "${DEV_ASSUME_YES:-}" != "1" ]]; then
    local reply
    echo "About to remove from ${HOME_VOLUME}:"
    printf '  %s\n' "${dests[@]}"
    read -r -p "Remove them? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  # Match the volume's --userns=keep-id ownership (rootless podman) so the
  # removal helper's vscode can traverse and delete under /home/vscode.
  local -a keepid_args=()
  [[ "$(_agent_keepid)" == true ]] && keepid_args=(--userns=keep-id)

  local remote='cd /home/vscode && rm -rf'
  local d
  for d in "${dests[@]}"; do
    remote+=" $(printf '%q' "$d")"
  done
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS / keepid_args
  $RUNTIME $RUNTIME_ARGS run --rm ${keepid_args[@]+"${keepid_args[@]}"} -u vscode \
    -v "$HOME_VOLUME":/home/vscode --entrypoint sh "$IMAGE_TAG" -c "$remote"
  echo "Removed from ${HOME_VOLUME}: ${dests[*]}"
}
