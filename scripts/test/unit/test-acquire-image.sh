#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
DEV_CI_CACHE_DIR="$TMPDIR/cache"
export DEV_CI_CACHE_DIR

# Source: a small file we control.
echo "hello qemu world" > "$TMPDIR/src.qcow2"
sha=$(sha256sum "$TMPDIR/src.qcow2" | awk '{print $1}')

# First call: cache miss, downloads.
out=$(acquire_image "file://$TMPDIR/src.qcow2" "$sha" "testdistro")
[ -f "$out" ] || { echo "no output path"; exit 1; }
diff "$out" "$TMPDIR/src.qcow2" || { echo "content mismatch"; exit 1; }

# Second call: cache hit, no download. Make the source unreadable to prove
# the cache was used.
chmod 000 "$TMPDIR/src.qcow2"
out2=$(acquire_image "file://$TMPDIR/src.qcow2" "$sha" "testdistro")
[ "$out" = "$out2" ] || { echo "cache miss on hot path"; exit 1; }
chmod 644 "$TMPDIR/src.qcow2"

# Wrong sha -> fail.
if acquire_image "file://$TMPDIR/src.qcow2" "deadbeef" "testdistro2" 2>/dev/null; then
    echo "expected sha mismatch to fail"; exit 1
fi

# REPLACE_ME -> fail loudly.
if out=$(acquire_image "file://$TMPDIR/src.qcow2" "REPLACE_ME" "x" 2>&1); then
    echo "expected REPLACE_ME to fail"; exit 1
fi
echo "$out" | grep -q REPLACE_ME || { echo "expected REPLACE_ME message"; exit 1; }

echo "ok"
