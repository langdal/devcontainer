#!/usr/bin/env bash
# Verifies that sha256_of works regardless of which underlying tool
# (sha256sum on Linux, shasum on macOS) is available.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo -n "hello qemu world" > "$TMP/data"

# Expected SHA-256 of "hello qemu world" (no trailing newline) computed
# at test-writing time with: printf 'hello qemu world' | sha256sum
EXPECTED="cb4c5488089b0251071ae685442c23c471b15a10b2672493e42073cc5f27b328"
ACTUAL=$(sha256_of "$TMP/data")
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "sha256_of returned unexpected value:"
    echo "  expected: $EXPECTED"
    echo "  actual:   $ACTUAL"
    exit 1
fi

# Round-trip via either backend should match.
if command -v sha256sum >/dev/null 2>&1; then
    DIRECT=$(sha256sum "$TMP/data" | awk '{print $1}')
    [ "$DIRECT" = "$ACTUAL" ] || { echo "sha256sum direct != wrapper"; exit 1; }
fi
if command -v shasum >/dev/null 2>&1; then
    DIRECT=$(shasum -a 256 "$TMP/data" | awk '{print $1}')
    [ "$DIRECT" = "$ACTUAL" ] || { echo "shasum direct != wrapper"; exit 1; }
fi

echo "ok"
