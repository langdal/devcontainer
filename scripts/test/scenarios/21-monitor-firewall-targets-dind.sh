#!/bin/bash
# scripts/test/scenarios/21-monitor-firewall-targets-dind.sh
# platform: linux
# privilege: user
#
# `dev fw log`, `fw drops`, `fw off`, `fw on`
# must operate on whichever workspace container is running (normal *or*
# dind). The dind container has the same firewall stack as the normal one
# (firewall-init.sh runs unless DEVCONTAINER_MAINTENANCE=1, tinyproxy on
# 127.0.0.1:8888, NFLOG group 1) — only the container name differs.
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
N="dev-${WS}"; M="dev-${WS}-maint"; D="dev-${WS}-dind"
remember_container "$N"; remember_container "$M"; remember_container "$D"

run_bg() {
    nohup "$@" >/dev/null 2>&1 &
    disown
    sleep 4
}

"$RUNTIME" rm -f "$N" "$M" "$D" 2>/dev/null

# 0. Regression: with the normal container running, `fw off`
#    and `fw on` must continue to work as before.
run_bg ./dev exec -- sleep 60
if ! "$RUNTIME" ps -q -f name="^${N}$" | grep -q .; then
    log_fail "precondition: normal container ${N} did not start"
    exit 1
fi
if ! out=$(./dev fw off 2>&1); then
    log_fail "fw off regressed against normal container: $out"
    exit 1
fi
expect_grep "$out" "firewall disabled" \
    || { log_fail "fw off on normal did not print 'firewall disabled': $out"; exit 1; }
if ! out=$(./dev fw on 2>&1); then
    log_fail "fw on regressed against normal container: $out"
    exit 1
fi
expect_grep "$out" "firewall-init: ready" \
    || { log_fail "fw on on normal did not invoke firewall-init.sh: $out"; exit 1; }
"$RUNTIME" stop "$N" 2>/dev/null; "$RUNTIME" rm -f "$N" 2>/dev/null

# 1. With only the dind container running, `fw on` and
#    `fw off` must operate on it instead of erroring
#    "container <normal-name> is not running".
run_bg ./dev exec --dind -- sleep 60
sleep 6   # dockerd-rootless takes longer to come up
if ! "$RUNTIME" ps -q -f name="^${D}$" | grep -q .; then
    log_fail "precondition: dind container ${D} did not start"
    exit 1
fi

if ! out=$(./dev fw off 2>&1); then
    log_fail "fw off failed against running dind: $out"
    exit 1
fi
expect_grep "$out" "firewall disabled" \
    || { log_fail "fw off on dind did not print 'firewall disabled': $out"; exit 1; }

if ! out=$(./dev fw on 2>&1); then
    log_fail "fw on failed against running dind: $out"
    exit 1
fi
expect_grep "$out" "firewall-init: ready" \
    || { log_fail "fw on on dind did not invoke firewall-init.sh: $out"; exit 1; }

# `fw log` exec's `tail -F`. Bound it with timeout, redirect stdin from
# /dev/null so the test passes in non-TTY runs (the existing -it flag
# would still fail the docker exec, but we only need to confirm the
# early-exit block did not reject the dind container with "not running").
out=$(timeout 2 ./dev fw log </dev/null 2>&1 || true)
if expect_grep "$out" "container ${N} is not running"; then
    log_fail "fw log still targets normal container ${N}, not dind ${D}: $out"
    exit 1
fi

"$RUNTIME" stop "$D" 2>/dev/null; "$RUNTIME" rm -f "$D" 2>/dev/null

# 2. With only the maintenance container running, all four management
#    commands must refuse with a clear maintenance-mode message.
run_bg ./dev exec --maint -- sleep 60
if ! "$RUNTIME" ps -q -f name="^${M}$" | grep -q .; then
    log_fail "precondition: maintenance container ${M} did not start"
    exit 1
fi
for action in log drops off on; do
    if out=$(./dev fw "$action" </dev/null 2>&1); then
        log_fail "fw $action should have refused while maintenance is running"
        exit 1
    fi
    expect_grep "$out" "maintenance" \
        || { log_fail "fw $action should mention maintenance mode; got: $out"; exit 1; }
done
"$RUNTIME" stop "$M" 2>/dev/null; "$RUNTIME" rm -f "$M" 2>/dev/null

# 3. With no workspace container running, the read-only/restore management
#    commands must error with a clear "not running" / "no container" message.
#    `fw off` is excluded here: it never cold-starts (see step 4, which
#    exercises the exec --open replacement for the old fw-disable fallthrough).
for action in log drops on; do
    if out=$(./dev fw "$action" </dev/null 2>&1); then
        log_fail "fw $action should have refused with no container running"
        exit 1
    fi
    expect_grep "$out" "not running|no .* container" \
        || { log_fail "fw $action should report no running container; got: $out"; exit 1; }
done

# 4. `dev exec --open` (replacing the old `fw disable` cold-start fallthrough)
#    with no container running must START a fresh normal container with the
#    firewall already open, not error. Confirm via the OUTPUT chain policy:
#    ACCEPT when disabled vs the default-deny DROP.
run_bg ./dev exec --open -- sleep 60
if ! "$RUNTIME" ps -q -f name="^${N}$" | grep -q .; then
    log_fail "exec --open with no container running did not start ${N}"
    exit 1
fi
sleep 2   # firewall-init.sh + firewall-disable.sh run before the CMD
out=$(docker exec --user root "$N" iptables -S OUTPUT 2>&1 | head -1)
expect_grep "$out" "OUTPUT ACCEPT" \
    || { log_fail "fresh exec --open container should have OUTPUT policy ACCEPT; got: $out"; exit 1; }
# And it must be re-securable in place with `fw on`.
if ! out=$(./dev fw on 2>&1); then
    log_fail "fw on failed against fresh fw-open container: $out"
    exit 1
fi
expect_grep "$out" "firewall-init: ready" \
    || { log_fail "fw on did not invoke firewall-init.sh: $out"; exit 1; }
"$RUNTIME" stop "$N" 2>/dev/null; "$RUNTIME" rm -f "$N" 2>/dev/null

log_pass "monitor + firewall management commands target running normal-or-dind container"
exit 0
