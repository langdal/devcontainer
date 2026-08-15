#!/bin/bash
# /usr/local/sbin/firewall-disable.sh
#
# Tear down the egress firewall on a running container WITHOUT restarting it.
# Runs as root. Idempotent: safe to re-run.
#
# Two callers, one behaviour:
#   - `dev fw off` on a running container (exec'd here)
#   - entrypoint.sh, when DEVCONTAINER_FW_DISABLED=1, after firewall-init.sh
#     has set up tinyproxy + iptables (so a fresh container can come up with
#     the firewall already open, identical to start-then-disable).
#
# Opens the kernel egress AND switches tinyproxy to allow-all (permissive
# filter + SIGHUP) so HTTP_PROXY-honouring clients also get through, not just
# direct / --noproxy traffic. This requires tinyproxy to already be running.
#
# --- Threat model (see SECURITY.md) ---
# May: tear down the egress firewall — this IS the explicit, documented,
# opt-in escape hatch (dev fw off / dev up --open / DEVCONTAINER_FW_DISABLED).
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
echo "  Re-enable with:  dev fw on"
echo "=========================================================="
echo
EOF
chmod 644 /etc/profile.d/zz-fw-disabled-banner.sh

echo 'firewall disabled'
