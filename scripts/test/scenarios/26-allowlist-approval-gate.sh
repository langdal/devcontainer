#!/bin/bash
# scripts/test/scenarios/26-allowlist-approval-gate.sh
# platform: linux
# privilege: user
#
# The workspace allowlist is agent-writable. Verify an entry added WITHOUT
# host-side approval never reaches the tinyproxy filter, and that the same
# entry IS merged once approved (DEV_ASSUME_YES=1 stands in for the prompt).
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
N="dev-${WS}"
remember_container "$N"
"$RUNTIME" rm -f "$N" 2>/dev/null

ALLOWLIST=".devcontainer-allowlist"
SENTINEL="approval-gate-$(date +%s).example.com"
if [ -f "$ALLOWLIST" ]; then
    cp "$ALLOWLIST" "$ALLOWLIST.bak"
fi
# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() {
    if [ -f "$ALLOWLIST.bak" ]; then
        mv "$ALLOWLIST.bak" "$ALLOWLIST"
    else
        rm -f "$ALLOWLIST"
    fi
    rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WS}"-*/allowlist.approved
}
trap 'cleanup_extra; restore_host' EXIT

# Simulate the agent extending its own allowlist: write the entry and start
# non-interactively with NO approval (fresh state, DEV_ASSUME_YES unset).
# DEV_EGRESS=closed: the filter this scenario inspects is tinyproxy's, which
# only runs in closed mode -- open mode (the default since the egress-open
# work) has no tinyproxy filter file at all.
echo "$SENTINEL" >> "$ALLOWLIST"
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WS}"-*/allowlist.approved

filter=$(DEV_EGRESS=closed ./dev exec -- cat /etc/tinyproxy/filter </dev/null 2>&1) \
    || { log_fail "could not read filter (unapproved run)"; exit 1; }
escaped="${SENTINEL//./\\\\.}"
if echo "$filter" | grep -Eq "^\\^${escaped}\\\$$"; then
    log_fail "UNAPPROVED workspace allowlist entry reached the filter"
    exit 1
fi
"$RUNTIME" rm -f "$N" 2>/dev/null

# Same entry, approved -> merged.
filter=$(DEV_EGRESS=closed DEV_ASSUME_YES=1 ./dev exec -- cat /etc/tinyproxy/filter 2>&1) \
    || { log_fail "could not read filter (approved run)"; exit 1; }
if ! echo "$filter" | grep -Eq "^\\^${escaped}\\\$$"; then
    log_fail "approved allowlist entry missing from filter"
    exit 1
fi
log_pass "workspace allowlist requires host-side approval before reaching the filter"
exit 0
