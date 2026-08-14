# shellcheck shell=bash
# lib/dev/fw.sh — `dev fw` handlers (log, drops, enable, disable).
# Sourced by dev; not executed directly.

# fw_log: stream tinyproxy's log from the running workspace firewall
# container. Requires a firewall-capable container (normal or dind) to
# already be running; never returns (execs into `tail`).
fw_log() {
  require_workspace_firewall_container "--monitor/--monitor-fw"
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec -it "$MANAGED_NAME" tail -F /var/log/tinyproxy.log
}

# fw_drops: tcpdump on the NFLOG group set by firewall-init.sh, showing
# packets the firewall dropped. Needs CAP_NET_ADMIN (the container already
# has it) and root inside the container. Never returns (execs into
# `tcpdump`).
fw_drops() {
  require_workspace_firewall_container "--monitor/--monitor-fw"
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec -it --user root "$MANAGED_NAME" \
      tcpdump -i nflog:1 -nn -l
}

# fw_enable: re-enable iptables on an already-running firewall container.
# Only makes sense on a running container, so it requires one via
# require_workspace_firewall_container. Never returns (execs into
# firewall-init.sh).
fw_enable() {
  require_workspace_firewall_container "--enable-firewall"
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec --user root "$MANAGED_NAME" /usr/local/sbin/firewall-init.sh
}

# fw_disable: toggle a running firewall container's iptables off in place,
# or — if no firewall-capable container is running for this workspace —
# fall through to a fresh start with the firewall disabled from the start.
#
# Unlike the other three handlers this does NOT always exec: in the
# no-container case it sets the global FW_DISABLED_START=true and returns 0
# so the caller (dev's main flow) continues on into the normal startup path
# with DEVCONTAINER_FW_DISABLED=1, producing the same end state as
# start-then-disable. The toggle case (a container is already running)
# still execs into firewall-disable.sh and never returns.
fw_disable() {
  resolve_managed_container
  if [[ "$MANAGED_TARGET" == "maint" ]]; then
    echo "Error: maintenance container ${MAINT_NAME} has no firewall — --disable-firewall is meaningless in maintenance mode." >&2
    exit 1
  elif [[ -n "$MANAGED_TARGET" ]]; then
    # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
    exec $RUNTIME $MANAGED_RUNTIME_ARGS exec --user root "$MANAGED_NAME" /usr/local/sbin/firewall-disable.sh
  else
    # shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
    FW_DISABLED_START=true
    return 0
  fi
}

# fw_off_running_only: toggle a running firewall container's iptables off in
# place, same as fw_disable's running-container branch. Unlike fw_disable,
# this NEVER cold-starts: if nothing is running for this workspace, it
# errors instead of falling through to the default start path (that
# fallthrough is being replaced by 'dev up --open').
fw_off_running_only() {
  resolve_managed_container
  if [[ "$MANAGED_TARGET" == "maint" ]]; then
    echo "Error: maintenance container ${MAINT_NAME} has no firewall — 'dev fw off' is meaningless in maintenance mode." >&2
    exit 1
  elif [[ -n "$MANAGED_TARGET" ]]; then
    # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
    exec $RUNTIME $MANAGED_RUNTIME_ARGS exec --user root "$MANAGED_NAME" /usr/local/sbin/firewall-disable.sh
  else
    echo "Error: nothing running for this workspace." >&2
    echo "       'dev up --open' starts a fresh container with the firewall already open." >&2
    exit 1
  fi
}
