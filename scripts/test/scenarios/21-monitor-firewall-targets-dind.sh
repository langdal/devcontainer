#!/bin/bash
# scripts/test/scenarios/21-monitor-firewall-targets-dind.sh
# platform: linux
#
# `dev --monitor`, `--monitor-fw`, `--disable-firewall`, `--enable-firewall`
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

docker rm -f "$N" "$M" "$D" 2>/dev/null

# 0. Regression: with the normal container running, --disable-firewall
#    and --enable-firewall must continue to work as before.
run_bg ./dev -- sleep 60
if ! docker ps -q -f name="^${N}$" | grep -q .; then
    log_fail "precondition: normal container ${N} did not start"
    exit 1
fi
if ! out=$(./dev --disable-firewall 2>&1); then
    log_fail "--disable-firewall regressed against normal container: $out"
    exit 1
fi
expect_grep "$out" "firewall disabled" \
    || { log_fail "--disable-firewall on normal did not print 'firewall disabled': $out"; exit 1; }
if ! out=$(./dev --enable-firewall 2>&1); then
    log_fail "--enable-firewall regressed against normal container: $out"
    exit 1
fi
expect_grep "$out" "firewall-init: ready" \
    || { log_fail "--enable-firewall on normal did not invoke firewall-init.sh: $out"; exit 1; }
docker stop "$N" 2>/dev/null; docker rm -f "$N" 2>/dev/null

# 1. With only the dind container running, --enable-firewall and
#    --disable-firewall must operate on it instead of erroring
#    "container <normal-name> is not running".
run_bg ./dev --dind -- sleep 60
sleep 6   # dockerd-rootless takes longer to come up
if ! docker ps -q -f name="^${D}$" | grep -q .; then
    log_fail "precondition: dind container ${D} did not start"
    exit 1
fi

if ! out=$(./dev --disable-firewall 2>&1); then
    log_fail "--disable-firewall failed against running dind: $out"
    exit 1
fi
expect_grep "$out" "firewall disabled" \
    || { log_fail "--disable-firewall on dind did not print 'firewall disabled': $out"; exit 1; }

if ! out=$(./dev --enable-firewall 2>&1); then
    log_fail "--enable-firewall failed against running dind: $out"
    exit 1
fi
expect_grep "$out" "firewall-init: ready" \
    || { log_fail "--enable-firewall on dind did not invoke firewall-init.sh: $out"; exit 1; }

# --monitor exec's `tail -F`. Bound it with timeout, redirect stdin from
# /dev/null so the test passes in non-TTY runs (the existing -it flag
# would still fail the docker exec, but we only need to confirm the
# early-exit block did not reject the dind container with "not running").
out=$(timeout 2 ./dev --monitor </dev/null 2>&1 || true)
if expect_grep "$out" "container ${N} is not running"; then
    log_fail "--monitor still targets normal container ${N}, not dind ${D}: $out"
    exit 1
fi

docker stop "$D" 2>/dev/null; docker rm -f "$D" 2>/dev/null

# 2. With only the maintenance container running, all four management
#    commands must refuse with a clear maintenance-mode message.
run_bg ./dev --maintenance -- sleep 60
if ! docker ps -q -f name="^${M}$" | grep -q .; then
    log_fail "precondition: maintenance container ${M} did not start"
    exit 1
fi
for flag in --monitor --monitor-fw --disable-firewall --enable-firewall; do
    if out=$(./dev "$flag" </dev/null 2>&1); then
        log_fail "$flag should have refused while maintenance is running"
        exit 1
    fi
    expect_grep "$out" "maintenance" \
        || { log_fail "$flag should mention maintenance mode; got: $out"; exit 1; }
done
docker stop "$M" 2>/dev/null; docker rm -f "$M" 2>/dev/null

# 3. With no workspace container running, the read-only/restore management
#    commands must error with a clear "not running" / "no container" message.
#    --disable-firewall is excluded here: it doubles as a start flag (step 4).
for flag in --monitor --monitor-fw --enable-firewall; do
    if out=$(./dev "$flag" </dev/null 2>&1); then
        log_fail "$flag should have refused with no container running"
        exit 1
    fi
    expect_grep "$out" "not running|no .* container" \
        || { log_fail "$flag should report no running container; got: $out"; exit 1; }
done

# 4. --disable-firewall with no container running must START a fresh normal
#    container with the firewall already open (same end state as
#    start-then-toggle), not error. Confirm via the OUTPUT chain policy:
#    ACCEPT when disabled vs the default-deny DROP.
run_bg ./dev --disable-firewall -- sleep 60
if ! docker ps -q -f name="^${N}$" | grep -q .; then
    log_fail "--disable-firewall with no container running did not start ${N}"
    exit 1
fi
sleep 2   # firewall-init.sh + firewall-disable.sh run before the CMD
out=$(docker exec --user root "$N" iptables -S OUTPUT 2>&1 | head -1)
expect_grep "$out" "OUTPUT ACCEPT" \
    || { log_fail "fresh --disable-firewall container should have OUTPUT policy ACCEPT; got: $out"; exit 1; }
# And it must be re-securable in place with --enable-firewall.
if ! out=$(./dev --enable-firewall 2>&1); then
    log_fail "--enable-firewall failed against fresh fw-disabled container: $out"
    exit 1
fi
expect_grep "$out" "firewall-init: ready" \
    || { log_fail "--enable-firewall did not invoke firewall-init.sh: $out"; exit 1; }
docker stop "$N" 2>/dev/null; docker rm -f "$N" 2>/dev/null

log_pass "monitor + firewall management commands target running normal-or-dind container"
exit 0
