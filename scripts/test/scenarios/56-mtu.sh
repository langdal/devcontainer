#!/bin/bash
# scripts/test/scenarios/56-mtu.sh
# platform: linux
# privilege: user
#
# Behavioral contract for DEV_MTU: the value set on the host is applied to
# the container's default-route interface by the entrypoint (as root, before
# privileges drop), in normal AND maintenance mode, and a container started
# without it keeps the runtime's default.
#
# Why: a corporate VPN client (FortiClient, 2026-09-07) lowered the host
# uplink to 1280 and silently dropped every forwarded packet above ~1180
# bytes. Host sockets were fine, so only in-container clients with a large
# first packet (mise's rustls ClientHello) hung. The MTU lives on the
# interface the runtime creates per `run`, so nothing in the image can carry
# the fix -- it has to be re-applied at every container creation.
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
remember_container "dev-${WS}"
remember_container "dev-${WS}-maint"
# A stale container from an aborted prior run would be reused by dev's attach
# path, and reuse ignores DEV_MTU (applied only at creation).
"$RUNTIME" rm -f "dev-${WS}" "dev-${WS}-maint" >/dev/null 2>&1 || true

# Report the MTU of whichever interface carries the default route: eth0 under
# docker/rootful podman, tap0 under slirp4netns, the host's name under pasta.
MTU_OF_DEFAULT='dev=$(ip -o route show default | awk "{for(i=1;i<=NF;i++) if(\$i==\"dev\") {print \$(i+1); exit}}"); echo "MTURESULT:$(cat /sys/class/net/$dev/mtu)"'

# ---------- (a) DEV_MTU applied in normal mode ----------
out=$(DEV_MTU=1400 ./dev exec -- sh -c "$MTU_OF_DEFAULT" 2>&1) \
    || { log_fail "(a) outer 'dev exec' failed: $out"; exit 1; }
expect_grep "$out" "MTURESULT:1400" \
    || { log_fail "(a) DEV_MTU=1400 not applied to the default-route interface: $out"; exit 1; }
./dev down >/dev/null 2>&1
echo "assertion (a): DEV_MTU=1400 applied in normal mode"

# ---------- (b) DEV_MTU applied in maintenance mode ----------
out=$(DEV_MTU=1400 ./dev exec --maint -- sh -c "$MTU_OF_DEFAULT" 2>&1) \
    || { log_fail "(b) outer 'dev exec --maint' failed: $out"; exit 1; }
expect_grep "$out" "MTURESULT:1400" \
    || { log_fail "(b) DEV_MTU=1400 not applied in --maint: $out"; exit 1; }
./dev down --maint >/dev/null 2>&1; ./dev down >/dev/null 2>&1
echo "assertion (b): DEV_MTU=1400 applied in maintenance mode"

# ---------- (c) unset: the runtime's own default is left alone ----------
out=$(env -u DEV_MTU ./dev exec -- sh -c "$MTU_OF_DEFAULT" 2>&1) \
    || { log_fail "(c) outer 'dev exec' failed: $out"; exit 1; }
expect_grep "$out" "MTURESULT:1400" \
    && { log_fail "(c) MTU 1400 persisted into a container started without DEV_MTU: $out"; exit 1; }
expect_grep "$out" "MTURESULT:[0-9]+" \
    || { log_fail "(c) could not read the default MTU: $out"; exit 1; }
./dev down >/dev/null 2>&1
echo "assertion (c): no DEV_MTU leaves the runtime default"

log_pass "DEV_MTU applied in normal (a) and maintenance (b) mode; absent leaves the default (c)"
exit 0
