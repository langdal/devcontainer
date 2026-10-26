#!/usr/bin/env bash
# Unit: the passive update notice in lib/dev/update-check.sh.
#
# Sources the module (plus update.sh for latest_stable_tag) against a fake
# SCRIPT_DIR checkout, a throwaway XDG_CACHE_HOME, and a stub `git` on PATH
# that stands in for `git ls-remote`. _update_check_tty is redefined so the
# terminal gate can be driven both ways without a real tty.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/checkout/.git" "$WORK/bin"
# Stub git: prints a canned ls-remote listing (prerelease included, so the
# shared stable-tag filter is exercised) and logs every call.
cat >"$WORK/bin/git" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$WORK/git-calls"
printf 'abc\trefs/tags/v2.2.1\nabc\trefs/tags/v2.3.0\nabc\trefs/tags/v2.4.0-rc.1\n'
EOF
chmod +x "$WORK/bin/git"
PATH="$WORK/bin:$PATH"

SCRIPT_DIR="$WORK/checkout"
XDG_CACHE_HOME="$WORK/cache"
VERSION="2.2.1"
DRY_RUN=false
unset CI DEV_NO_UPDATE_CHECK
# shellcheck source=lib/dev/update.sh
. "$ROOT/lib/dev/update.sh"
# shellcheck source=lib/dev/update-check.sh
. "$ROOT/lib/dev/update-check.sh"
_update_check_tty() { return 0; }

CACHE="$WORK/cache/devcontainer/update-check"
fail() { echo "$*"; exit 1; }
# Run the notifier, wait for its background refresh, capture stderr.
notify() { notify_update_available 2>"$WORK/err"; wait; cat "$WORK/err"; }

# 1. Version compare: numeric, not lexical; leading v ignored.
_version_gt v2.10.0 2.9.0 || fail "v2.10.0 should be newer than 2.9.0"
_version_gt 2.2.1 v2.2.1 && fail "equal versions must not compare newer"
_version_gt 2.2.0 2.2.1 && fail "older version compared newer"
_version_gt 3.0.0 2.99.99 || fail "major bump not detected"

# 2. No cache yet: silent, but schedules a refresh that records the highest
# STABLE tag (v2.3.0, not the rc).
out=$(notify)
[ -z "$out" ] || fail "first run should be silent, got: $out"
read -r _ cached <"$CACHE"
[ "$cached" = "v2.3.0" ] || fail "refresh cached '$cached', expected v2.3.0"

# 3. Fresh cache naming a newer tag: notice printed, no new git call.
: >"$WORK/git-calls"
out=$(notify)
echo "$out" | grep -q "dev v2.3.0" || fail "expected notice for v2.3.0, got: $out"
echo "$out" | grep -q "you have v2.2.1" || fail "notice lacks current version: $out"
[ -s "$WORK/git-calls" ] && fail "fresh cache still queried origin"

# 4. Already on the latest release: silent.
out=$(VERSION=2.3.0; notify)
[ -z "$out" ] || fail "up-to-date run printed: $out"

# 5. Stale cache: still prints from it, and refreshes in the background.
printf '1 v2.3.0\n' >"$CACHE"
out=$(notify)
echo "$out" | grep -q "dev v2.3.0" || fail "stale cache notice missing: $out"
grep -q ls-remote "$WORK/git-calls" || fail "stale cache did not trigger ls-remote"
read -r checked _ <"$CACHE"
[ "$checked" -gt 1 ] || fail "refresh did not update the timestamp"

# 6. Unreachable origin: the attempt is still stamped (no retry storm) and
# the previously known tag is kept.
printf '#!/usr/bin/env bash\nexit 128\n' >"$WORK/bin/git"
printf '1 v2.3.0\n' >"$CACHE"
notify >/dev/null
read -r checked cached <"$CACHE"
[ "$checked" -gt 1 ] || fail "failed refresh was not stamped"
[ "$cached" = "v2.3.0" ] || fail "failed refresh lost the known tag: '$cached'"

# 7. Every gate silences the notice AND skips the refresh.
printf '1 v9.9.9\n' >"$CACHE"
for gate in "DEV_NO_UPDATE_CHECK=1" "CI=true" "DRY_RUN=true" "tty"; do
  out=$(
    if [ "$gate" = tty ]; then
      _update_check_tty() { return 1; }
    else
      eval "$gate"
    fi
    notify
  )
  [ -z "$out" ] || fail "gate $gate still printed: $out"
  [ "$(cat "$CACHE")" = "1 v9.9.9" ] || fail "gate $gate still refreshed"
done
out=$(SCRIPT_DIR="$WORK/not-a-checkout"; notify)
[ -z "$out" ] || fail "non-git install printed: $out"

# 8. A corrupt cache is ignored rather than tripping arithmetic.
printf 'garbage\n' >"$CACHE"
notify >/dev/null || fail "corrupt cache made the notifier fail"

echo ok
