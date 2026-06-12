#!/bin/bash
# /usr/local/sbin/firewall-disable.sh
#
# Tear down the egress firewall on a running container WITHOUT restarting it.
# Runs as root. Idempotent: safe to re-run.
#
# Two callers, one behaviour:
#   - `dev --disable-firewall` on a running container (exec'd here)
#   - entrypoint.sh, when DEVCONTAINER_FW_DISABLED=1, after firewall-init.sh
#     has set up tinyproxy + iptables (so a fresh container can come up with
#     the firewall already open, identical to start-then-disable).
#
# Opens the kernel egress AND switches tinyproxy to allow-all (permissive
# filter + SIGHUP) so HTTP_PROXY-honouring clients also get through, not just
# direct / --noproxy traffic. This requires tinyproxy to already be running.
set -eu

# Open the kernel egress.
iptables -F OUTPUT
iptables -P OUTPUT ACCEPT

# Switch tinyproxy to an allow-all filter and reload it in place.
printf '%s\n' '^.*$' > /etc/tinyproxy/filter
if [ -f /run/tinyproxy.pid ]; then
    kill -HUP "$(cat /run/tinyproxy.pid)"
else
    pkill -HUP -x tinyproxy 2>/dev/null || true
fi

echo 'firewall disabled'
