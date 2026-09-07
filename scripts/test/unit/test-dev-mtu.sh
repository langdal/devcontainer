#!/usr/bin/env bash
# Unit: DEV_MTU reaches the container as DEVCONTAINER_MTU in the run command,
# and a nonsense value is refused up front (exit 2, like DEV_EGRESS).
#
# Why this exists: a VPN client (FortiClient, 2026-09-07) shrank the host's
# uplink MTU and silently blackholed every forwarded packet over ~1180 bytes.
# The image cannot carry the fix -- MTU is a property of the interface docker
# creates per `run` -- so `dev` has to pass it at every container creation and
# the entrypoint applies it as root.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "SKIP: no container runtime on PATH"; exit 77; }
WORK=$(mktemp -d); mkdir -p "$WORK/myproj"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
dev() { (cd "$WORK/myproj" && env -u DEV_MTU "$@" "$ROOT/dev" exec --dry-run -- echo hi </dev/null 2>&1); }

# 1. Unset: nothing about MTU in the run command (the default path is untouched).
out=$(dev) || fail "dry-run failed with DEV_MTU unset: $out"
echo "$out" | grep -q 'DEVCONTAINER_MTU' \
    && fail "DEVCONTAINER_MTU leaked into the run command with DEV_MTU unset: $out"

# 2. Set: forwarded verbatim as -e DEVCONTAINER_MTU=<n>.
out=$(dev DEV_MTU=1180) || fail "dry-run failed with DEV_MTU=1180: $out"
echo "$out" | grep -q -- '-e DEVCONTAINER_MTU=1180' \
    || fail "DEV_MTU=1180 not forwarded as -e DEVCONTAINER_MTU=1180: $out"

# 3. Maintenance mode needs it just as much (same bridge, same VPN), unlike
#    the egress mode which --maint deliberately drops.
out=$(cd "$WORK/myproj" && env -u DEV_MTU DEV_MTU=1180 "$ROOT/dev" exec --maint --dry-run -- echo hi </dev/null 2>&1) \
    || fail "dry-run --maint failed with DEV_MTU=1180: $out"
echo "$out" | grep -q -- '-e DEVCONTAINER_MTU=1180' \
    || fail "DEV_MTU must also reach a --maint container: $out"

# 4. Garbage is refused before anything else happens, exit 2, naming the var.
for bad in abc 1180x '' 100 70000; do
    out=$(dev DEV_MTU="$bad"); rc=$?
    if [ -z "$bad" ]; then
        # Empty is "unset" in shell convention: accepted, not forwarded.
        [ "$rc" -eq 0 ] || fail "DEV_MTU='' should behave as unset, got exit $rc: $out"
        echo "$out" | grep -q 'DEVCONTAINER_MTU' \
            && fail "DEV_MTU='' must not forward anything: $out"
        continue
    fi
    [ "$rc" -eq 2 ] || fail "DEV_MTU=$bad should exit 2, got $rc: $out"
    echo "$out" | grep -q 'DEV_MTU' || fail "DEV_MTU=$bad: error does not name the variable: $out"
    echo "$out" | grep -q 'DEVCONTAINER_MTU' \
        && fail "DEV_MTU=$bad must not reach the run command: $out"
done

echo "PASS: DEV_MTU forwarding and validation"
