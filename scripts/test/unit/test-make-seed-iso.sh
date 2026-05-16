#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

if ! command -v xorriso >/dev/null 2>&1 \
    && ! command -v mkisofs >/dev/null 2>&1 \
    && ! command -v genisoimage >/dev/null 2>&1 \
    && ! command -v cloud-localds >/dev/null 2>&1; then
    echo "skip: no ISO tool installed"
    exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/seed"
cat > "$TMP/seed/user-data" <<'EOF'
#cloud-config
hostname: test
EOF
cat > "$TMP/seed/meta-data" <<EOF
instance-id: test
local-hostname: test
EOF

make_seed_iso "$TMP/seed.iso" "$TMP/seed"
[ -s "$TMP/seed.iso" ] || { echo "iso empty"; exit 1; }
file "$TMP/seed.iso" | grep -qiE 'ISO 9660|UDF' || {
    echo "not an ISO: $(file "$TMP/seed.iso")"; exit 1
}

# Missing user-data must fail loudly.
rm "$TMP/seed/user-data"
if out=$(make_seed_iso "$TMP/seed-bad.iso" "$TMP/seed" 2>&1); then
    echo "expected missing user-data to fail"; exit 1
fi
echo "$out" | grep -q 'user-data and meta-data' \
    || { echo "expected diagnostic about user-data/meta-data, got: $out"; exit 1; }

# Missing seed directory must fail loudly.
if make_seed_iso "$TMP/seed-bad.iso" "$TMP/no-such-dir" 2>/dev/null; then
    echo "expected missing seed dir to fail"; exit 1
fi

echo "ok"
