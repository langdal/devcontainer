#!/bin/bash
# scripts/test/scenarios/56-global-mise-config.sh
# platform: linux
# privilege: user
#
# A host-side global mise config (${XDG_CONFIG_HOME}/devcontainer/mise.toml)
# is mounted read-only at /mise/conf.d/user.toml and applies to every
# workspace. Verify, in a workspace with NO project mise.toml (so only the
# global config can trigger the entrypoint's mise install), that:
#   - its tools are installed at startup and override the baked base version,
#   - its [env] is exported, i.e. mise loads it as global config,
#   - the agent cannot modify it.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
DEV="$(pwd)/dev"

WS_DIR="$(mktemp -d)"
WS="$(basename "$WS_DIR")"
N="dev-${WS}"
remember_container "$N"
XDG="$(mktemp -d)"

# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() {
    "$RUNTIME" rm -f "$N" 2>/dev/null
    "$RUNTIME" volume rm "devcontainer-home-${WS}" 2>/dev/null
    rm -rf "$WS_DIR" "$XDG"
}
trap 'cleanup_extra; restore_host' EXIT

# ripgrep is a baked base tool, so pinning another version also proves the
# global config takes precedence over /mise/config.toml.
mkdir -p "$XDG/devcontainer"
cat > "$XDG/devcontainer/mise.toml" <<'EOF'
[tools]
ripgrep = "14.1.1"

[env]
DEV_GLOBAL_MISE_PROBE = "loaded"
EOF

# shellcheck disable=SC2016  # runs in the container shell, not the host
out=$(cd "$WS_DIR" && XDG_CONFIG_HOME="$XDG" "$DEV" exec -- bash -ic '
    echo "PROBE:$DEV_GLOBAL_MISE_PROBE"
    rg --version | head -1
    touch /mise/conf.d/user.toml 2>/dev/null && echo WRITABLE || echo READONLY
' </dev/null 2>&1)

echo "$out" | grep -q 'PROBE:loaded' \
    || { log_fail "global mise config [env] not loaded"; echo "$out" | tail -20 >&2; exit 1; }
echo "$out" | grep -q 'ripgrep 14.1.1' \
    || { log_fail "global mise config tool not installed or not overriding base"; echo "$out" | tail -20 >&2; exit 1; }
echo "$out" | grep -q 'READONLY' \
    || { log_fail "global mise config is writable from inside the container"; echo "$out" | tail -20 >&2; exit 1; }

log_pass "global mise config is mounted read-only, loaded, and its tools installed"
exit 0
