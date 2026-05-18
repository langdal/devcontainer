#!/bin/bash
# /usr/local/sbin/firewall-init.sh
#
# Configure tinyproxy and iptables to enforce a hostname allowlist.
# Runs as root at container startup.  Fail-closed: any error => non-zero exit.
set -euo pipefail

BASE=/etc/devcontainer/allowlist.base
PROJECT=/workspace/.devcontainer-allowlist
FILTER=/etc/tinyproxy/filter
CONF=/etc/tinyproxy/tinyproxy.conf

mkdir -p /etc/tinyproxy /var/log /run

# --- Merge base + project allowlist into a tinyproxy regex filter ---
{
    cat "$BASE"
    if [ -f "$PROJECT" ]; then
        cat "$PROJECT"
    fi
    if [ -n "${DEVCONTAINER_DIND:-}" ] && [ -f /etc/devcontainer/allowlist.dind ]; then
        cat /etc/devcontainer/allowlist.dind
    fi
} | sed 's/#.*//'           \
  | tr -d ' \t'             \
  | awk 'NF'                \
  | sort -u                 \
  | while IFS= read -r entry; do
        # *.foo.com  -> ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.foo\.com$
        # foo.com    -> ^foo\.com$
        if [[ "$entry" == \*.* ]]; then
            tail="${entry#*.}"
            escaped="${tail//./\\.}"
            printf '^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.%s$\n' "$escaped"
        else
            escaped="${entry//./\\.}"
            printf '^%s$\n' "$escaped"
        fi
    done > "$FILTER"

if [ ! -s "$FILTER" ]; then
    echo "firewall-init: refusing to start with an empty filter" >&2
    exit 1
fi

# --- Write tinyproxy config ---
cat > "$CONF" <<'EOF'
User proxy
Group proxy
Port 8888
Listen 127.0.0.1
PidFile "/run/tinyproxy.pid"
LogFile "/var/log/tinyproxy.log"
LogLevel Notice
MaxClients 100
Timeout 600

Filter "/etc/tinyproxy/filter"
FilterDefaultDeny Yes
FilterExtended Yes
FilterURLs No
EOF

touch /var/log/tinyproxy.log
chown proxy:proxy /var/log/tinyproxy.log
chmod 0755 /run

tinyproxy_listening() {
    ss -lnt 'sport = :8888' 2>/dev/null | grep -q ':8888'
}

# --- Start tinyproxy (daemonizes by default; skip if already running so this
#     script is safe to re-run on a live container, e.g. `dev --enable-firewall`).
#     If already running, SIGHUP it so the just-rewritten filter is picked up. ---
if tinyproxy_listening; then
    echo "firewall-init: tinyproxy already listening on 127.0.0.1:8888, reloading filter"
    if [ -f /run/tinyproxy.pid ]; then
        kill -HUP "$(cat /run/tinyproxy.pid)"
    else
        pkill -HUP -x tinyproxy
    fi
else
    if ! tinyproxy -c "$CONF"; then
        echo "firewall-init: tinyproxy failed to start" >&2
        exit 1
    fi
    for _ in {1..10}; do
        tinyproxy_listening && break
        sleep 0.2
    done
    if ! tinyproxy_listening; then
        echo "firewall-init: tinyproxy did not bind to 127.0.0.1:8888" >&2
        exit 1
    fi
fi

# --- Apply iptables rules ---
PROXY_UID="$(id -u proxy)"

# Reset OUTPUT chain (idempotent across container restarts)
iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
iptables -P INPUT ACCEPT   # docker port forwarding lives here

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" \
                  -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Optional: punch a hole to specific ports on the host gateway. Set by
# `dev --host-port PORT`, which also adds --add-host=host.docker.internal:host-gateway
# at run time. Scoped to the gateway IP only so the firewall still default-drops
# every other destination. Fail-closed: if the hostname doesn't resolve or any
# port is invalid, the firewall does not come up.
if [ -n "${DEVCONTAINER_HOST_PORTS:-}" ]; then
    HOST_GW="$(getent ahostsv4 host.docker.internal 2>/dev/null | awk 'NR==1 {print $1}')" || true
    if [ -z "$HOST_GW" ]; then
        echo "firewall-init: DEVCONTAINER_HOST_PORTS set but host.docker.internal does not resolve" >&2
        exit 1
    fi
    IFS=',' read -ra _HOST_PORTS <<< "$DEVCONTAINER_HOST_PORTS"
    for port in "${_HOST_PORTS[@]}"; do
        port="${port//[[:space:]]/}"
        [ -z "$port" ] && continue
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "firewall-init: invalid host port '$port' in DEVCONTAINER_HOST_PORTS" >&2
            exit 1
        fi
        iptables -A OUTPUT -p tcp -d "$HOST_GW" --dport "$port" -j ACCEPT
    done
    echo "firewall-init: opened host gateway $HOST_GW for ports: $DEVCONTAINER_HOST_PORTS"
fi

# Log packets that fell through every ACCEPT above — i.e. exactly what the
# default-DROP policy is about to discard. Rate-limited so a noisy app cannot
# flood the netlink buffer. Read with `tcpdump -i nflog:1` (see `dev --monitor-fw`).
iptables -A OUTPUT -m limit --limit 60/min --limit-burst 20 \
                  -j NFLOG --nflog-group 1 --nflog-prefix "FW-DROP"

echo "firewall-init: ready ($(wc -l < "$FILTER") allowlist entries, proxy uid=$PROXY_UID)"
