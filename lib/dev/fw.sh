# shellcheck shell=bash
# lib/dev/fw.sh — `dev fw` handlers (off, on, log, drops).
# Sourced by dev; not executed directly.

# cmd_fw <action> [args]: the `dev fw` verb. Validates the action (each takes no
# extra arguments), then dispatches to the fw_* handler, all of which exec or
# exit.
cmd_fw() {
  fw_action="${1:-}"
  case "$fw_action" in
    log|drops|on)
      shift
      # These share a strict no-extra-args branch (consistent with
      # reset/update). `on` is an alias for `enable`: map it after
      # validation so the dispatch below only needs to handle `enable`.
      if [[ $# -gt 0 ]]; then
        echo "Error: dev fw $fw_action does not take extra arguments: $*" >&2
        exit 1
      fi
      [[ "$fw_action" == on ]] && fw_action=enable
      ;;
    off)
      shift
      # `off` never cold-starts: it only toggles an already-running
      # container's firewall off, and errors instead of falling through to
      # the default start path.
      if [[ $# -gt 0 ]]; then
        echo "Error: dev fw off does not take extra arguments: $*" >&2
        echo "       To start a fresh container with the firewall open, use 'dev up --open'." >&2
        exit 1
      fi
      ;;
    disable)
      echo "Error: 'fw disable' was renamed: use 'dev fw off' (running container) or 'dev up --open' (fresh)." >&2
      exit 1
      ;;
    enable)
      echo "Error: 'fw enable' was renamed: use 'dev fw on'." >&2
      exit 1
      ;;
    *)
      echo "Error: dev fw: expected an action (off|on|log|drops), got '${fw_action:-<none>}'" >&2
      echo "Run 'dev --help' for usage information" >&2
      exit 1
      ;;
  esac
  detect_runtime
  ensure_runtime_ready
  _resolve_workspace_names
  case "$fw_action" in
    log)     fw_log ;;
    drops)   fw_drops ;;
    enable)  fw_enable ;;
    off)     fw_off_running_only ;;
  esac
  # Every fw_* handler above exec's or exits; the explicit exit keeps the
  # router's "no arm falls through" invariant local to this function.
  exit
}

# fw_log: stream tinyproxy's log from the running workspace firewall
# container. Requires a firewall-capable container (normal or dind) to
# already be running; never returns (execs into `tail`).
fw_log() {
  require_workspace_firewall_container "fw log"
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec -it "$MANAGED_NAME" tail -F /var/log/tinyproxy.log
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

# fw_enable: re-enable iptables on an already-running firewall container.
# Only makes sense on a running container, so it requires one via
# require_workspace_firewall_container. Never returns (execs into
# firewall-init.sh).
fw_enable() {
  require_workspace_firewall_container "fw on"
  # shellcheck disable=SC2086  # intentional word-splitting of $MANAGED_RUNTIME_ARGS
  exec $RUNTIME $MANAGED_RUNTIME_ARGS exec --user root "$MANAGED_NAME" /usr/local/sbin/firewall-init.sh
}

# fw_off_running_only: toggle a running firewall container's iptables off in
# place. Never cold-starts: if nothing is running for this workspace, it
# errors and points at 'dev up --open' instead of falling through to a
# fresh start.
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
