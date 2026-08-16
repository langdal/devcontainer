# shellcheck shell=bash
# lib/dev/doctor.sh — the `dev doctor` verb: run every applicable host check
# and print one screen naming each problem and its fix.
#
# Must work on a machine where NOTHING is set up: no image, no container, no
# running podman machine. That is the whole point — it is the first command a
# colleague runs on an unfamiliar laptop.
# Sourced by dev; not executed directly.

# Glyphs. Non-tty output stays ASCII because this report gets pasted into
# chat when someone asks for help.
_doc_glyph() {
  local state="$1"
  if [[ -t 1 ]]; then
    case "$state" in
      pass) printf '\033[32m✓\033[0m' ;;
      fail) printf '\033[31m✗\033[0m' ;;
      advise) printf '\033[33m!\033[0m' ;;
      *) printf '–' ;;
    esac
  else
    case "$state" in
      pass) printf 'ok  ' ;;
      fail) printf 'FAIL' ;;
      advise) printf 'warn' ;;
      *) printf 'n/a ' ;;
    esac
  fi
}

# First N.N.N-shaped token in a --version banner ("Docker version 29.1.3,
# build ..." / "podman version 5.7.0"), or empty. Pipe through head so a
# no-match (grep exit 1) never trips the caller's `set -e`.
_doc_cli_ver() {
  echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# The first "{Name Version map[...]}" component of _engine_server_name's raw
# Server.Components dump, e.g. "[{Podman Engine 5.7.0 map[...]}]" ->
# "Podman Engine 5.7.0". Pure parameter expansion (no regex engine, no
# subshell): safe even though later components (OCI Runtime) can contain
# embedded newlines, because none of that text appears before the first
# "map[" this strips down to.
_doc_engine_ver() {
  local raw="$1" head
  [[ -z "$raw" ]] && return 0
  head="${raw%%map[*}"
  head="${head#\[\{}"
  head="${head% }"
  echo "$head"
}

# Host / Runtime / Workspace header. Only called once a runtime CLI is known
# to exist and detect_runtime has run, so $RUNTIME is always set here.
# Degrades gracefully: any field this cannot determine (no engine reachable,
# version banner didn't parse) is simply omitted, never printed as "unknown".
# Host and Workspace never depend on a runtime, so they are printable even on
# a machine where none exists. Split out so the no-runtime path can reuse them.
_doc_host_line() {
  printf 'Host      %s %s, %s\n' "$1" "$(uname -r 2>/dev/null)" "$(uname -m 2>/dev/null)"
}

_doc_header() {
  local os="$1"
  _doc_host_line "$os"

  local cli_ver engine_raw engine_ver line="$RUNTIME"
  cli_ver="$(_doc_cli_ver "$(_runtime_version)")"
  [[ -n "$cli_ver" ]] && line="$line (CLI $cli_ver)"
  engine_raw="$(_engine_server_name)"
  engine_ver="$(_doc_engine_ver "$engine_raw")"
  [[ -n "$engine_ver" ]] && line="$line -> $engine_ver"
  if runtime_is_rootless; then
    line="$line, rootless"
  fi
  printf 'Runtime   %s\n' "$line"

  local ws image_state=""
  ws="$(basename "$(pwd)")"
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  if $RUNTIME $RUNTIME_ARGS info >/dev/null 2>&1; then
    # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
    if $RUNTIME $RUNTIME_ARGS image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
      image_state="built"
    else
      image_state="not built"
    fi
  fi
  if [[ -n "$image_state" ]]; then
    printf 'Workspace %s  (image: %s)\n' "$ws" "$image_state"
  else
    printf 'Workspace %s\n' "$ws"
  fi
}

cmd_doctor() {
  NESTED=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dind|--pind) NESTED=true; shift ;;
      *) echo "Error: unknown option for 'dev doctor': $1" >&2
         echo "Usage: dev doctor [--dind|--pind]" >&2
         exit 2 ;;
    esac
  done

  # Phase 0 runs before a runtime is known.
  local os
  os="$(_host_os)"
  local blocking=0 advisories=0 passed=0 na=0

  _report_one() {
    local id="$1" sev="$2" title="$3"
    run_check "$id"
    local shown="$CHECK_STATE"
    if [[ "$CHECK_STATE" == fail && "$sev" == advise ]]; then
      shown=advise; advisories=$((advisories + 1))
    elif [[ "$CHECK_STATE" == fail && "$sev" == block-if-nested && "$NESTED" != true ]]; then
      shown=advise; advisories=$((advisories + 1))
    elif [[ "$CHECK_STATE" == fail ]]; then
      # Covers plain 'block' and 'block-in-doctor' alike: doctor is a
      # readiness report, so a host that cannot build an image is never
      # "ready" here — unlike cmd_start, which never blocks on this severity
      # because lib/dev/image.sh's runtime_build already guards the real
      # build site with the same probe. checks_select's 'blocking' filter
      # (cmd_start's only consumer) drops block-in-doctor entirely; doctor
      # calls checks_select with filter=all, so it reaches this generic
      # fail branch instead of either special case above.
      blocking=$((blocking + 1))
    elif [[ "$CHECK_STATE" == pass ]]; then
      passed=$((passed + 1))
    else
      na=$((na + 1))
    fi
    printf '  %s  %s\n' "$(_doc_glyph "$shown")" "$title"
    if [[ "$shown" == fail || "$shown" == advise ]]; then
      local fixfn
      fixfn="_chk_$(echo "$id" | tr '-' '_')_fix"
      if command -v "$fixfn" >/dev/null 2>&1; then
        # `s/^./       &/` not `s/^/       /`: the latter indents blank
        # lines too, leaving trailing whitespace in every gap.
        "$fixfn" | sed 's/^./       &/'
      fi
    fi
  }

  _doc_phase0() {
    local id entry
    for id in $(checks_select 0 all "$os" ""); do
      for entry in "${CHECKS[@]}"; do
        [[ "$(check_field "$entry" 1)" == "$id" ]] || continue
        _report_one "$id" "$(check_field "$entry" 4)" "$(check_field "$entry" 5)"
      done
    done
  }

  # The header (Host/Runtime/Workspace) needs detect_runtime, which cannot
  # run until phase 0 has established that a runtime exists at all — but the
  # header still belongs above every check result. Buffer phase 0's report
  # lines into a plain file (a brace group, not a subshell, so _report_one's
  # tally increments above land in THIS shell) and flush them after the
  # header prints.
  # True unless a phase-0 check that detect_runtime would refuse on has
  # explicitly FAILED. `na` means "nothing to validate", which is fine.
  _doc_runtime_identifiable() {
    local id
    for id in runtime-present dev-runtime-valid; do
      run_check "$id"
      [[ "$CHECK_STATE" == fail ]] && return 1
    done
    return 0
  }

  local phase0_buf
  phase0_buf="$(mktemp 2>/dev/null)" || phase0_buf=""
  if [[ -n "$phase0_buf" ]]; then
    { _doc_phase0; } > "$phase0_buf"
  else
    _doc_phase0   # mktemp unavailable: fall back to printing immediately
  fi

  # Only now is it safe to identify the runtime — and only if every phase-0
  # condition detect_runtime would refuse on has passed. detect_runtime exits
  # rather than returning, so calling it on a host it rejects would abandon the
  # report mid-flight: no header, no rows, no tally, on precisely the
  # unconfigured machines doctor exists to diagnose.
  #
  # Test the probes through run_check, NOT by calling them directly: a probe
  # returns 0/1/2, and 2 ("not applicable") is falsy in bash. Calling
  # _chk_dev_runtime_valid in a boolean context would read its perfectly
  # healthy "no DEV_RUNTIME set, nothing to validate" as a failure and skip
  # phase 1 on every ordinary host. Only an explicit `fail` should stop us.
  if _doc_runtime_identifiable; then
    detect_runtime
    _doc_header "$os"
    [[ -n "$phase0_buf" ]] && cat "$phase0_buf"
    for id in $(checks_select 1 all "$os" "$RUNTIME"); do
      for entry in "${CHECKS[@]}"; do
        [[ "$(check_field "$entry" 1)" == "$id" ]] || continue
        _report_one "$id" "$(check_field "$entry" 4)" "$(check_field "$entry" 5)"
      done
    done
  else
    # detect_runtime cannot run here (it exits rather than returns), but the
    # Host and Workspace lines never needed it. Without them the report opened
    # mid-table, with no record of which OS, kernel, arch or directory produced
    # it -- on precisely the unconfigured machine whose report gets pasted into
    # a bug thread. Found by CI's bare-macOS runner, which has no podman at all.
    _doc_host_line "$os"
    printf 'Runtime   none detected\n'
    printf 'Workspace %s\n' "$(basename "$(pwd)")"
    [[ -n "$phase0_buf" ]] && cat "$phase0_buf"
  fi
  [[ -n "$phase0_buf" ]] && rm -f "$phase0_buf"

  # --dind/--pind promise to check nested prerequisites, but every
  # block-if-nested check is scoped linux:* -- unprivileged userns, the subuid
  # grant, /dev/fuse, cgroup v2 are all properties of a LINUX host. On macOS
  # the nested engine runs inside the podman machine VM, so none of them apply
  # to the Mac itself and the report would otherwise print "0 blocking" having
  # verified nothing at all about nested readiness. Silence reading as approval
  # is the failure mode this whole registry exists to prevent, so say it.
  if [[ "$NESTED" == true ]]; then
    local _n_entry _n_seen=false
    for _n_entry in "${CHECKS[@]}"; do
      [[ "$(check_field "$_n_entry" 4)" == block-if-nested ]] || continue
      check_applies "$(check_field "$_n_entry" 3)" "$os" "${RUNTIME:-}" || continue
      _n_seen=true
      break
    done
    if [[ "$_n_seen" != true ]]; then
      printf '  %s  %s\n' "$(_doc_glyph na)" "nested prerequisites not checkable on $os"
      printf '       They are properties of a Linux host; here the nested engine runs\n'
      printf '       inside the podman machine VM. --dind/--pind readiness is NOT\n'
      printf '       verified by this report.\n'
      na=$((na + 1))
    fi
  fi

  echo
  printf '%d blocking, %d advisory, %d passed, %d not applicable\n' \
    "$blocking" "$advisories" "$passed" "$na"
  [[ "$blocking" -eq 0 ]] || exit 1
  exit 0
}
