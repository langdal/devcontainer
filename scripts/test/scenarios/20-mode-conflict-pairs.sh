#!/bin/bash
# scripts/test/scenarios/20-mode-conflict-pairs.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"; . "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.."
WS=$(basename "$(pwd)")
N="dev-${WS}"; M="dev-${WS}-maint"; D="dev-${WS}-dind"
remember_container "$N"; remember_container "$M"; remember_container "$D"

run_bg() {
    nohup "$@" >/dev/null 2>&1 &
    disown
    sleep 4
}

refuse_normal_due_to() {
    local running="$1"
    local out
    if out=$(./dev -- true 2>&1); then
        log_fail "normal mode should have refused while $running is running"; return 1
    fi
    expect_grep "$out" "$running .* is running" \
        || { log_fail "expected refusal mentioning $running; got: $out"; return 1; }
}

refuse_flag_due_to() {
    local flag="$1" running="$2"
    local out
    if out=$(./dev "$flag" -- true 2>&1); then
        log_fail "$flag should have refused while $running is running"; return 1
    fi
    expect_grep "$out" "$running .* is running" \
        || { log_fail "expected refusal mentioning $running; got: $out"; return 1; }
}

# Pair 1: normal running -> --dind, --maintenance refused.
docker rm -f "$N" "$M" "$D" 2>/dev/null
run_bg ./dev -- sleep 60
refuse_flag_due_to --dind "$N" || exit 1
refuse_flag_due_to --maintenance "$N" || exit 1
docker stop "$N" 2>/dev/null; docker rm -f "$N" 2>/dev/null

# Pair 2: --maintenance running -> normal, --dind refused.
run_bg ./dev --maintenance -- sleep 60
refuse_normal_due_to "$M" || exit 1
refuse_flag_due_to --dind "$M" || exit 1
docker stop "$M" 2>/dev/null; docker rm -f "$M" 2>/dev/null

# Pair 3: --dind running -> normal, --maintenance refused.
run_bg ./dev --dind -- sleep 60
sleep 6   # dockerd-rootless takes longer to come up
refuse_normal_due_to "$D" || exit 1
refuse_flag_due_to --maintenance "$D" || exit 1
docker stop "$D" 2>/dev/null; docker rm -f "$D" 2>/dev/null

log_pass "three-way conflict guard correct on all pairs"
exit 0
