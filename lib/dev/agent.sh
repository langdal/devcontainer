# shellcheck shell=bash
# lib/dev/agent.sh — `dev agent {add,list,rm}` handlers. Copy a curated,
# per-agent allowlist of credentials + settings from the host into this
# workspace's home volume. One-way snapshot: never a host mount, never baked
# into an image. This file owns the per-agent manifests, host resolution
# (including the macOS Keychain fallback) and the command UI; the storage
# routing and the helper-container copy itself live in lib/dev/inject.sh.
# Sourced by dev; not executed directly.

# Known agent names, in display order. 'all' is a pseudo-name expanded by
# _agent_expand; it is intentionally NOT in this list.
AGENT_KNOWN=(claude opencode pi)

# macOS stores Claude Code's OAuth token in the login Keychain (a generic
# password under this service name) instead of ~/.claude/.credentials.json, so
# the manifest's file source never exists on a Mac. _agent_resolve falls back
# to this Keychain entry and emits AGENT_KEYCHAIN_CLAUDE_SRC as a sentinel SRC
# (never a real path); the copy path materializes it into a real staged file.
CLAUDE_KEYCHAIN_SERVICE='Claude Code-credentials'
AGENT_KEYCHAIN_CLAUDE_SRC='keychain:claude-credentials'

# cmd_agent <action> [args]: the `dev agent` verb. Validates the action, pulls
# out the storage-routing flags, and calls the matching handler.
cmd_agent() {
  agent_action="${1:-}"
  case "$agent_action" in
    add|list|rm) shift ;;
    ''|-h|--help|help) _agent_usage; exit 0 ;;
    *)
      echo "Error: dev agent: expected an action (add|list|rm), got '${agent_action:-<none>}'" >&2
      echo "Run 'dev --help' for usage information" >&2
      exit 1
      ;;
  esac
  # --dind/--pind route the helper containers at the storage the target
  # container actually uses. On macOS+podman the dind/pind container and its
  # home volume live in a *separate* rootful podman connection; without this
  # routing, `agent add` writes into the default rootless home volume that the
  # dind/pind container never mounts (creds silently never appear inside).
  # Extract the flags here so they apply uniformly to add/list/rm, then pass
  # the remaining args (agent names, --dry-run) through untouched.
  AGENT_DIND=false
  AGENT_PIND=false
  agent_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dind) AGENT_DIND=true; shift ;;
      --pind) AGENT_PIND=true; shift ;;
      *) agent_args+=("$1"); shift ;;
    esac
  done
  if [[ "$AGENT_DIND" == true && "$AGENT_PIND" == true ]]; then
    echo "Error: dev agent: --dind and --pind are mutually exclusive." >&2
    exit 1
  fi
  # The handlers validate their args before calling resolve_agent_storage
  # themselves (and skip it entirely for `add --dry-run`, which needs no
  # runtime), so bad input fails without the storage-detection hint. Pass the
  # storage flags through for that deferred resolution.
  set -- ${agent_args[@]+"${agent_args[@]}"}
  case "$agent_action" in
    add)  _agent_add  "$AGENT_DIND" "$AGENT_PIND" "$@" ;;
    list) _agent_list "$AGENT_DIND" "$AGENT_PIND" "$@" ;;
    rm)   _agent_rm   "$AGENT_DIND" "$AGENT_PIND" "$@" ;;
  esac
  exit 0
}

# _agent_macos_keychain_has_creds: 0 if Claude Code's OAuth token is present in
# the macOS login Keychain. Non-macOS (no `security`) returns non-zero, so the
# fallback is inert on Linux where the credential file exists on disk instead.
_agent_macos_keychain_has_creds() {
  [[ "$(uname -s)" == Darwin ]] || return 1
  command -v security >/dev/null 2>&1 || return 1
  security find-generic-password -s "$CLAUDE_KEYCHAIN_SERVICE" -w >/dev/null 2>&1
}

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

  # macOS fallback: Claude Code keeps its OAuth token in the login Keychain, not
  # in ~/.claude/.credentials.json, so the manifest's file source above is
  # skipped on a Mac. If that file is absent but the Keychain entry exists, emit
  # a sentinel source (never a real path) that the copy path materializes into
  # the dest — the Keychain payload is byte-for-byte the file Claude reads inside
  # the Linux container. Guarded on file-absence so a real file always wins.
  if [[ "$name" == claude && ! -e "$HOME/.claude/.credentials.json" ]] \
     && _agent_macos_keychain_has_creds; then
    printf '%s\t%s\t%s\t%s\n' \
      "$AGENT_KEYCHAIN_CLAUDE_SRC" '.claude/.credentials.json' file 0600
  fi
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

# _agent_materialize_keychain <tmpdir>: read 4-field resolved TSV (SRC \t DEST
# \t KIND \t MODE) on stdin; for each line whose SRC is the Keychain sentinel,
# dump the Keychain payload to a file under <tmpdir> and rewrite SRC to that
# path. All other lines pass through unchanged. Fails (non-zero) if a sentinel
# line's payload can't be read, so the caller can abort before copying.
_agent_materialize_keychain() {
  local tmpdir="$1" src dest kind mode kc_out i=0
  while IFS=$'\t' read -r src dest kind mode; do
    [[ -n "$src" ]] || continue
    if [[ "$src" == "$AGENT_KEYCHAIN_CLAUDE_SRC" ]]; then
      kc_out="$tmpdir/cred_$i"; i=$((i + 1))
      # -w prints just the password (the raw JSON). JSON.parse tolerates the
      # trailing newline `security` appends, so no post-processing is needed.
      security find-generic-password -s "$CLAUDE_KEYCHAIN_SERVICE" -w > "$kc_out" 2>/dev/null \
        || return 1
      src="$kc_out"
    fi
    printf '%s\t%s\t%s\t%s\n' "$src" "$dest" "$kind" "$mode"
  done
}

# _agent_copy_into_volume <name>: resolve an agent's manifest to existing host
# sources and inject them into the workspace home volume via _stage_and_extract,
# then apply the claude-only onboarding-flag follow-up.
_agent_copy_into_volume() {
  local name="$1" resolved
  resolved="$(_agent_resolve "$name")"
  if [[ -z "$resolved" ]]; then
    echo "  ${name}: no source files found on host — nothing to copy." >&2
    return 0
  fi

  # Materialize any Keychain-sourced entries (macOS Claude credentials) into a
  # temp dir, rewriting their SRC to a real path so _stage_and_extract can cp
  # them like any host file. Cleaned up once the copy has run.
  local kc_dir=""
  if [[ "$resolved" == *"${AGENT_KEYCHAIN_CLAUDE_SRC}"$'\t'* ]]; then
    kc_dir="$(mktemp -d)"
    if ! resolved="$(_agent_materialize_keychain "$kc_dir" <<< "$resolved")"; then
      rm -rf "$kc_dir"
      echo "  ${name}: failed to read credentials from the macOS Keychain." >&2
      return 1
    fi
  fi

  local rc=0
  # _agent_resolve emits SRC_ABS \t DEST_REL \t KIND \t MODE; _stage_and_extract
  # takes SRC_ABS \t DEST_REL \t MODE (it detects dir vs file itself). Drop KIND.
  cut -f1,2,4 <<< "$resolved" | _stage_and_extract "  ${name}: " || rc=$?
  [[ -n "$kc_dir" ]] && rm -rf "$kc_dir"

  # Claude gates its interactive onboarding wizard (theme picker + "Select
  # login method") on hasCompletedOnboarding in ~/.claude.json — a top-level
  # file that lives *outside* ~/.claude/ and is never in the manifest (it also
  # holds cross-workspace project history we deliberately exclude). Copying
  # only .credentials.json authenticates the API but leaves that flag unset,
  # so the login prompt reappears in every fresh workspace. Set the one flag.
  if [[ "$rc" -eq 0 && "$name" == claude ]]; then
    local -a keepid_args=()
    keepid_active && keepid_args=("$KEEPID_FLAG")
    # shellcheck disable=SC2086  # forward keepid_args verbatim (empty -> no arg)
    _agent_mark_claude_onboarded ${keepid_args[@]+"${keepid_args[@]}"} || rc=$?
  fi
  return $rc
}

# _agent_mark_claude_onboarded [keepid-arg...]: ensure ~/.claude.json in the
# workspace home volume has hasCompletedOnboarding=true so Claude Code's
# interactive onboarding/login wizard does not run. Merges into an existing
# file (never clobbers accumulated state), creates a minimal one if absent,
# and leaves a corrupt / non-object file untouched. Runs node (baked on the
# image PATH via /mise/shims) in a short-lived helper under the same
# --userns=keep-id mapping the volume was written with. Args are the caller's
# keepid_args, forwarded verbatim.
_agent_mark_claude_onboarded() {
  local js='
const fs = require("fs");
const p = "/home/vscode/.claude.json";
let d = {};
if (fs.existsSync(p)) {
  try {
    const parsed = JSON.parse(fs.readFileSync(p, "utf8"));
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      d = parsed;
    } else {
      console.error("  claude: ~/.claude.json is not a JSON object; left as-is");
      process.exit(0);
    }
  } catch (e) {
    console.error("  claude: ~/.claude.json is not valid JSON; left as-is");
    process.exit(0);
  }
}
if (d.hasCompletedOnboarding !== true) {
  d.hasCompletedOnboarding = true;
  fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");
  fs.chmodSync(p, 0o600);
  console.log("  claude: + ~/.claude.json (hasCompletedOnboarding — skips login wizard)");
}
'
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  printf '%s' "$js" | $RUNTIME $RUNTIME_ARGS run --rm -i \
    "$@" -u vscode \
    -v "$HOME_VOLUME":/home/vscode \
    --entrypoint sh "$IMAGE_TAG" -c 'node'
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
  _agent_require_image
  # Run the probe under the same --userns=keep-id mapping the volume was
  # written with (rootless podman). Without it, vscode maps to a subuid that
  # cannot even traverse the keep-id-owned /home/vscode mount, so `cd` fails
  # ("can't cd to /home/vscode") and every dest reads as absent.
  local -a keepid_args=()
  keepid_active && keepid_args=("$KEEPID_FLAG")
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  # shellcheck disable=SC2016  # single-quoted: runs in the helper container's shell, not the host
  # Trailing ": true" ensures the helper's own exit status stays 0 regardless
  # of whether the *last* candidate happened to exist — under our caller's
  # set -e/pipefail, a bare `present=$(... | this)` assignment would otherwise
  # abort the whole `dev` invocation whenever the last dest is absent (the
  # common case, since most agents' dests aren't all injected).
  $RUNTIME $RUNTIME_ARGS run --rm -i ${keepid_args[@]+"${keepid_args[@]}"} -u vscode \
    -v "$HOME_VOLUME":/home/vscode --entrypoint sh "$IMAGE_TAG" -c \
    'cd /home/vscode && while IFS= read -r p; do [ -e "$p" ] && printf "%s\n" "$p"; done; :'
}

# _agent_list <want_dind> <want_pind>: per-agent table of host-present? /
# injected-here? Resolves storage after the arg check (needs runtime to probe
# the volume).
_agent_list() {
  local want_dind="$1" want_pind="$2"; shift 2
  [[ $# -eq 0 ]] || { echo "Error: dev agent list takes no arguments: $*" >&2; exit 1; }
  resolve_agent_storage "$want_dind" "$want_pind"

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

# _agent_rm <want_dind> <want_pind> <name>... | all: delete an agent's injected
# files from the volume. Validates names before resolving storage, so an unknown
# name fails without the storage auto-detection hint.
_agent_rm() {
  local want_dind="$1" want_pind="$2"; shift 2
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

  local -a targets=()
  local line expanded
  # Capture via command substitution (not process substitution): _agent_expand
  # calls `exit` on an unknown name, and that exit code only propagates
  # through $? of a command substitution, not through a `< <(...)` pipeline.
  expanded="$(_agent_expand known "${raw[@]}")" || exit 1
  while IFS= read -r line; do
    [[ -n "$line" ]] && targets+=("$line")
  done <<< "$expanded"

  # Args are valid — resolve storage (may print a hint), then remove.
  resolve_agent_storage "$want_dind" "$want_pind"

  if ! _agent_volume_exists; then
    echo "No home volume (${HOME_VOLUME}) for this workspace — nothing to remove."
    return 0
  fi
  _agent_require_image

  # Match the volume's --userns=keep-id ownership (rootless podman) so the
  # removal helper's vscode can traverse and delete under /home/vscode.
  local -a keepid_args=()
  keepid_active && keepid_args=("$KEEPID_FLAG")

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
    $RUNTIME $RUNTIME_ARGS run --rm ${keepid_args[@]+"${keepid_args[@]}"} -u vscode \
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

For a container started with 'dev up --dind' or 'dev up --pind', pass the matching
--dind/--pind flag (e.g. 'dev agent add claude --pind'). On macOS+podman the
dind/pind container uses a separate storage backend, and without the flag the
credentials land in a home volume that container never mounts.
EOF
}

# _agent_add <want_dind> <want_pind> [--dry-run] <name>... | all
# want_dind/want_pind are the storage flags parsed by the dispatch; they are
# forwarded to resolve_agent_storage only AFTER argument validation, so bad
# input fails cleanly without the storage auto-detection hint. --dry-run
# previews host files only and never resolves storage (needs no runtime).
_agent_add() {
  local want_dind="$1" want_pind="$2"; shift 2
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

  # Dry-run previews host files only — no runtime/storage needed, so return
  # before resolving storage (which would otherwise print the auto-detect hint).
  if [[ "$dry" == true ]]; then
    local name src dest kind mode resolved
    for name in "${targets[@]}"; do
      resolved="$(_agent_resolve "$name")"
      if [[ -z "$resolved" ]]; then
        echo "  ${name}: no source files found on host."
        continue
      fi
      while IFS=$'\t' read -r src dest kind mode; do
        [[ -n "$src" ]] || continue
        local from=""
        [[ "$src" == "$AGENT_KEYCHAIN_CLAUDE_SRC" ]] && from=" [from macOS Keychain]"
        if [[ "$mode" == 0600 ]]; then
          echo "  ${name}: would copy ${dest} (mode 0600)${from}"
        else
          echo "  ${name}: would copy ${dest}${from}"
        fi
      done <<< "$resolved"
      if [[ "$name" == claude ]]; then
        echo "  ${name}: would set hasCompletedOnboarding in ~/.claude.json (skips login wizard)"
      fi
    done
    return 0
  fi

  # Args are valid — resolve the target storage (may print a hint) and inject.
  resolve_agent_storage "$want_dind" "$want_pind"
  local name
  for name in "${targets[@]}"; do
    _agent_copy_into_volume "$name"
  done
  echo "Done. Injected into ${HOME_VOLUME}. Re-run 'dev agent add' to refresh;"
  echo "'dev agent rm' or 'dev reset' to remove."
}
