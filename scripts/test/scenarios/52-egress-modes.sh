#!/bin/bash
# scripts/test/scenarios/52-egress-modes.sh
# platform: linux
# privilege: user
#
# Behavioral contract for the open/closed egress modes: `dev up`/`dev exec`
# default to OPEN egress (reaches arbitrary internet hosts); `--closed` (or
# DEV_EGRESS=closed) switches to the hostname-allowlist firewall, which
# blocks a non-allowlisted host (example.com is not in allowlist.base);
# precedence is explicit flag > DEV_EGRESS > default open; link-local
# (169.254.0.0/16) is DROPped in BOTH modes; and open mode stays observable
# via `dev fw log` (DNS-name/new-connection logging instead of tinyproxy's
# hostname log).
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
export DEV_ASSUME_YES=1

WS=$(basename "$(pwd)")
N="dev-${WS}"
remember_container "$N"

# Defensive pre-removal: a stale container from an aborted prior run would
# otherwise be reused by dev's attach path with whatever mode it was left in.
"$RUNTIME" rm -f "$N" >/dev/null 2>&1 || true

CURL_OK='curl -sS -m8 -o /dev/null -w OK https://example.com'
META='curl -sS -m5 -o /dev/null http://169.254.169.254/ || echo METABLOCKED'

# `dev exec -- <cmd>` runs <cmd> to completion and the (--rm) container then
# exits and self-removes -- fine for the one-shot assertions below, which
# only need that single call's own captured stdout. (f) needs the container
# to still be running *after* its exec returns (so a concurrent `dev fw log`
# has something to attach to), so it uses this backgrounded long-runner
# instead, exactly like scenarios 20/21.
run_bg() {
    nohup "$@" >/dev/null 2>&1 &
    disown
    sleep 4
}

# ---------- (a) default egress is open: reaches a non-allowlisted host ----------
out=$(./dev exec -- sh -c "$CURL_OK || echo NOPE" 2>&1) \
    || { log_fail "(a) outer 'dev exec' failed: $out"; exit 1; }
expect_grep "$out" OK \
    || { log_fail "(a) default egress did not reach example.com: $out"; exit 1; }

./dev down >/dev/null 2>&1

# ---------- (b) --closed blocks example.com (not in allowlist.base) ----------
out=$(./dev exec --closed -- sh -c "$CURL_OK || echo BLOCKED" 2>&1) \
    || { log_fail "(b) outer 'dev exec --closed' failed: $out"; exit 1; }
expect_grep "$out" BLOCKED \
    || { log_fail "(b) --closed reached example.com, expected a block: $out"; exit 1; }

./dev down >/dev/null 2>&1

# ---------- (c) DEV_EGRESS=closed also blocks it ----------
out=$(DEV_EGRESS=closed ./dev exec -- sh -c "$CURL_OK || echo BLOCKED" 2>&1) \
    || { log_fail "(c) outer 'DEV_EGRESS=closed dev exec' failed: $out"; exit 1; }
expect_grep "$out" BLOCKED \
    || { log_fail "(c) DEV_EGRESS=closed reached example.com, expected a block: $out"; exit 1; }

./dev down >/dev/null 2>&1

# ---------- (d) explicit --open overrides DEV_EGRESS=closed (flag > env) ----------
out=$(DEV_EGRESS=closed ./dev exec --open -- sh -c "$CURL_OK || echo NOPE" 2>&1) \
    || { log_fail "(d) outer 'DEV_EGRESS=closed dev exec --open' failed: $out"; exit 1; }
expect_grep "$out" OK \
    || { log_fail "(d) --open (over DEV_EGRESS=closed) blocked example.com: $out"; exit 1; }

echo "assertions (a)-(d): egress precedence (default open, --closed, DEV_EGRESS=closed, --open overrides env) all correct"

# ---------- (e-open) link-local DROP holds in open mode ----------
out=$(./dev exec -- sh -c "$META" 2>&1) \
    || { log_fail "(e-open) outer 'dev exec' failed: $out"; exit 1; }
expect_grep "$out" METABLOCKED \
    || { log_fail "(e-open) link-local metadata IP not blocked in open mode: $out"; exit 1; }

echo "assertion (e-open): link-local (169.254.169.254) blocked under open egress"

# ---------- (f) open-mode observability via 'dev fw log' ----------
# Needs the container to still be running when `dev fw log` attaches, so
# start one that stays up (default egress = open, no flags/env) rather than
# a one-shot exec that would self-remove the instant its command finishes.
# Unlike the other assertions, the curl here must NOT run inside run_bg's
# startup command: 'dev fw log' now reads a live NFLOG feed (see
# lib/dev/fw.sh fw_log), so the DNS query / connection SYN it is meant to
# catch has to happen *after* tcpdump attaches -- a curl that already
# completed during run_bg's 4s startup sleep would leave nothing in the feed
# by the time the reader starts listening.
"$RUNTIME" rm -f "$N" >/dev/null 2>&1 || true
run_bg ./dev exec -- sh -c "sleep 60"
if ! "$RUNTIME" ps -q -f name="^${N}\$" | grep -q .; then
    log_fail "(f) precondition: open container ${N} did not start"
    exit 1
fi

# Confirm this container's egress env is actually "open" -- that's exactly
# the signal fw_log() (lib/dev/fw.sh) branches on to pick tcpdump over
# tinyproxy's log -- so the branch assertion below is grounded independent of
# whether tcpdump itself can run on this host.
mode_env=$(./dev exec -- printenv DEVCONTAINER_EGRESS 2>&1) \
    || { log_fail "(f) could not read DEVCONTAINER_EGRESS from the running container: $mode_env"; exit 1; }
expect_grep "$mode_env" '^open$' \
    || { log_fail "(f) container egress env is not 'open' ($mode_env); fw_log's branch pick can't be verified"; exit 1; }

# fw_log() execs `tcpdump -i nflog:2 ... -it`; bound it with timeout and
# detach stdin from a tty exactly as scenario 21
# (monitor-firewall-targets-dind) does. Start the reader in the background
# first, give it a moment to attach, THEN issue the curl that generates the
# DNS query + connection it's supposed to catch -- the reverse order (curl
# first) races the capture and can miss evidence that genuinely exists.
#
# DNS-via-nflog:2 has been verified to genuinely work on rootless podman (see
# report), so a miss here is a real assertion, not a documented skip. One
# bounded retry guards only against a pure attach/curl timing race (tcpdump
# not fully attached to nflog:2 yet when the curl fires); a miss on both
# attempts is a hard failure.
fw_out=""
for attempt in 1 2; do
    FW_OUT_FILE=$(mktemp)
    ( timeout 6 ./dev fw log </dev/null >"$FW_OUT_FILE" 2>&1 ) &
    fw_log_pid=$!
    sleep 1.5
    curl_out=$(./dev exec -- sh -c "$CURL_OK" 2>&1)
    curl_rc=$?
    sleep 1.5
    wait "$fw_log_pid" 2>/dev/null
    fw_out=$(cat "$FW_OUT_FILE")
    rm -f "$FW_OUT_FILE"

    if [[ $curl_rc -ne 0 ]]; then
        log_fail "(f) outer 'dev exec' (DNS/connection trigger) failed on attempt $attempt: $curl_out"
        exit 1
    fi

    if expect_grep "$fw_out" 'example\.com'; then
        break
    fi
    echo "assertion (f): attempt $attempt found no example.com line yet, retrying once -- fw_out=[$fw_out]"
done

expect_grep "$fw_out" 'example\.com' \
    || { log_fail "(f) 'dev fw log' showed no example.com DNS/connection activity in open mode after 2 attempts: fw_out=[$fw_out]"; exit 1; }

echo "assertion (f): 'dev fw log' showed example.com DNS/connection activity in open mode"

# ---------- (g) fw close/open toggle actually flips the kernel policy ----------
# Regression guard for C-1: `dev fw close` on a container that was started
# with DEVCONTAINER_EGRESS=open must not silently inherit that env into the
# exec and re-run firewall-init.sh's OPEN branch. Reuses the still-running
# default-egress container from (f). Assert the OUTPUT policy directly
# (evidence), not the "ready" log line, which both branches print.
if ! out=$(./dev fw close 2>&1); then
    log_fail "(g) 'dev fw close' failed on a running open-egress container: $out"
    exit 1
fi
pol=$("$RUNTIME" exec --user root "$N" iptables -S OUTPUT 2>&1 | head -1)
expect_grep "$pol" "OUTPUT DROP" \
    || { log_fail "(g) 'dev fw close' did not set OUTPUT policy to DROP: $pol"; exit 1; }

if ! out=$(./dev fw open 2>&1); then
    log_fail "(g) 'dev fw open' failed after fw close: $out"
    exit 1
fi
pol=$("$RUNTIME" exec --user root "$N" iptables -S OUTPUT 2>&1 | head -1)
expect_grep "$pol" "OUTPUT ACCEPT" \
    || { log_fail "(g) 'dev fw open' did not restore OUTPUT policy to ACCEPT: $pol"; exit 1; }

echo "assertion (g): 'dev fw close'/'dev fw open' toggle the kernel OUTPUT policy (DROP/ACCEPT) on a running container"

"$RUNTIME" stop "$N" >/dev/null 2>&1
"$RUNTIME" rm -f "$N" >/dev/null 2>&1

# ---------- (e-closed) link-local DROP holds in closed mode too ----------
out=$(./dev exec --closed -- sh -c "$META" 2>&1) \
    || { log_fail "(e-closed) outer 'dev exec --closed' failed: $out"; exit 1; }
expect_grep "$out" METABLOCKED \
    || { log_fail "(e-closed) link-local metadata IP not blocked in closed mode: $out"; exit 1; }

echo "assertion (e-closed): link-local (169.254.169.254) blocked under closed egress"

./dev down >/dev/null 2>&1

log_pass "egress open/closed contract holds: precedence (a-d), link-local DROP in both modes (e), open-mode fw log observability (f), fw close/open toggle (g)"
exit 0
