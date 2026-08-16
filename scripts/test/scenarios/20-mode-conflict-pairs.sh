#!/bin/bash
# scripts/test/scenarios/20-mode-conflict-pairs.sh
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
N="dev-${WS}"; M="dev-${WS}-maint"; D="dev-${WS}-dind"; P="dev-${WS}-pind"
remember_container "$N"; remember_container "$M"; remember_container "$D"; remember_container "$P"

run_bg() {
    nohup "$@" >/dev/null 2>&1 &
    disown
    sleep 4
}

refuse_normal_due_to() {
    local running="$1"
    local out
    if out=$(./dev exec -- true 2>&1); then
        log_fail "normal mode should have refused while $running is running"; return 1
    fi
    # The message is "Error: <label> container <name> is running for this
    # workspace." — so "<name> is running" sit adjacent with a single space.
    # Match that, not "<name> .* is running" which would require filler
    # words between them.
    expect_grep "$out" "$running is running" \
        || { log_fail "expected refusal mentioning $running; got: $out"; return 1; }
}

refuse_flag_due_to() {
    local flag="$1" running="$2"
    local out
    if out=$(./dev exec "$flag" -- true 2>&1); then
        log_fail "$flag should have refused while $running is running"; return 1
    fi
    expect_grep "$out" "$running is running" \
        || { log_fail "expected refusal mentioning $running; got: $out"; return 1; }
}

# Pair 1: normal running -> --dind, --maintenance refused.
"$RUNTIME" rm -f "$N" "$M" "$D" "$P" 2>/dev/null
run_bg ./dev exec -- sleep 60
refuse_flag_due_to --dind "$N" || exit 1
refuse_flag_due_to --maint "$N" || exit 1
"$RUNTIME" stop "$N" 2>/dev/null; "$RUNTIME" rm -f "$N" 2>/dev/null

# Pair 2: --maintenance running -> normal, --dind, --pind refused.
run_bg ./dev exec --maint -- sleep 60
refuse_normal_due_to "$M" || exit 1
refuse_flag_due_to --dind "$M" || exit 1
refuse_flag_due_to --pind "$M" || exit 1
"$RUNTIME" stop "$M" 2>/dev/null; "$RUNTIME" rm -f "$M" 2>/dev/null

# Pair 3: --dind running -> normal, --maintenance, --pind refused.
run_bg ./dev exec --dind -- sleep 60
sleep 6   # dockerd-rootless takes longer to come up
refuse_normal_due_to "$D" || exit 1
refuse_flag_due_to --maint "$D" || exit 1
refuse_flag_due_to --pind "$D" || exit 1
"$RUNTIME" stop "$D" 2>/dev/null; "$RUNTIME" rm -f "$D" 2>/dev/null

# Pair 4: --dind and --maintenance together in the same invocation are
# mutually exclusive, independent of any running container.
"$RUNTIME" rm -f "$N" "$M" "$D" "$P" 2>/dev/null
if out=$(./dev exec --dind --maint -- true 2>&1); then
    log_fail "--dind --maintenance together should have been rejected"
    exit 1
fi
expect_grep "$out" "mutually exclusive" \
    || { log_fail "expected mutual-exclusivity error; got: $out"; exit 1; }

# Pair 5: normal running -> --pind refused.
"$RUNTIME" rm -f "$N" "$M" "$D" "$P" 2>/dev/null
run_bg ./dev exec -- sleep 60
refuse_flag_due_to --pind "$N" || exit 1
"$RUNTIME" stop "$N" 2>/dev/null; "$RUNTIME" rm -f "$N" 2>/dev/null

# Pair 6: --pind running -> normal, --dind, --maintenance refused.
run_bg ./dev exec --pind -- sleep 60
sleep 6   # podman service startup
refuse_normal_due_to "$P" || exit 1
refuse_flag_due_to --dind "$P" || exit 1
refuse_flag_due_to --maint "$P" || exit 1
"$RUNTIME" stop "$P" 2>/dev/null; "$RUNTIME" rm -f "$P" 2>/dev/null

# Pair 7: --pind with --dind / --maintenance in one invocation are rejected.
"$RUNTIME" rm -f "$N" "$M" "$D" "$P" 2>/dev/null
if out=$(./dev exec --pind --dind -- true 2>&1); then
    log_fail "--pind --dind together should have been rejected"; exit 1
fi
expect_grep "$out" "mutually exclusive" \
    || { log_fail "expected mutual-exclusivity error; got: $out"; exit 1; }
if out=$(./dev exec --pind --maint -- true 2>&1); then
    log_fail "--pind --maintenance together should have been rejected"; exit 1
fi
expect_grep "$out" "mutually exclusive" \
    || { log_fail "expected mutual-exclusivity error; got: $out"; exit 1; }

log_pass "four-way conflict guard and --dind/--pind/--maintenance mutex correct (all six pairwise running->refused directions plus same-invocation pairs)"
exit 0
