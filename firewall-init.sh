#!/bin/bash
# /usr/local/sbin/firewall-init.sh
#
# Configure tinyproxy and iptables to enforce a hostname allowlist.
# Runs as root at container startup.  Fail-closed: any error => non-zero exit.
#
# --- Threat model (see SECURITY.md) ---
# May: program iptables/ip6tables to default-DROP OUTPUT (v4+v6), write the
# tinyproxy config/filter from BAKED (allowlist.base) and APPROVED
# (/etc/devcontainer/project/allowlist.approved) allowlist material only.
# Must never: read allowlist material from /workspace (agent-writable), or
# weaken/skip any rule based on an env var an in-container process can set.
set -euo pipefail

BASE=/etc/devcontainer/allowlist.base
# Approved snapshot mounted read-only by dev (see approve_project_allowlist).
# NEVER read the workspace copy here: /workspace is agent-writable, and an
# agent may not extend its own egress allowlist.
PROJECT=/etc/devcontainer/project/allowlist.approved
FILTER=/etc/tinyproxy/filter
CONF=/etc/tinyproxy/tinyproxy.conf

mkdir -p /etc/tinyproxy /var/log /run

# Convert allowlist entries (stdin) to anchored tinyproxy ERE lines (stdout).
# Fail closed on any entry that is not a bare hostname or a *.suffix wildcard:
# a stray ERE metacharacter (|, *, +, (, ), [, ], {, }, ^, $, \, ?) would
# otherwise be injected into a FilterExtended regex and could match every
# host (e.g. "x|" -> "^x|$" -> matches all). See SECURITY.md C1.
allowlist_to_filter() {
    local entry tail escaped
    while IFS= read -r entry; do
        if [[ "$entry" == \*.* ]]; then
            tail="${entry#*.}"
            if [[ ! "$tail" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; then
                echo "firewall-init: refusing malformed allowlist wildcard: $entry" >&2
                return 1
            fi
            escaped="${tail//./\\.}"
            printf '^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.%s$\n' "$escaped"
        else
            if [[ ! "$entry" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; then
                echo "firewall-init: refusing malformed allowlist entry: $entry" >&2
                return 1
            fi
            escaped="${entry//./\\.}"
            printf '^%s$\n' "$escaped"
        fi
    done
}

# Always-on in every mode: link-local (169.254/16, fe80::/10) carries the
# cloud metadata endpoint (169.254.169.254 on AWS/GCP/Azure/Oracle), a network
# path to host credentials. Rules precede the chain policy, so this holds
# whether OUTPUT policy is ACCEPT (open) or DROP (closed). If the container's
# own resolver is link-local, exempt it so DNS still resolves.
install_baseline_blocks() {
    local ns
    while read -r _ ns _; do
        case "$ns" in
          169.254.*) iptables  -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
                     iptables  -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT ;;
        esac
    done < <(grep '^nameserver ' /etc/resolv.conf 2>/dev/null)
    iptables  -A OUTPUT -d 169.254.0.0/16 -j DROP
    ip6tables -w -A OUTPUT -d fe80::/10    -j DROP 2>/dev/null || true
}

# --- Merge base + project allowlist into a tinyproxy regex filter ---
{
    cat "$BASE"
    if [ -f "$PROJECT" ]; then
        cat "$PROJECT"
    fi
    if { [ -n "${DEVCONTAINER_DIND:-}" ] || [ -n "${DEVCONTAINER_PIND:-}" ]; } \
       && [ -f /etc/devcontainer/allowlist.dind ]; then
        cat /etc/devcontainer/allowlist.dind
    fi
} | sed 's/#.*//'           \
  | tr -d ' \t'             \
  | awk 'NF'                \
  | sort -u                 \
  | allowlist_to_filter > "$FILTER" || exit 1

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
#     script is safe to re-run on a live container, e.g. `dev fw on`).
#     If already running, SIGHUP it so the just-rewritten filter is picked up. ---
if tinyproxy_listening; then
    echo "firewall-init: tinyproxy already listening on 127.0.0.1:8888, reloading filter" >&2
    if [ -f /run/tinyproxy.pid ]; then
        kill -HUP "$(cat /run/tinyproxy.pid)"
    else
        pkill -HUP -x dc-tinyproxy
    fi
else
    # dc-tinyproxy is a copy of the tinyproxy binary at a path no host
    # AppArmor profile attaches to (see Dockerfile).
    if ! dc-tinyproxy -c "$CONF"; then
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

# Baseline blocks first, so they occupy the earliest slots in the chain and
# take precedence over every ACCEPT rule added below (including the
# ESTABLISHED,RELATED short-circuit).
install_baseline_blocks

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" \
                  -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Optional: punch a hole to specific ports on the host gateway. Set by
# `dev up --host-port PORT`, which also adds --add-host=host.docker.internal:host-gateway
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
    echo "firewall-init: opened host gateway $HOST_GW for ports: $DEVCONTAINER_HOST_PORTS" >&2
fi

# Log packets that fell through every ACCEPT above — i.e. exactly what the
# default-DROP policy is about to discard. Rate-limited so a noisy app cannot
# flood the netlink buffer. Read with `tcpdump -i nflog:1` (see `dev fw drops`).
iptables -A OUTPUT -m limit --limit 60/min --limit-burst 20 \
                  -j NFLOG --nflog-group 1 --nflog-prefix "FW-DROP"

# --- Mirror the egress policy for IPv6 ---
# iptables above only filters IPv4. Some runtimes give the container a global
# IPv6 default route (podman 5's pasta does by default), and with ip6tables
# left at ACCEPT that route is a complete firewall bypass. Same rules, same
# fail-closed posture. (The host-port holes are IPv4-only by construction:
# host.docker.internal resolves to the v4 host gateway.)
if ip6tables -w -F OUTPUT 2>/dev/null; then
    ip6tables -w -P OUTPUT DROP
    ip6tables -w -P FORWARD DROP
    ip6tables -w -P INPUT ACCEPT

    ip6tables -w -A OUTPUT -o lo -j ACCEPT
    ip6tables -w -A OUTPUT -p udp --dport 53 -j ACCEPT
    ip6tables -w -A OUTPUT -p tcp --dport 53 -j ACCEPT
    ip6tables -w -A OUTPUT -m owner --uid-owner "$PROXY_UID" \
                      -p tcp -m multiport --dports 80,443 -j ACCEPT
    ip6tables -w -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -w -A OUTPUT -m limit --limit 60/min --limit-burst 20 \
                      -j NFLOG --nflog-group 1 --nflog-prefix "FW-DROP6"
else
    # Kernel without ip6table_filter. That is only safe when the container
    # has no routable IPv6 at all; otherwise refuse rather than leave an
    # unfiltered egress path open.
    if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
        echo "firewall-init: cannot program ip6tables but a global IPv6 address is present — refusing to start with an unfiltered IPv6 egress path" >&2
        exit 1
    fi
    echo "firewall-init: ip6tables unavailable; no global IPv6 present, continuing IPv4-only" >&2
fi

# Clear the firewall-disabled banner if a previous toggle left one.
rm -f /etc/profile.d/zz-fw-disabled-banner.sh

# Diagnostics go to stderr: this script is invoked by entrypoint.sh purely
# for its side effects, so stdout must stay clean for the payload command
# in `dev -- <cmd>` (otherwise `x=$(dev -- some-cmd)` captures this line).
echo "firewall-init: ready ($(wc -l < "$FILTER") allowlist entries, proxy uid=$PROXY_UID)" >&2
