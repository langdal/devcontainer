#!/bin/bash
# scripts/test/scenarios/55-host-port.sh
# platform: linux
# privilege: user
#
# Behavioral contract for `--host-port PORT`: a service listening on the
# host is reachable from inside the container at host.docker.internal:PORT
# in BOTH egress modes, and punching that hole must not weaken the
# always-on link-local/cloud-metadata block for any other destination.
#
# Regression guard: podman >=5 (pasta backend) maps the host-gateway
# sentinel to a LINK-LOCAL address (169.254.1.2 by default), which
# install_baseline_blocks's 169.254.0.0/16 DROP swallowed — the closed-mode
# ACCEPT was appended after the DROP (a dead rule), and open mode never
# punched a hole at all — so `--host-port` timed out on every pasta host,
# in both modes.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux

command -v python3 >/dev/null 2>&1 \
    || { log_skip "python3 not on host PATH (needed for the host-side listener)"; exit 0; }

SRV_PID=""
# shellcheck disable=SC2317,SC2329  # invoked via the EXIT trap below
cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    restore_host
}
trap cleanup EXIT

cd "$(dirname "$0")/../../.." || exit 1
export DEV_ASSUME_YES=1

WS=$(basename "$(pwd)")
N="dev-${WS}"
remember_container "$N"

# Defensive pre-removal: a stale container from an aborted prior run would
# otherwise be reused by dev's attach path — and reuse ignores --host-port,
# which only takes effect at container creation.
"$RUNTIME" rm -f "$N" >/dev/null 2>&1 || true

# Free port on the host, from a handful of uncommon candidates.
PORT=""
for p in 18099 18173 18251 18337 18411; do
    if ! ss -tln 2>/dev/null | grep -q ":$p "; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || { log_skip "no free probe port found on the host"; exit 0; }

# Host-side listener. Bind 0.0.0.0: under docker the container's traffic
# arrives on the bridge IP, not loopback.
python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "$SRV_PID" 2>/dev/null \
    || { SRV_PID=""; log_skip "host listener failed to start on :$PORT"; exit 0; }

# Assert on the HTTP status, not a bare success marker: `curl -w` writes its
# format string even when the transfer FAILS (a timed-out curl still prints
# it), so grepping for a constant would pass on a dead connection. HITRESULT:200
# only appears when the host listener actually answered.
#
# Bounded retry, because this probes steady-state reachability: pasta's
# host-gateway forwarding refuses connections for the first few seconds of
# container life (instant RST, measured ~3-4s on podman 6), and the scenario's
# curl runs as the container's FIRST command. The regression this scenario
# guards is a permanent iptables DROP — every attempt times out — so the
# retry cannot mask it.
HIT="i=0; r=000; while [ \$i -lt 10 ]; do r=\$(curl -sS -m3 -o /dev/null -w '%{http_code}' http://host.docker.internal:$PORT/ 2>/dev/null); [ \"\$r\" = 200 ] && break; i=\$((i+1)); sleep 1; done; echo \"HITRESULT:\$r\""
META='curl -sS -m5 -o /dev/null http://169.254.169.254/ || echo METABLOCKED'

# ---------- (a) open mode (default): host service reachable ----------
out=$(./dev exec --host-port "$PORT" -- sh -c "$HIT" 2>&1) \
    || { log_fail "(a) outer 'dev exec --host-port' failed: $out"; exit 1; }
expect_grep "$out" "HITRESULT:200" \
    || { log_fail "(a) open mode: host.docker.internal:$PORT unreachable from container: $out"; exit 1; }

./dev down >/dev/null 2>&1

echo "assertion (a): host service reachable via host.docker.internal:$PORT under open egress"

# ---------- (b) closed mode: same reachability ----------
out=$(./dev exec --closed --host-port "$PORT" -- sh -c "$HIT" 2>&1) \
    || { log_fail "(b) outer 'dev exec --closed --host-port' failed: $out"; exit 1; }
expect_grep "$out" "HITRESULT:200" \
    || { log_fail "(b) closed mode: host.docker.internal:$PORT unreachable from container: $out"; exit 1; }

./dev down >/dev/null 2>&1

echo "assertion (b): host service reachable via host.docker.internal:$PORT under closed egress"

# ---------- (c) the hole must not open the metadata IP ----------
out=$(./dev exec --host-port "$PORT" -- sh -c "$META" 2>&1) \
    || { log_fail "(c) outer 'dev exec --host-port' failed: $out"; exit 1; }
expect_grep "$out" METABLOCKED \
    || { log_fail "(c) cloud metadata IP reachable with --host-port active: $out"; exit 1; }

./dev down >/dev/null 2>&1

log_pass "--host-port reaches the host service in open (a) and closed (b) mode; metadata IP stays blocked (c)"
exit 0
