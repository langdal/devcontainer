# shellcheck shell=bash
# lib/dev/agent.sh — `dev agent {add,list,rm}` handlers. Copy a curated,
# per-agent allowlist of credentials + settings from the host into this
# workspace's home volume. One-way snapshot: never a host mount, never baked
# into an image. Sourced by dev; not executed directly.

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

# `dev agent add claude --auth token` injects a long-lived OAuth token (from
# `claude setup-token`) at this dest instead of snapshotting the host's
# .credentials.json. entrypoint.sh exports it as CLAUDE_CODE_OAUTH_TOKEN,
# which Claude checks before the credentials file — so the token keeps
# working even when refresh-token rotation invalidates a snapshot.
CLAUDE_TOKEN_DEST='.claude/.devcontainer-oauth-token'
CLAUDE_TOKEN_PREFIX='sk-ant-oat01-'

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

# _agent_require_image: fail clearly if the helper image is not built yet.
# The agent helpers (copy/probe/rm) all run this image; the dev agent path
# never builds it (unlike the start path), so check before any helper run.
_agent_require_image() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if ! $RUNTIME $RUNTIME_ARGS image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Error: image '$IMAGE_TAG' is not built yet. Run './dev --build' (or start the container once with './dev') first." >&2
    exit 1
  fi
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
  # host user before we write (reuses lifecycle.sh's one-time migration).
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

# _agent_claude_auth_prompt: interactively choose the claude auth method.
# Prints "creds" or "token" on stdout; prompts on stderr so callers can
# capture the choice. Only called when stdin is a tty and no --auth flag or
# DEV_ASSUME_YES already decided.
_agent_claude_auth_prompt() {
  local reply
  cat >&2 <<'EOF'
claude: two ways to authenticate inside the container:
  1) credentials snapshot — copy ~/.claude/.credentials.json from this host.
     Quick, but OAuth refresh-token rotation can invalidate the copy whenever
     another machine (or the host itself) refreshes first, forcing /login.
  2) long-lived token — mint one with 'claude setup-token' (browser sign-in)
     and inject it as CLAUDE_CODE_OAUTH_TOKEN. Stable across machines and
     workspaces; unaffected by rotation.
EOF
  while true; do
    read -r -p "Auth method for claude [1/2] (default 1): " reply
    case "$reply" in
      ''|1) echo creds; return 0 ;;
      2)    echo token; return 0 ;;
      *)    echo "Please answer 1 or 2." >&2 ;;
    esac
  done
}

# _agent_claude_token_acquire <out_file>: obtain a long-lived token and write
# it (no trailing newline) to <out_file> with mode 0600. Interactive path
# (tty): offer to run `claude setup-token` attached to the terminal, then
# read the pasted token silently. Non-tty path (scripted `--auth token`):
# read one line from stdin. Validates the sk-ant-oat01- prefix; returns 1 on
# empty/malformed input.
_agent_claude_token_acquire() {
  local out_file="$1" tok="" reply
  if [[ -t 0 ]]; then
    if command -v claude >/dev/null 2>&1; then
      read -r -p "Run 'claude setup-token' now to mint a token? [Y/n] " reply
      case "$reply" in
        n|N|no|NO) ;;
        *) claude setup-token || {
             echo "  claude: 'claude setup-token' failed; paste an existing token or retry." >&2
           } ;;
      esac
    else
      echo "  claude: no 'claude' CLI on this host — run 'claude setup-token' wherever" >&2
      echo "  Claude Code is installed and paste the token it prints." >&2
    fi
    read -rs -p "Paste the token (input hidden): " tok
    echo >&2
  else
    # Scripted: token arrives on stdin (e.g. printf '%s\n' "$TOK" | dev agent
    # add claude --auth token).
    IFS= read -r tok || true
  fi
  # Strip whitespace/CR the paste may carry; tokens themselves contain none.
  tok="${tok//[$'\r\n\t ']/}"
  if [[ -z "$tok" ]]; then
    echo "Error: no token provided." >&2
    return 1
  fi
  if [[ "$tok" != "$CLAUDE_TOKEN_PREFIX"* ]]; then
    echo "Error: that does not look like a 'claude setup-token' token (expected" >&2
    echo "       prefix ${CLAUDE_TOKEN_PREFIX}...). Not injecting it." >&2
    return 1
  fi
  (umask 077 && printf '%s' "$tok" > "$out_file")
}

# _agent_copy_into_volume <name> [auth_method] [token_file]: resolve an
# agent's manifest to existing host sources and inject them into the workspace
# home volume via _stage_and_extract, then apply the claude-only
# onboarding-flag follow-up. auth_method (claude only) is "creds" (default,
# snapshot .credentials.json) or "token" (skip the credentials snapshot and
# inject token_file at CLAUDE_TOKEN_DEST instead).
_agent_copy_into_volume() {
  local name="$1" auth_method="${2:-creds}" token_file="${3:-}" resolved
  resolved="$(_agent_resolve "$name")"
  if [[ "$name" == claude && "$auth_method" == token ]]; then
    # Drop the credentials snapshot (file or macOS Keychain sentinel — both
    # carry DEST .claude/.credentials.json) and inject the token instead.
    resolved="$(awk -F'\t' '$2 != ".claude/.credentials.json"' <<< "$resolved")"
    resolved+="${resolved:+$'\n'}$(printf '%s\t%s\t%s\t%s' \
      "$token_file" "$CLAUDE_TOKEN_DEST" file 0600)"
  fi
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
    [[ "$(_agent_keepid)" == true ]] && keepid_args=(--userns=keep-id)
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

# _agent_volume_exists: 0 if the workspace home volume exists.
_agent_volume_exists() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME $RUNTIME_ARGS volume inspect "$HOME_VOLUME" >/dev/null 2>&1
}

# _agent_all_dests <name>: print every manifest DEST_REL for the agent
# (independent of whether the source exists on the host). For claude the
# token-method dest is included too, so `list` counts it as injected and
# `rm` removes it alongside the snapshot files.
_agent_all_dests() {
  local src_rel dest_rel kind mode
  while IFS=$'\t' read -r src_rel dest_rel kind mode; do
    [[ -n "$dest_rel" ]] && printf '%s\n' "$dest_rel"
  done < <(_agent_manifest "$1")
  if [[ "$1" == claude ]]; then
    printf '%s\n' "$CLAUDE_TOKEN_DEST"
  fi
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
  [[ "$(_agent_keepid)" == true ]] && keepid_args=(--userns=keep-id)
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
  [[ "$(_agent_keepid)" == true ]] && keepid_args=(--userns=keep-id)

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

For claude, 'add' offers two auth methods (pick interactively or pass
--auth creds|token):
  creds   snapshot ~/.claude/.credentials.json (default; non-interactive
          runs use this). Refresh-token rotation on another machine can
          invalidate the copy, forcing /login inside the container.
  token   inject a long-lived token from 'claude setup-token' as
          CLAUDE_CODE_OAUTH_TOKEN (exported by the container entrypoint).
          Stable across machines; needs a rebuilt image (dev --build) if
          yours predates this feature. Scripted use: pipe the token on
          stdin: printf '%s\n' "$TOK" | dev agent add claude --auth token

For a container started with 'dev --dind' or 'dev --pind', pass the matching
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
  local dry=false auth_flag=""
  local -a raw=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=true; shift ;;
      --auth)
        auth_flag="${2:-}"
        [[ $# -ge 2 ]] || { echo "Error: dev agent add: --auth needs a value (creds|token)" >&2; exit 1; }
        shift 2 ;;
      --auth=*) auth_flag="${1#--auth=}"; shift ;;
      --) shift ;;
      -*) echo "Error: dev agent add: unknown option: $1" >&2; exit 1 ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  if [[ -n "$auth_flag" && "$auth_flag" != creds && "$auth_flag" != token ]]; then
    echo "Error: dev agent add: --auth must be 'creds' or 'token', got '$auth_flag'" >&2
    exit 1
  fi
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

  # --auth only changes the claude flow; reject it when claude is not among
  # the targets so a typo'd invocation fails loudly instead of no-opping.
  local claude_targeted=false name
  for name in "${targets[@]}"; do
    [[ "$name" == claude ]] && claude_targeted=true
  done
  if [[ -n "$auth_flag" && "$claude_targeted" == false ]]; then
    echo "Error: dev agent add: --auth only applies to the claude agent." >&2
    exit 1
  fi

  # Dry-run previews host files only — no runtime/storage needed, so return
  # before resolving storage (which would otherwise print the auto-detect
  # hint). Never prompts: without --auth it previews the creds default.
  if [[ "$dry" == true ]]; then
    local src dest kind mode resolved
    for name in "${targets[@]}"; do
      resolved="$(_agent_resolve "$name")"
      if [[ "$name" == claude && "$auth_flag" == token ]]; then
        resolved="$(awk -F'\t' '$2 != ".claude/.credentials.json"' <<< "$resolved")"
        echo "  ${name}: would inject ${CLAUDE_TOKEN_DEST} (mode 0600) [long-lived token via 'claude setup-token']"
      elif [[ -z "$resolved" ]]; then
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

  # Claude auth method: explicit flag wins; otherwise prompt on a tty.
  # Non-interactive (DEV_ASSUME_YES / no tty) defaults to the credentials
  # snapshot — the historical behavior, so scripts are unaffected.
  local claude_auth="$auth_flag"
  if [[ "$claude_targeted" == true && -z "$claude_auth" ]]; then
    if [[ "${DEV_ASSUME_YES:-}" == 1 || ! -t 0 ]]; then
      claude_auth=creds
    else
      claude_auth="$(_agent_claude_auth_prompt)"
    fi
  fi

  # Token method: obtain the token up front so a failed/aborted paste stops
  # everything before any storage is touched.
  local token_tmp=""
  if [[ "$claude_auth" == token ]]; then
    token_tmp="$(mktemp)"
    if ! _agent_claude_token_acquire "$token_tmp"; then
      rm -f "$token_tmp"
      exit 1
    fi
  fi

  # Args are valid — resolve the target storage (may print a hint) and inject.
  resolve_agent_storage "$want_dind" "$want_pind"
  local rc=0
  for name in "${targets[@]}"; do
    if [[ "$name" == claude ]]; then
      _agent_copy_into_volume claude "$claude_auth" "$token_tmp" || rc=$?
    else
      _agent_copy_into_volume "$name" || rc=$?
    fi
  done
  [[ -n "$token_tmp" ]] && rm -f "$token_tmp"
  if [[ "$rc" -eq 0 ]]; then
    echo "Done. Injected into ${HOME_VOLUME}. Re-run 'dev agent add' to refresh;"
    echo "'dev agent rm' or 'dev reset' to remove."
  fi
  return $rc
}
