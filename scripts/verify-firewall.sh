#!/bin/bash
# scripts/verify-firewall.sh
#
# Run inside the dev container to probe firewall posture.
# In normal mode: all 7 checks should pass.
# In maintenance mode: checks 1, 3, 4, 6, 7 are skipped; 2 and 5 should pass.
set -u

PASS=0; FAIL=0; SKIP=0
maint=${DEVCONTAINER_MAINTENANCE:-}

run_check() {
    local name="$1"; shift
    local skip_in_maint="${SKIP_IN_MAINT:-0}"
    if [ -n "$maint" ] && [ "$skip_in_maint" = "1" ]; then
        printf '  SKIP   %s (maintenance mode)\n' "$name"
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

echo "Firewall verification"
if [ -n "$maint" ]; then
    echo "  mode: MAINTENANCE"
else
    echo "  mode: NORMAL"
fi
echo

SKIP_IN_MAINT=1 run_check "1. proxy reachable on 127.0.0.1:8888" proxy_listening
                run_check "2. allowed host reachable"            allowed_host
SKIP_IN_MAINT=1 run_check "3. blocked host returns 403"          blocked_host_returns_403
SKIP_IN_MAINT=1 run_check "4. raw socket bypass blocked"         raw_socket_blocked
                run_check "5. DNS works"                         dns_works
SKIP_IN_MAINT=1 run_check "6. sudo blocked"                      sudo_blocked
SKIP_IN_MAINT=1 run_check "7. iptables flush blocked"            iptables_flush_blocked

echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
