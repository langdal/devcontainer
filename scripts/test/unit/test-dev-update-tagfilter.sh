#!/usr/bin/env bash
# Unit: the prerelease-tag filter in lib/dev/update.sh's self_update().
#
# self_update() picks the update target via:
#   git ls-remote --sort='version:refname' origin | awk -F/ '{print $NF}' \
#     | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | tail -1
# There's no local remote to ls-remote here, so this test stands in for the
# remote-side `--sort='version:refname'` step with a local `sort -V` (the
# closest local equivalent for plain semver-ish refs) and then applies the
# EXACT SAME grep+tail update.sh uses. If update.sh's filter regex or the
# tail stage ever changes, this test must be updated to match — read
# lib/dev/update.sh's self_update() before editing either.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

filter_line="$(grep -n "grep -E '\^v?\[0-9\]" "$ROOT/lib/dev/update.sh")"
[ -n "$filter_line" ] || { echo "update.sh no longer contains the expected prerelease filter"; exit 1; }

# Fixture mirrors what `git ls-remote --tags --refs` would emit for tag
# names after `awk -F/ '{print $NF}'` has already stripped the refs/tags/
# prefix — i.e. bare tag names, not yet sorted or filtered.
fixture='v1.0.0
v1.1.0-rc.1
v1.0.1
v1.2.0-beta.2'

latest="$(printf '%s\n' "$fixture" \
  | sort -V \
  | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
  | tail -1)"

if [ "$latest" != "v1.0.1" ]; then
    echo "expected v1.0.1 (highest STABLE tag), got: $latest"
    exit 1
fi

# Sanity: without the filter, the rc/beta tags would corrupt the pick —
# confirms the fixture actually exercises the bug install.sh/update.sh guard
# against, not just an already-sorted trivial case.
unfiltered="$(printf '%s\n' "$fixture" | sort -V | tail -1)"
if [ "$unfiltered" = "v1.0.1" ]; then
    echo "fixture does not exercise the prerelease bug (unfiltered already gave v1.0.1)"
    exit 1
fi

echo ok
