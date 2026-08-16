#!/bin/bash
# /usr/local/sbin/firewall-disable.sh
#
# Tear down the egress firewall on a running container WITHOUT restarting it.
# Runs as root. Idempotent: safe to re-run.
#
# Two callers, one behaviour:
#   - `dev fw open` on a running container (exec'd here)
#   - entrypoint.sh, when DEVCONTAINER_EGRESS=open, after firewall-init.sh
#     has set up tinyproxy + iptables (so a fresh container can come up with
#     the firewall already open, identical to start-then-open — see
#     `dev up --open`).
#
# Opens the kernel egress AND switches tinyproxy to allow-all (permissive
# filter + SIGHUP) so HTTP_PROXY-honouring clients also get through, not just
# direct / --noproxy traffic. This requires tinyproxy to already be running.
#
# --- Threat model (see SECURITY.md) ---
# May: tear down the egress firewall — this IS the explicit, documented,
# opt-in escape hatch (dev fw open / dev up --open / DEVCONTAINER_EGRESS=open).
# Must never: run implicitly as a side effect of any other code path, or
# leave no visible signal (the banner file below) that egress is now open.
set -eu

# Open the kernel egress (both families; ip6tables tolerated missing on
# kernels without ip6table_filter — nothing was programmed there either).
iptables -F OUTPUT
iptables -P OUTPUT ACCEPT
if ip6tables -w -F OUTPUT 2>/dev/null; then
    ip6tables -w -P OUTPUT ACCEPT
fi

# Re-assert the always-on link-local block; opening egress must not open
# the path to the cloud metadata endpoint. This script runs standalone (it
# does not source firewall-init.sh), so the rules are inlined rather than
# calling install_baseline_blocks — but the resolver exemption below mirrors
# that function's loop exactly: if the container's own resolver is
# link-local, exempt it BEFORE the DROP so opening egress does not kill DNS.
while read -r _ ns _; do
    case "$ns" in
      169.254.*) iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
                 iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT ;;
    esac
done < <(grep '^nameserver ' /etc/resolv.conf 2>/dev/null)
iptables  -A OUTPUT -d 169.254.0.0/16   -j DROP
ip6tables -w -A OUTPUT -d fe80::/10     -j DROP 2>/dev/null || true
ip6tables -w -A OUTPUT -d fd00:ec2::254/128 -j DROP 2>/dev/null || true

# Reinstall the open-mode connection log (mirrors firewall-init.sh's open
# branch): without this, `dev fw open` leaves `dev fw log`/`fw drops` with
# only DNS traffic to show, since the FW-CONN NFLOG rule was never (re)added.
iptables -A OUTPUT -p tcp --syn -m limit --limit 60/min --limit-burst 20 \
    -j NFLOG --nflog-group 2 --nflog-prefix "FW-CONN"

# Switch tinyproxy to an allow-all filter and reload it in place.
# The HUP must not abort the script (set -e): a stale pidfile or an
# already-exited process would otherwise make entrypoint.sh refuse to
# start the container. Fall back to pkill, and tolerate "not running".
printf '%s\n' '^.*$' > /etc/tinyproxy/filter
if ! { [ -f /run/tinyproxy.pid ] && kill -HUP "$(cat /run/tinyproxy.pid)" 2>/dev/null; }; then
    pkill -HUP -x dc-tinyproxy 2>/dev/null || true
fi

# Visible signal for new shells: toggling the firewall does not change the
# container name, so leave a banner (mirrors the maintenance-mode banner).
cat > /etc/profile.d/zz-fw-disabled-banner.sh <<'EOF'
echo
echo "=========================================================="
echo "  FIREWALL DISABLED - all outbound traffic is allowed."
echo "  Re-enable with:  dev fw close"
echo "=========================================================="
echo
EOF
chmod 644 /etc/profile.d/zz-fw-disabled-banner.sh

echo 'firewall disabled'
