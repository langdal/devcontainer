#!/bin/bash
# scripts/test/scenarios/27-mise-install-allowlist-hint.sh
# platform: linux
#
# A project mise tool whose download host lives only in the workspace
# .devcontainer-allowlist is blocked by the firewall until that allowlist is
# approved on the host, and mise install then fails silently -- leaving the
# tool off PATH with no obvious cause (the java-not-on-PATH trap). Verify the
# entrypoint connects the dots: on a failed install with an UNAPPROVED project
# allowlist it prints the actionable NOTE, and on an APPROVED run it does not.
#
# The failure is forced with a bogus tool version so the test is deterministic
# and does not depend on any specific host being (un)reachable.
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

# Isolated throwaway workspace so we never touch this repo's mise.toml.
WS_DIR="$(mktemp -d)"
WS="$(basename "$WS_DIR")"
N="dev-${WS}"
remember_container "$N"
STATE_GLOB="${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WS}-*"

# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() {
    "$RUNTIME" rm -f "$N" 2>/dev/null
    "$RUNTIME" volume rm "devcontainer-home-${WS}" 2>/dev/null
    # shellcheck disable=SC2086  # intentional glob
    rm -rf $STATE_GLOB
    rm -rf "$WS_DIR"
}
trap 'cleanup_extra; restore_host' EXIT

# A tool version that cannot resolve -> mise install exits non-zero, and a
# project allowlist whose host is not in allowlist.base.
cat > "$WS_DIR/mise.toml" <<'EOF'
[tools]
java = "999.0.0"
EOF
echo "download.java.net" > "$WS_DIR/.devcontainer-allowlist"

NOTE='was NOT'   # distinctive fragment of the entrypoint hint

# --- Unapproved: hint MUST appear -----------------------------------------
# shellcheck disable=SC2086  # intentional glob
rm -rf $STATE_GLOB
"$RUNTIME" rm -f "$N" 2>/dev/null
out=$(cd "$WS_DIR" && "$DEV" -- true </dev/null 2>&1)
if ! echo "$out" | grep -q "$NOTE"; then
    log_fail "unapproved-allowlist install failure did not print the actionable NOTE"
    echo "$out" | tail -20 >&2
    exit 1
fi
"$RUNTIME" rm -f "$N" 2>/dev/null

# --- Approved: install still fails (bogus version) but hint must NOT appear -
# shellcheck disable=SC2086  # intentional glob
rm -rf $STATE_GLOB
out=$(cd "$WS_DIR" && DEV_ASSUME_YES=1 "$DEV" -- true 2>&1)
if echo "$out" | grep -q "$NOTE"; then
    log_fail "approved allowlist run still printed the unapproved-allowlist NOTE"
    echo "$out" | tail -20 >&2
    exit 1
fi

log_pass "entrypoint flags an unapproved project allowlist as a likely mise-install cause"
exit 0
