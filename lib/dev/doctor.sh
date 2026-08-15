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
  local os id entry
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
        "$fixfn" | sed 's/^/       /'
      fi
    fi
  }

  for id in $(checks_select 0 all "$os" ""); do
    for entry in "${CHECKS[@]}"; do
      [[ "$(check_field "$entry" 1)" == "$id" ]] || continue
      _report_one "$id" "$(check_field "$entry" 4)" "$(check_field "$entry" 5)"
    done
  done

  # Only now is it safe to identify the runtime.
  if _chk_runtime_present; then
    # shellcheck disable=SC2034  # consumed by ensure_runtime_ready; doctor never calls it, but detect_runtime reads the same global
    NEEDS_ENGINE=false
    detect_runtime
    printf 'Host      %s\n' "$os"
    printf 'Runtime   %s\n' "$RUNTIME"
    for id in $(checks_select 1 all "$os" "$RUNTIME"); do
      for entry in "${CHECKS[@]}"; do
        [[ "$(check_field "$entry" 1)" == "$id" ]] || continue
        _report_one "$id" "$(check_field "$entry" 4)" "$(check_field "$entry" 5)"
      done
    done
  fi

  echo
  printf '%d blocking, %d advisory, %d passed, %d not applicable\n' \
    "$blocking" "$advisories" "$passed" "$na"
  [[ "$blocking" -eq 0 ]] || exit 1
  exit 0
}
