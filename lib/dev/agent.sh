# shellcheck shell=bash
# lib/dev/agent.sh — `dev agent {add,list,rm}` handlers. Copy a curated,
# per-agent allowlist of credentials + settings from the host into this
# workspace's home volume. One-way snapshot: never a host mount, never baked
# into an image. Sourced by dev; not executed directly.

# Known agent names, in display order. 'all' is a pseudo-name expanded by
# _agent_expand; it is intentionally NOT in this list.
AGENT_KNOWN=(claude opencode pi)

# _agent_is_known <name> -> 0 if name is a supported agent, else 1.
_agent_is_known() {
  local n
  for n in "${AGENT_KNOWN[@]}"; do
    [[ "$n" == "$1" ]] && return 0
  done
  return 1
}

# _agent_manifest <name>: print one TSV line per manifest entry:
#   SRC_REL <TAB> DEST_REL <TAB> KIND <TAB> MODE
# SRC_REL is relative to the host $HOME; DEST_REL relative to /home/vscode.
# KIND is "file" or "dir"; MODE is "0600" for secrets, "-" otherwise.
# printf reuses the 4-field format for each group of 4 arguments.
_agent_manifest() {
  case "$1" in
    claude)
      printf '%s\t%s\t%s\t%s\n' \
        '.claude/.credentials.json' '.claude/.credentials.json' file 0600 \
        '.claude/settings.json'     '.claude/settings.json'     file -    \
        '.claude/CLAUDE.md'         '.claude/CLAUDE.md'         file -    \
        '.claude/commands'          '.claude/commands'          dir  -    \
        '.claude/agents'            '.claude/agents'            dir  -    \
        '.claude/skills'            '.claude/skills'            dir  -
      ;;
    opencode)
      printf '%s\t%s\t%s\t%s\n' \
        '.local/share/opencode/auth.json'     '.local/share/opencode/auth.json'     file 0600 \
        '.local/share/opencode/mcp-auth.json' '.local/share/opencode/mcp-auth.json' file 0600 \
        '.config/opencode/opencode.json'      '.config/opencode/opencode.json'      file 0600 \
        '.config/opencode/tui.json'           '.config/opencode/tui.json'           file -    \
        '.config/opencode/agents'             '.config/opencode/agents'             dir  -    \
        '.config/opencode/commands'           '.config/opencode/commands'           dir  -    \
        '.config/opencode/skills'             '.config/opencode/skills'             dir  -
      ;;
    pi)
      printf '%s\t%s\t%s\t%s\n' \
        '.pi/agent/auth.json'     '.pi/agent/auth.json'     file 0600 \
        '.pi/agent/settings.json' '.pi/agent/settings.json' file -    \
        '.pi/agent/models.json'   '.pi/agent/models.json'   file 0600 \
        '.pi/agent/skills'        '.pi/agent/skills'        dir  -    \
        '.pi/agent/extensions'    '.pi/agent/extensions'    dir  -
      ;;
  esac
}

# _agent_src_abs <name> <src_rel>: absolute host path for a manifest source.
# For pi, honor PI_CODING_AGENT_DIR (which relocates ~/.pi/agent) when set,
# keeping the DEST layout under the default .pi/agent/.
_agent_src_abs() {
  local name="$1" src_rel="$2"
  if [[ "$name" == pi && -n "${PI_CODING_AGENT_DIR:-}" && "$src_rel" == .pi/agent/* ]]; then
    printf '%s/%s\n' "${PI_CODING_AGENT_DIR%/}" "${src_rel#.pi/agent/}"
  else
    printf '%s/%s\n' "$HOME" "$src_rel"
  fi
}

# _agent_resolve <name>: print manifest lines whose source exists on the host,
# as TSV: SRC_ABS <TAB> DEST_REL <TAB> KIND <TAB> MODE. A top-level broken
# symlink fails the -e test and is skipped here; broken links *inside* a
# copied dir are handled at copy time.
_agent_resolve() {
  local name="$1" src_rel dest_rel kind mode src_abs
  while IFS=$'\t' read -r src_rel dest_rel kind mode; do
    [[ -n "$src_rel" ]] || continue
    src_abs="$(_agent_src_abs "$name" "$src_rel")"
    [[ -e "$src_abs" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$src_abs" "$dest_rel" "$kind" "$mode"
  done < <(_agent_manifest "$name")
}

# _agent_expand <mode> <arg...>: resolve name arguments to a deduped list,
# one per line. mode="host": 'all' -> known agents that have >=1 source on
# the host. mode="known": 'all' -> every known agent. Unknown names are fatal.
_agent_expand() {
  local mode="$1"; shift
  local a k
  local -a out=()
  for a in "$@"; do
    if [[ "$a" == all ]]; then
      for k in "${AGENT_KNOWN[@]}"; do
        if [[ "$mode" == known ]]; then
          out+=("$k")
        elif [[ -n "$(_agent_resolve "$k")" ]]; then
          out+=("$k")
        fi
      done
    elif _agent_is_known "$a"; then
      out+=("$a")
    else
      echo "Error: unknown agent '$a' (valid: ${AGENT_KNOWN[*]}, or 'all')" >&2
      exit 1
    fi
  done
  [[ ${#out[@]} -gt 0 ]] || return 0
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

# _agent_keepid: prints "true" when this runtime would create the workspace
# container with --userns=keep-id (rootless podman only), matching the logic
# in start_container. Otherwise "false".
_agent_keepid() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if $RUNTIME $RUNTIME_ARGS --version 2>/dev/null | grep -qi podman && runtime_is_rootless; then
    echo true
  else
    echo false
  fi
}

# _agent_copy_into_volume <name>: stage the resolved sources into a temp dir
# (dereferencing symlinks) and extract them into the workspace home volume
# through a short-lived helper container running as vscode with the same
# --userns=keep-id args the real container uses, so ownership is correct on
# Docker, rootful podman, and rootless podman alike.
_agent_copy_into_volume() {
  local name="$1" resolved
  resolved="$(_agent_resolve "$name")"
  if [[ -z "$resolved" ]]; then
    echo "  ${name}: no source files found on host — nothing to copy." >&2
    return 0
  fi

  local staging
  staging="$(mktemp -d)"
  local -a secret_dests=()
  local src dest kind mode
  while IFS=$'\t' read -r src dest kind mode; do
    [[ -n "$src" ]] || continue
    mkdir -p "$staging/$(dirname "$dest")"
    if [[ "$kind" == dir ]]; then
      mkdir -p "$staging/$dest"
      # -R recurse, -L dereference: links pointing outside the copied tree
      # become real files. Broken links make cp non-zero; warn, don't abort.
      if ! cp -RL "$src/." "$staging/$dest/" 2>/dev/null; then
        echo "  ${name}: warning: some entries under ${dest} were skipped (broken symlinks?)" >&2
      fi
    else
      if ! cp -L "$src" "$staging/$dest" 2>/dev/null; then
        echo "  ${name}: warning: skipped ${dest} (broken symlink?)" >&2
        continue
      fi
    fi
    echo "  ${name}: + ${dest}"
    [[ "$mode" == 0600 ]] && secret_dests+=("$dest")
  done <<< "$resolved"

  # Ensure the volume exists; under keep-id also make sure it is owned by the
  # host user before we write (reuses lifecycle.sh's one-time migration).
  local keepid
  keepid="$(_agent_keepid)"
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS volume create "$HOME_VOLUME" >/dev/null
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

  local rc=0
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  tar -C "$staging" -cf - . \
    | $RUNTIME $RUNTIME_ARGS run --rm -i \
        ${keepid_args[@]+"${keepid_args[@]}"} -u vscode \
        -v "$HOME_VOLUME":/home/vscode \
        --entrypoint sh "$IMAGE_TAG" -c "$remote" \
    || rc=$?
  rm -rf "$staging"
  return $rc
}

# _agent_volume_exists: 0 if the workspace home volume exists.
_agent_volume_exists() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS volume inspect "$HOME_VOLUME" >/dev/null 2>&1
}

# _agent_all_dests <name>: print every manifest DEST_REL for the agent
# (independent of whether the source exists on the host).
_agent_all_dests() {
  local src_rel dest_rel kind mode
  while IFS=$'\t' read -r src_rel dest_rel kind mode; do
    [[ -n "$dest_rel" ]] && printf '%s\n' "$dest_rel"
  done < <(_agent_manifest "$1")
}

# _agent_volume_present_dests: read candidate dest paths on stdin (one per
# line) and print those that exist in the home volume. One helper container
# for the whole set. Prints nothing if the volume does not exist.
_agent_volume_present_dests() {
  _agent_volume_exists || return 0
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  # shellcheck disable=SC2016  # single-quoted: runs in the helper container's shell, not the host
  # Trailing ": true" ensures the helper's own exit status stays 0 regardless
  # of whether the *last* candidate happened to exist — under our caller's
  # set -e/pipefail, a bare `present=$(... | this)` assignment would otherwise
  # abort the whole `dev` invocation whenever the last dest is absent (the
  # common case, since most agents' dests aren't all injected).
  $RUNTIME $RUNTIME_ARGS run --rm -i -u vscode \
    -v "$HOME_VOLUME":/home/vscode --entrypoint sh "$IMAGE_TAG" -c \
    'cd /home/vscode && while IFS= read -r p; do [ -e "$p" ] && printf "%s\n" "$p"; done; :'
}

# _agent_list: per-agent table of host-present? / injected-here?
_agent_list() {
  [[ $# -eq 0 ]] || { echo "Error: dev agent list takes no arguments: $*" >&2; exit 1; }

  # One helper call to learn which manifest dests currently exist in the volume.
  local present=""
  if _agent_volume_exists; then
    local a
    local all=""
    for a in "${AGENT_KNOWN[@]}"; do
      all+="$(_agent_all_dests "$a")"$'\n'
    done
    present="$(printf '%s' "$all" | _agent_volume_present_dests)"
  fi

  printf '%-10s  %-8s  %-11s\n' AGENT ON-HOST INJECTED-HERE
  local name host_yn inj_yn dest
  for name in "${AGENT_KNOWN[@]}"; do
    if [[ -n "$(_agent_resolve "$name")" ]]; then host_yn=yes; else host_yn=no; fi
    inj_yn=no
    while IFS= read -r dest; do
      [[ -n "$dest" ]] || continue
      if printf '%s\n' "$present" | grep -Fxq "$dest"; then inj_yn=yes; break; fi
    done < <(_agent_all_dests "$name")
    printf '%-10s  %-8s  %-11s\n' "$name" "$host_yn" "$inj_yn"
  done
}

# _agent_rm <name>... | all: delete an agent's injected files from the volume.
_agent_rm() {
  local -a raw=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift ;;
      -*) echo "Error: dev agent rm: unknown option: $1" >&2; exit 1 ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  [[ ${#raw[@]} -gt 0 ]] || {
    echo "Error: dev agent rm: name required (${AGENT_KNOWN[*]}, or 'all')" >&2
    exit 1
  }

  if ! _agent_volume_exists; then
    echo "No home volume (${HOME_VOLUME}) for this workspace — nothing to remove."
    return 0
  fi

  local -a targets=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && targets+=("$line")
  done < <(_agent_expand known "${raw[@]}")

  local name dest reply
  local -a dests
  for name in "${targets[@]}"; do
    dests=()
    while IFS= read -r dest; do
      [[ -n "$dest" ]] && dests+=("$dest")
    done < <(_agent_all_dests "$name")

    if [[ "${DEV_ASSUME_YES:-}" != "1" ]]; then
      echo "About to remove ${name} files from ${HOME_VOLUME}:"
      printf '  %s\n' "${dests[@]}"
      read -r -p "Remove them? [y/N] " reply
      case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Skipped ${name}."; continue ;;
      esac
    fi

    # Build the remote rm; quote each dest path.
    local remote='cd /home/vscode && rm -rf'
    for dest in "${dests[@]}"; do
      remote+=" $(printf '%q' "$dest")"
    done
    # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
    $RUNTIME $RUNTIME_ARGS run --rm -u vscode \
      -v "$HOME_VOLUME":/home/vscode --entrypoint sh "$IMAGE_TAG" -c "$remote"
    echo "Removed ${name} files from ${HOME_VOLUME}."
  done
}

_agent_usage() {
  cat <<'EOF'
Usage: dev agent add  <name>... | all    Copy an agent's creds+settings in
       dev agent list                    Show host / injected status
       dev agent rm   <name>... | all    Remove an agent's injected files

Agents: claude, opencode, pi

'add' is a one-way snapshot into this workspace's home volume (never a host
mount, never baked into an image). Re-run 'add' to refresh (tokens expire).
Preview with 'dev agent add <name> --dry-run'. Remove with 'dev agent rm'
or wipe the whole home volume with 'dev reset'.
EOF
}

# _agent_add [--dry-run] <name>... | all
_agent_add() {
  local dry=false
  local -a raw=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=true; shift ;;
      --) shift ;;
      -*) echo "Error: dev agent add: unknown option: $1" >&2; exit 1 ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  [[ ${#raw[@]} -gt 0 ]] || {
    echo "Error: dev agent add: name required (${AGENT_KNOWN[*]}, or 'all')" >&2
    exit 1
  }

  local -a targets=()
  local line expanded
  # Capture via command substitution (not process substitution): _agent_expand
  # calls `exit` on an unknown name, and that exit code only propagates
  # through $? of a command substitution, not through a `< <(...)` pipeline.
  expanded="$(_agent_expand host "${raw[@]}")" || exit 1
  while IFS= read -r line; do
    [[ -n "$line" ]] && targets+=("$line")
  done <<< "$expanded"
  [[ ${#targets[@]} -gt 0 ]] || { echo "No matching agents found on host."; return 0; }

  local name src dest kind mode resolved
  for name in "${targets[@]}"; do
    if [[ "$dry" == true ]]; then
      resolved="$(_agent_resolve "$name")"
      if [[ -z "$resolved" ]]; then
        echo "  ${name}: no source files found on host."
        continue
      fi
      while IFS=$'\t' read -r src dest kind mode; do
        [[ -n "$src" ]] || continue
        if [[ "$mode" == 0600 ]]; then
          echo "  ${name}: would copy ${dest} (mode 0600)"
        else
          echo "  ${name}: would copy ${dest}"
        fi
      done <<< "$resolved"
    else
      _agent_copy_into_volume "$name"
    fi
  done

  if [[ "$dry" == false ]]; then
    echo "Done. Injected into ${HOME_VOLUME}. Re-run 'dev agent add' to refresh;"
    echo "'dev agent rm' or 'dev reset' to remove."
  fi
}
