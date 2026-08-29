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

# Always-on in every mode: link-local (169.254/16 here for v4; fe80::/10 for
# v6 is re-asserted separately below, immediately after the v6 OUTPUT flush,
# since that flush would otherwise wipe it) carries the cloud metadata
# endpoint (169.254.169.254 on AWS/GCP/Azure/Oracle), a network path to host
# credentials. Rules precede the chain policy, so this holds whether OUTPUT
# policy ends up ACCEPT (open) or DROP (closed). If the container's own
# resolver is link-local, exempt it so DNS still resolves.
install_baseline_blocks() {
    local ns
    while read -r _ ns _; do
        case "$ns" in
          169.254.*) iptables  -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
                     iptables  -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT ;;
        esac
    done < <(grep '^nameserver ' /etc/resolv.conf 2>/dev/null)
    install_host_port_holes
    iptables -A OUTPUT -d 169.254.0.0/16 -j DROP
}

# Punch the `dev up --host-port PORT` holes BEFORE the link-local DROP above
# appends, and in BOTH egress modes: podman >=5's pasta backend maps the
# host-gateway sentinel to a LINK-LOCAL address (169.254.1.2 by default), so
# an ACCEPT appended after the DROP can never match — and open mode's ACCEPT
# policy doesn't help either, because the DROP precedes it. Scoped to the
# resolved gateway IP plus the declared ports only, so every other
# link-local destination (the metadata endpoint included) stays dropped.
# `dev` sets DEVCONTAINER_HOST_PORTS at container creation and pairs it with
# --add-host=host.docker.internal:host-gateway. Fail-closed: an unresolvable
# gateway or an invalid port refuses container start.
#
# Loopback resolutions are skipped when picking the gateway: rootless podman
# seeds the container's /etc/hosts from the HOST's /etc/hosts, so a host-side
# "127.0.0.1 ... host.docker.internal" line would otherwise shadow the
# --add-host entry and punch the hole for the container's own loopback. The
# cloud metadata IP itself is refused outright — no host mapping may weaken
# the block above.
install_host_port_holes() {
    [ -n "${DEVCONTAINER_HOST_PORTS:-}" ] || return 0
    local gw port
    gw="$(getent ahostsv4 host.docker.internal 2>/dev/null \
          | awk '$1 !~ /^127\./ {print $1; exit}')" || true
    if [ -z "$gw" ]; then
        echo "firewall-init: DEVCONTAINER_HOST_PORTS set but host.docker.internal does not resolve to a non-loopback address" >&2
        exit 1
    fi
    if [ "$gw" = "169.254.169.254" ]; then
        echo "firewall-init: refusing host-port hole to the cloud metadata IP" >&2
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
        iptables -A OUTPUT -p tcp -d "$gw" --dport "$port" -j ACCEPT
    done
    echo "firewall-init: opened host gateway $gw for ports: $DEVCONTAINER_HOST_PORTS" >&2
}

# Open-mode egress is unfiltered at the IP layer but must stay observable:
# log the first packet (SYN) of every new outbound TCP connection, plus every
# outbound DNS query (name resolution is the cheapest signal for "what host
# is this talking to"), both rate limited so a noisy process cannot flood the
# netlink buffer. Both land in the same NFLOG group so a single
# `tcpdump -i nflog:2` reader sees DNS names and connection tuples together
# (mirrors the closed-mode FW-DROP group 1 convention) — no CAP_NET_RAW
# `tcpdump -i any` capture needed, only the CAP_NET_ADMIN the container
# already has. Takes the iptables binary (and any flags, e.g. "ip6tables -w")
# to run as its arguments, so the same rules can be installed for both
# families.
install_egress_logging() {
    "$@" -A OUTPUT -m limit --limit 60/min --limit-burst 20 \
        -p tcp --syn -j NFLOG --nflog-group 2 --nflog-prefix "FW-CONN"
    "$@" -A OUTPUT -p udp --dport 53 -m limit --limit 120/min --limit-burst 30 \
        -j NFLOG --nflog-group 2 --nflog-prefix "FW-DNS"
    "$@" -A OUTPUT -p tcp --dport 53 -m limit --limit 120/min --limit-burst 30 \
        -j NFLOG --nflog-group 2 --nflog-prefix "FW-DNS"
}

# --- Apply iptables rules ---
PROXY_UID="$(id -u proxy)"

# Reset OUTPUT chain (idempotent across container restarts)
iptables -F OUTPUT
iptables -P FORWARD DROP
iptables -P INPUT ACCEPT   # docker port forwarding lives here

# In open mode, install the DNS-query/new-connection NFLOG rules *before*
# install_baseline_blocks, not after: NFLOG is a non-terminating target (it
# logs, then falls through to the next rule), so logging first doesn't
# change what gets accepted or dropped below — but it does mean these rules
# still see traffic that a later rule is about to ACCEPT outright.
# install_baseline_blocks's link-local-resolver exemption is exactly such a
# rule: rootless podman's pasta/slirp4netns commonly points /etc/resolv.conf
# at a 169.254.x gateway resolver, and that exemption ACCEPTs port-53 traffic
# to it unconditionally. Installed afterward, the DNS NFLOG rule would never
# fire for the container's own (very common) resolver — installed before, the
# query is logged and then still ACCEPTed exactly as before.
if [ "${DEVCONTAINER_EGRESS:-closed}" = "open" ]; then
    install_egress_logging iptables
fi

# Baseline blocks first, so they occupy the earliest slots in the chain and
# take precedence over every ACCEPT rule added below (including the
# ESTABLISHED,RELATED short-circuit) and over the open-mode ACCEPT policy.
install_baseline_blocks

if [ "${DEVCONTAINER_EGRESS:-closed}" = "open" ]; then
    # Open mode: everything except link-local (already dropped above) is
    # allowed at the IP layer. No proxy, no allowlist. Egress stays
    # observable via install_egress_logging, installed above (new-connection
    # + DNS-query NFLOG).
    iptables -P OUTPUT ACCEPT
    echo "firewall-init: egress OPEN (link-local blocked; connections + DNS logged to NFLOG group 2)" >&2
else
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

    # --- Start tinyproxy (daemonizes by default; skip if already running so
    #     this script is safe to re-run on a live container, e.g. `dev fw
    #     on`). If already running, SIGHUP it so the just-rewritten filter is
    #     picked up. ---
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

    iptables -P OUTPUT DROP
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" \
                      -p tcp -m multiport --dports 80,443 -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # (--host-port holes are installed by install_host_port_holes above,
    # before the link-local DROP — see that function for why the placement
    # matters.)

    # Log packets that fell through every ACCEPT above — i.e. exactly what the
    # default-DROP policy is about to discard. Rate-limited so a noisy app cannot
    # flood the netlink buffer. Read with `tcpdump -i nflog:1` (see `dev fw drops`).
    iptables -A OUTPUT -m limit --limit 60/min --limit-burst 20 \
                      -j NFLOG --nflog-group 1 --nflog-prefix "FW-DROP"
fi

# --- Mirror the egress policy for IPv6 ---
# iptables above only filters IPv4. Some runtimes give the container a global
# IPv6 default route (podman 5's pasta does by default), and with ip6tables
# left at ACCEPT that route is a complete firewall bypass. Same rules, same
# fail-closed posture. (The host-port holes are IPv4-only by construction:
# host.docker.internal resolves to the v4 host gateway.)
if ip6tables -w -F OUTPUT 2>/dev/null; then
    ip6tables -w -P FORWARD DROP
    ip6tables -w -P INPUT ACCEPT

    # Re-assert the link-local block that the flush above just wiped (see
    # install_baseline_blocks), before either branch below sets the OUTPUT
    # policy — so it holds whether that policy ends up ACCEPT (open) or DROP
    # (closed).
    ip6tables -w -A OUTPUT -d fe80::/10 -j DROP 2>/dev/null || true
    # AWS's IPv6 IMDS endpoint lives outside fe80::/10 (a ULA, not
    # link-local) so the rule above does not cover it. Block it here too,
    # present in both open and closed mode.
    ip6tables -w -A OUTPUT -d fd00:ec2::254/128 -j DROP 2>/dev/null || true

    if [ "${DEVCONTAINER_EGRESS:-closed}" = "open" ]; then
        install_egress_logging ip6tables -w
        ip6tables -w -P OUTPUT ACCEPT
    else
        ip6tables -w -P OUTPUT DROP
        ip6tables -w -A OUTPUT -o lo -j ACCEPT
        ip6tables -w -A OUTPUT -p udp --dport 53 -j ACCEPT
        ip6tables -w -A OUTPUT -p tcp --dport 53 -j ACCEPT
        ip6tables -w -A OUTPUT -m owner --uid-owner "$PROXY_UID" \
                          -p tcp -m multiport --dports 80,443 -j ACCEPT
        ip6tables -w -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        ip6tables -w -A OUTPUT -m limit --limit 60/min --limit-burst 20 \
                          -j NFLOG --nflog-group 1 --nflog-prefix "FW-DROP6"
    fi
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
echo "firewall-init: ready (mode=${DEVCONTAINER_EGRESS:-closed}, proxy uid=$PROXY_UID)" >&2
