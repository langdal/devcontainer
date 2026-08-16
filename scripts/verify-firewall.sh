#!/bin/bash
# scripts/verify-firewall.sh
#
# Run inside the dev container to probe firewall posture.
# In closed egress mode: posture checks 1-7, 13, and 14 should pass.
# In open egress mode: checks 1, 3, 4, 13 are skipped (they assert closed-mode
# behavior that open mode deliberately doesn't provide); 2, 5, and 14 should pass.
# In maintenance mode: checks 1, 3, 4, 6, 7, 13 are skipped; 2, 5, and 14 should pass.
# Check 14 (link-local/metadata block) runs unconditionally in every mode: the
# 169.254.0.0/16 / fe80::/10 DROP rule is always-on regardless of egress mode.
set -u

PASS=0; FAIL=0; SKIP=0
maint=${DEVCONTAINER_MAINTENANCE:-}
egress_open=""; [ "${DEVCONTAINER_EGRESS:-}" = open ] && egress_open=1

run_check() {
    local name="$1"; shift
    local skip_in_maint="${SKIP_IN_MAINT:-0}"
    local skip_in_open="${SKIP_IN_OPEN:-0}"
    local skip_unless_nested="${SKIP_UNLESS_NESTED:-0}"
    if [ -n "$maint" ] && [ "$skip_in_maint" = "1" ]; then
        printf '  SKIP   %s (maintenance mode)\n' "$name"
        SKIP=$((SKIP+1)); return
    fi
    if [ -n "$egress_open" ] && [ "$skip_in_open" = "1" ]; then
        printf '  SKIP   %s (open egress mode)\n' "$name"
        SKIP=$((SKIP+1)); return
    fi
    if [ "$skip_unless_nested" = "1" ] && ! nested_active; then
        printf '  SKIP   %s (not in nested-runtime mode)\n' "$name"
        SKIP=$((SKIP+1)); return
    fi
    if "$@" >/dev/null 2>&1; then
        printf '  PASS   %s\n' "$name"
        PASS=$((PASS+1))
    else
        printf '  FAIL   %s\n' "$name"
        FAIL=$((FAIL+1))
    fi
}

# Helpers for the checks.
proxy_listening() {
    curl -s -o /dev/null -m 3 http://127.0.0.1:8888
}
allowed_host() {
    curl -fsS -o /dev/null -m 5 https://api.github.com/zen
}
blocked_host_returns_403() {
    # tinyproxy rejects on the CONNECT request itself; curl's %{http_code}
    # stays 000 and not all curl versions support %{http_connect_code}, so
    # match the proxy's 403 status line directly from -D (dump headers).
    curl -s -m 5 -o /dev/null -D - https://example.com 2>/dev/null | grep -q '^HTTP/1\.[01] 403'
}
raw_socket_blocked() {
    ! curl -fsS -o /dev/null -m 5 --noproxy '*' https://api.github.com 2>/dev/null
}
dns_works() {
    getent hosts example.com
}
sudo_blocked() {
    ! sudo -n true 2>/dev/null
}
iptables_flush_blocked() {
    ! sudo -n iptables -F 2>/dev/null
}
ipv6_direct_blocked() {
    # A runtime that gives the container a global v6 route (podman 5's pasta)
    # would otherwise expose an unfiltered egress path: iptables only covers
    # IPv4. firewall-init.sh mirrors the DROP policy in ip6tables; this probes
    # it with a literal v6 address (DNS is no help: the entrypoint sets
    # no-aaaa) against Cloudflare's well-known resolver IP. -k because the
    # cert won't match the bare IP — TLS completing at all means egress leaked.
    # Vacuously passes on hosts with no v6 route at all (connect fails either way).
    ! curl -g -6 -ksS -o /dev/null -m 5 --noproxy '*' 'https://[2606:4700:4700::1111]/' 2>/dev/null
}
link_local_blocked() {
    # The cloud metadata endpoint (169.254.169.254) and the rest of the
    # link-local range are DROPped on OUTPUT unconditionally — in open and
    # closed egress modes alike — so this must never be gated on proxy/mode.
    # --noproxy '*' bypasses tinyproxy to exercise the raw kernel iptables
    # path directly; the check passes when curl fails to connect.
    ! curl -s -m 3 -o /dev/null --noproxy '*' http://169.254.169.254/ 2>/dev/null
}

# Nested-runtime-aware helpers (used only when DEVCONTAINER_DIND or
# DEVCONTAINER_PIND is set).
nested_active() { [ -n "${DEVCONTAINER_DIND:-}" ] || [ -n "${DEVCONTAINER_PIND:-}" ]; }
nested_engine() { if [ -n "${DEVCONTAINER_PIND:-}" ]; then echo podman; else echo docker; fi; }

dockerd_reachable() {
    if [ "$(nested_engine)" = podman ]; then
        podman info >/dev/null 2>&1
    else
        docker version >/dev/null 2>&1
    fi
}
dockerd_rootless() {
    if [ "$(nested_engine)" = podman ]; then
        [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]
    else
        docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q 'rootless'
    fi
}
nested_pull_works() {
    if [ "$(nested_engine)" = podman ]; then
        podman pull alpine:3.20 >/dev/null 2>&1
    else
        docker pull -q alpine:3.20 >/dev/null 2>&1
    fi
}
nested_egress_blocked() {
    # Run a quick wget; expect non-zero exit.
    if [ "$(nested_engine)" = podman ]; then
        # No --network bridge here (unlike the docker branch below): rootless
        # podman's default network is pinned to slirp4netns via
        # default_rootless_network_cmd in pind-init.sh, and its egress is
        # meant to be NAT'd through the 10.0.2.2:8888 tinyproxy gateway. The
        # default network is the intended firewalled path under test, so
        # there is no docker-style "bridge" network to opt into.
        # Nested containers reach tinyproxy at 10.0.2.2:8888 because
        # pind-init.sh enables slirp4netns allow_host_loopback=true globally.
        # Non-allowlisted hosts are blocked by tinyproxy's hostname filter (403);
        # direct egress is separately blocked by iptables. This check therefore
        # exercises genuine firewall blocking, not a dead network path.
        ! podman run --rm alpine:3.20 \
            wget -T3 -q -O- https://example.com >/dev/null 2>&1
    else
        ! docker run --rm --network bridge alpine:3.20 \
            wget -T3 -q -O- https://example.com >/dev/null 2>&1
    fi
}
nested_loopback_works() {
    # Bring up a netcat listener on a random port and curl it from the agent shell.
    local engine
    engine="$(nested_engine)"
    local port
    if [ "$engine" = podman ]; then
        # podman (unlike docker) rejects an explicit host port of 0; the
        # empty-host-port form (host::container) is its random-port syntax.
        port=$(podman run --rm -d -p 127.0.0.1::8080 alpine:3.20 \
            sh -c 'echo -e "HTTP/1.0 200 OK\r\n\r\nhello" | nc -lp 8080')
    else
        port=$(docker run --rm -d -p 127.0.0.1:0:8080 alpine:3.20 \
            sh -c 'echo -e "HTTP/1.0 200 OK\r\n\r\nhello" | nc -lp 8080')
    fi
    [ -n "$port" ] || return 1
    # Resolve the host-side port assigned by the engine.
    local hostport
    hostport=$("$engine" port "$port" 8080 | head -1 | awk -F: '{print $NF}')
    [ -n "$hostport" ] || { "$engine" rm -f "$port" >/dev/null 2>&1; return 1; }
    sleep 0.3
    if curl -fsS -m 3 "http://127.0.0.1:${hostport}" 2>/dev/null | grep -q hello; then
        "$engine" rm -f "$port" >/dev/null 2>&1
        return 0
    fi
    "$engine" rm -f "$port" >/dev/null 2>&1
    return 1
}

echo "Firewall verification"
if [ -n "$maint" ]; then
    echo "  mode: MAINTENANCE"
else
    echo "  mode: NORMAL"
fi
echo

SKIP_IN_MAINT=1 SKIP_IN_OPEN=1 run_check "1. proxy reachable on 127.0.0.1:8888" proxy_listening
                                run_check "2. allowed host reachable"            allowed_host
SKIP_IN_MAINT=1 SKIP_IN_OPEN=1 run_check "3. blocked host returns 403"          blocked_host_returns_403
SKIP_IN_MAINT=1 SKIP_IN_OPEN=1 run_check "4. raw socket bypass blocked"         raw_socket_blocked
                                run_check "5. DNS works"                         dns_works
SKIP_IN_MAINT=1                run_check "6. sudo blocked"                      sudo_blocked
SKIP_IN_MAINT=1                run_check "7. iptables flush blocked"            iptables_flush_blocked
SKIP_IN_MAINT=1 SKIP_IN_OPEN=1 run_check "13. direct IPv6 bypass blocked"       ipv6_direct_blocked
                                run_check "14. link-local/metadata blocked"      link_local_blocked

SKIP_UNLESS_NESTED=1 run_check "8. nested engine reachable"         dockerd_reachable
SKIP_UNLESS_NESTED=1 run_check "9. nested engine rootless"          dockerd_rootless
SKIP_UNLESS_NESTED=1 run_check "10. registry pull through proxy"    nested_pull_works
SKIP_UNLESS_NESTED=1 run_check "11. nested container egress blocked" nested_egress_blocked
SKIP_UNLESS_NESTED=1 run_check "12. nested container loopback works" nested_loopback_works

echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
