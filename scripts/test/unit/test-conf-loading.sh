#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_CI_TEST_MODE=1 . "$ROOT/scripts/test/run-in-vm.sh"

TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT

# Good conf -> all vars populated.
cat > "$TMPDIR/good.conf" <<'EOF'
IMAGE_URL="https://example.invalid/x.qcow2"
IMAGE_SHA256="abc123"
CLOUD_USER="fedora"
PACKAGES="docker rsync"
PACKAGE_INSTALL_CMD="dnf install -y"
POST_BOOT_CMDS="setenforce 1"
EOF

load_distro_conf "$TMPDIR/good.conf"
[ "$IMAGE_URL" = "https://example.invalid/x.qcow2" ] || { echo "IMAGE_URL=$IMAGE_URL"; exit 1; }
[ "$IMAGE_SHA256" = "abc123" ] || { echo "IMAGE_SHA256=$IMAGE_SHA256"; exit 1; }
[ "$CLOUD_USER" = "fedora" ] || exit 1
[ "$PACKAGES" = "docker rsync" ] || exit 1
[ "$PACKAGE_INSTALL_CMD" = "dnf install -y" ] || exit 1
[ "$POST_BOOT_CMDS" = "setenforce 1" ] || exit 1

# Missing required var -> fail with clear message.
cat > "$TMPDIR/bad.conf" <<'EOF'
IMAGE_URL="https://example.invalid/x.qcow2"
CLOUD_USER="fedora"
PACKAGES="docker"
PACKAGE_INSTALL_CMD="dnf install -y"
EOF
if out=$(load_distro_conf "$TMPDIR/bad.conf" 2>&1); then
    echo "expected missing IMAGE_SHA256 to fail"; exit 1
fi
echo "$out" | grep -q 'IMAGE_SHA256' || { echo "expected IMAGE_SHA256 in error: $out"; exit 1; }

# Missing optional POST_BOOT_CMDS -> ok, var is empty.
cat > "$TMPDIR/no-extra.conf" <<'EOF'
IMAGE_URL="https://example.invalid/x.qcow2"
IMAGE_SHA256="abc"
CLOUD_USER="debian"
PACKAGES="docker"
PACKAGE_INSTALL_CMD="apt install -y"
EOF
load_distro_conf "$TMPDIR/no-extra.conf"
[ -z "${POST_BOOT_CMDS:-}" ] || { echo "POST_BOOT_CMDS should be empty"; exit 1; }

# Missing file -> fail.
if load_distro_conf "$TMPDIR/nope.conf" 2>/dev/null; then
    echo "expected missing file to fail"; exit 1
fi

echo "ok"
