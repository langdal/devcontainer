#!/bin/bash
# scripts/test/scenarios/25-private-registry-allowlist.sh
# platform: linux
# privilege: user
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
D="dev-${WS}-dind"
remember_container "$D"
"$RUNTIME" rm -f "$D" 2>/dev/null

# Add a fake "private registry" hostname to .devcontainer-allowlist for
# the duration of this scenario. We are NOT going to actually pull from
# it — just verify the merged tinyproxy filter contains an anchored regex
# for the new hostname.
ALLOWLIST=".devcontainer-allowlist"
SENTINEL="harbor-test-$(date +%s).example.com"

# Snapshot existing allowlist if any.
if [ -f "$ALLOWLIST" ]; then
    cp "$ALLOWLIST" "$ALLOWLIST.bak"
fi
echo "$SENTINEL" >> "$ALLOWLIST"

# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() {
    if [ -f "$ALLOWLIST.bak" ]; then
        mv "$ALLOWLIST.bak" "$ALLOWLIST"
    else
        rm -f "$ALLOWLIST"
    fi
    rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WS}"-*/allowlist.approved
}
# Add to the existing trap.
trap 'cleanup_extra; restore_host' EXIT

# DEV_EGRESS=closed: this scenario inspects tinyproxy's filter file, which
# only exists in closed mode -- open mode (the default since the
# egress-open work) runs no tinyproxy at all. Pinned the same way as
# scenario 26.
filter=$(DEV_ASSUME_YES=1 DEV_EGRESS=closed ./dev exec --dind -- cat /etc/tinyproxy/filter 2>&1) \
    || { log_fail "could not read /etc/tinyproxy/filter inside container"; exit 1; }

escaped="${SENTINEL//./\\\\.}"
if echo "$filter" | grep -Eq "^\\^${escaped}\\\$$"; then
    log_pass ".devcontainer-allowlist entry merged into the DinD filter"
    exit 0
fi
log_fail "expected anchored regex for $SENTINEL in filter; filter was:"
echo "$filter" >&2
exit 1
