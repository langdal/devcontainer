# shellcheck shell=bash
# lib/dev/update-check.sh — the passive "a newer dev is available" notice
# printed by `dev up` / `dev exec`. Sourced by dev; not executed directly.
#
# Model (the same one npm and oh-my-zsh use): the notice is printed from a
# cached answer, and the cache is refreshed in a detached background job at
# most once per DEV_UPDATE_CHECK_INTERVAL. The start flow therefore never
# waits on the network — offline, behind a closed proxy, or with GitHub down,
# `dev up` is exactly as fast as without the check. The first run after the
# cache goes stale only schedules the refresh; the notice shows on the run
# after that.
#
# Cache file: ${XDG_CACHE_HOME:-~/.cache}/devcontainer/update-check, one line
# "<epoch-of-last-attempt> <latest-stable-tag-or-empty>". The epoch is written
# BEFORE the background ls-remote, so a host that cannot reach origin retries
# once per interval rather than on every invocation.

# Seconds between background refreshes. Overridable for tests.
DEV_UPDATE_CHECK_INTERVAL="${DEV_UPDATE_CHECK_INTERVAL:-86400}"

_update_check_file() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/devcontainer/update-check"
}

# Indirection so the unit test can stand in for a terminal.
_update_check_tty() {
  [[ -t 2 ]]
}

# _update_check_enabled: whether this invocation may print the notice or
# start a refresh. Off when opted out, in CI, for --dry-run (which only
# prints a command and is what the unit/scenario suites drive), when stderr
# is not a terminal (scripts parsing dev's output), and when there is no git
# checkout for `dev update` to act on anyway.
_update_check_enabled() {
  [[ "${DEV_NO_UPDATE_CHECK:-}" != "1" ]] || return 1
  [[ -z "${CI:-}" ]] || return 1
  [[ "$DRY_RUN" != true ]] || return 1
  _update_check_tty || return 1
  command -v git >/dev/null 2>&1 || return 1
  [[ -d "$SCRIPT_DIR/.git" ]]
}

# _version_gt A B: true when semver A is strictly newer than B. A leading `v`
# is ignored. Plain field-by-field integer compare in-shell (no sort
# subprocess on the start path); both sides are already MAJOR.MINOR.PATCH.
_version_gt() {
  local a="${1#v}" b="${2#v}" a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  (( 10#${a1:-0} != 10#${b1:-0} )) && { (( 10#${a1:-0} > 10#${b1:-0} )); return; }
  (( 10#${a2:-0} != 10#${b2:-0} )) && { (( 10#${a2:-0} > 10#${b2:-0} )); return; }
  (( 10#${a3:-0} > 10#${b3:-0} ))
}

# _update_check_refresh FILE: query origin and record the result. Runs in the
# background, still attached to the user's terminal, so nothing may prompt:
# GIT_TERMINAL_PROMPT=0 stops git's HTTPS credential prompt, BatchMode stops
# ssh's host-key/passphrase prompts on an SSH origin (ssh opens /dev/tty
# directly, so the </dev/null redirect alone does not), and the low-speed
# limit abandons a stalled HTTPS fetch instead of leaving it hanging.
_update_check_refresh() {
  local file="$1" latest tmp
  latest="$(GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
    GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10 \
    latest_stable_tag || true)"
  [[ -n "$latest" ]] || return 0
  tmp="$file.$$"
  printf '%s %s\n' "$(date +%s)" "$latest" >"$tmp" && mv -f "$tmp" "$file"
}

# notify_update_available: print the notice from the cache (if it names a
# newer release than this script's $VERSION), then schedule a background
# refresh if the cache is stale. Never fails the caller.
notify_update_available() {
  _update_check_enabled || return 0

  local file checked=0 latest="" now
  file="$(_update_check_file)"
  if [[ -r "$file" ]]; then
    read -r checked latest <"$file" || true
    [[ "$checked" =~ ^[0-9]+$ ]] || checked=0
  fi

  if [[ "$latest" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] && _version_gt "$latest" "$VERSION"; then
    echo "Update available: dev $latest (you have v${VERSION#v}). Run 'dev update' to upgrade." >&2
    echo "  (silence with DEV_NO_UPDATE_CHECK=1)" >&2
  fi

  now="$(date +%s)"
  if (( now - checked >= DEV_UPDATE_CHECK_INTERVAL )); then
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
    printf '%s %s\n' "$now" "$latest" >"$file" 2>/dev/null || return 0
    # Detached from the terminal: no stdin, no output, and start_container's
    # exec into the runtime does not wait for it.
    _update_check_refresh "$file" </dev/null >/dev/null 2>&1 &
  fi
  return 0
}
