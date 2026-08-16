# shellcheck shell=bash
# lib/dev/fw.sh — `dev fw` handlers (open, close, log, drops).
# Sourced by dev; not executed directly.

# cmd_fw <action> [args]: the `dev fw` verb. Validates the action (each takes no
# extra arguments), then dispatches to the fw_* handler, all of which exec or
# exit.
cmd_fw() {
  fw_action="${1:-}"
  case "$fw_action" in
    log|drops|close)
      shift
      # These share a strict no-extra-args branch (consistent with
      # reset/update).
      if [[ $# -gt 0 ]]; then
        echo "Error: dev fw $fw_action does not take extra arguments: $*" >&2
        exit 1
      fi
      ;;
    open)
      shift
      # `open` never cold-starts: it only toggles an already-running
      # container's firewall open, and errors instead of falling through to
      # the default start path.
      if [[ $# -gt 0 ]]; then
        echo "Error: dev fw open does not take extra arguments: $*" >&2
        echo "       To start a fresh container in open egress mode, use 'dev up --open'." >&2
        exit 1
      fi
      ;;
    off)
      echo "Error: 'fw off' was renamed: use 'dev fw open'." >&2
      exit 1
      ;;
    on)
      echo "Error: 'fw on' was renamed: use 'dev fw close'." >&2
      exit 1
      ;;
    disable)
      echo "Error: 'fw disable' was renamed: use 'dev fw open' (running container) or 'dev up --open' (fresh)." >&2
      exit 1
      ;;
    enable)
      echo "Error: 'fw enable' was renamed: use 'dev fw close'." >&2
      exit 1
      ;;
    *)
      echo "Error: dev fw: expected an action (open|close|log|drops), got '${fw_action:-<none>}'" >&2
      echo "Run 'dev --help' for usage information" >&2
      exit 1
      ;;
  esac
  detect_runtime
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  NEEDS_ENGINE=true
  ensure_runtime_ready
  _resolve_workspace_names
  case "$fw_action" in
    log)   fw_log ;;
    drops) fw_drops ;;
    close) fw_close ;;
    open)  fw_open_running_only ;;
  esac
  # Every fw_* handler above exec's or exits; the explicit exit keeps the
  # router's "no arm falls through" invariant local to this function.
  exit
}

# fw_log: stream the running workspace firewall container's egress activity.
# Mode-aware: closed mode has tinyproxy (hostname-level log); open mode has no
# proxy, so URLs/headers aren't available — fall back to tcpdump on the DNS
# port and the FW-CONN NFLOG group firewall-init.sh installs for open mode
# (see install_egress_logging), which gives hostnames-via-DNS plus raw
# connection tuples instead. Requires a firewall-capable container (normal or
# dind/pind) to already be running; never returns.
fw_log() {
  require_workspace_firewall_container "fw log"
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  _fw_log_mode="$($RUNTIME $MANAGED_RUNTIME_ARGS exec "$MANAGED_NAME" printenv DEVCONTAINER_EGRESS 2>/dev/null || true)"
  if [[ "$_fw_log_mode" == open ]]; then
    # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
    exec $RUNTIME $MANAGED_RUNTIME_ARGS exec -it --user root "$MANAGED_NAME" \
        sh -c 'tcpdump -i any -nn -l port 53 & tcpdump -i nflog:2 -nn -l'
  else
    # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
    exec $RUNTIME $MANAGED_RUNTIME_ARGS exec -it "$MANAGED_NAME" tail -F /var/log/tinyproxy.log
  fi
}

# fw_drops: tcpdump on the NFLOG group set by firewall-init.sh, showing
# packets the firewall dropped. Needs CAP_NET_ADMIN (the container already
# has it) and root inside the container. Never returns (execs into
# `tcpdump`).
fw_drops() {
  require_workspace_firewall_container "fw drops"
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec -it --user root "$MANAGED_NAME" \
      tcpdump -i nflog:1 -nn -l
}

# fw_close: re-run firewall-init.sh on an already-running firewall container
# to (re)close egress — rebuilds the allowlist filter and restores the
# default-deny iptables policy. Only makes sense on a running container, so it
# requires one via require_workspace_firewall_container. Never returns (execs
# into firewall-init.sh).
fw_close() {
  require_workspace_firewall_container "fw close"
  # Override the container's own DEVCONTAINER_EGRESS (which may be "open" on
  # a container started via --open/DEV_EGRESS=open): without this, exec
  # inherits that env and firewall-init.sh re-runs its OPEN branch, silently
  # leaving OUTPUT ACCEPT and no tinyproxy while still printing "ready".
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec --user root -e DEVCONTAINER_EGRESS=closed "$MANAGED_NAME" /usr/local/sbin/firewall-init.sh
}

# fw_open_running_only: toggle a running firewall container's iptables open in
# place. Never cold-starts: if nothing is running for this workspace, it
# errors and points at 'dev up --open' instead of falling through to a
# fresh start.
fw_open_running_only() {
  resolve_managed_container
  if [[ "$MANAGED_TARGET" == "maint" ]]; then
    echo "Error: maintenance container ${MAINT_NAME} has no firewall — 'dev fw open' is meaningless in maintenance mode." >&2
    exit 1
  elif [[ -n "$MANAGED_TARGET" ]]; then
    # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
    exec $RUNTIME $MANAGED_RUNTIME_ARGS exec --user root "$MANAGED_NAME" /usr/local/sbin/firewall-disable.sh
  else
    echo "Error: nothing running for this workspace." >&2
    echo "       'dev up --open' starts a fresh container with egress already open." >&2
    exit 1
  fi
}
