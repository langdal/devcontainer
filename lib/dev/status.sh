# shellcheck shell=bash
# lib/dev/status.sh — `dev down` and `dev status` handlers.
# Sourced by dev; not executed directly.

# cmd_down: the `dev down` verb.
cmd_down() {
  if [[ $# -gt 0 ]]; then
    echo "Error: 'dev down' takes no arguments." >&2; exit 2
  fi
  detect_runtime
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  NEEDS_ENGINE=false
  ensure_runtime_ready; _resolve_workspace_names
  down_workspace
  exit 0
}

# cmd_status: the `dev status` verb.
cmd_status() {
  if [[ $# -gt 0 ]]; then
    echo "Error: 'dev status' takes no arguments." >&2; exit 2
  fi
  detect_runtime
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  NEEDS_ENGINE=false
  ensure_runtime_ready; _resolve_workspace_names
  status_workspace
  exit 0
}

# Stop this workspace's container(s), whatever mode is running. Containers
# run with --rm, so stopping also removes them. Volumes are untouched
# ('dev reset' handles those).
down_workspace() {
  local stopped=false name
  for name in "$NORMAL_NAME" "$MAINT_NAME"; do
    if container_running "$name"; then
      echo "Stopping $name..."
      $RUNTIME stop "$name" >/dev/null 2>&1 || true
      stopped=true
    fi
  done
  for name in "$DIND_NAME" "$PIND_NAME"; do
    if container_running "$name" "$DIND_RUNTIME_ARGS"; then
      echo "Stopping $name..."
      # shellcheck disable=SC2086  # intentional word-splitting of DIND_RUNTIME_ARGS
      $RUNTIME $DIND_RUNTIME_ARGS stop "$name" >/dev/null 2>&1 || true
      stopped=true
    fi
  done
  [[ "$stopped" == true ]] || echo "Nothing running for this workspace."
}

# One line per running container: mode, name, engine status, firewall state,
# egress mode. Firewall state is inferred from the banner file that
# firewall-disable.sh writes and firewall-init.sh removes — no firewall logic
# re-implemented here. Egress mode is read from the container's own
# DEVCONTAINER_EGRESS env (default open when unset, e.g. an older container).
status_workspace() {
  local any=false
  _status_one() {
    local name="$1" mode="$2" args="${3-}"
    local st fw egress
    if ! container_running "$name" "$args"; then
      return 0
    fi
    # shellcheck disable=SC2086  # intentional word-splitting of $args
    st=$($RUNTIME $args ps --filter "name=^${name}\$" --format '{{.Status}}' 2>/dev/null | head -1) || true
    [[ -n "$st" ]] || return 0
    any=true
    if [[ "$mode" == maintenance ]]; then
      fw="no firewall (maintenance)"
      egress="n/a"
    else
      # `dev status` is the security-visibility surface, so it must not fail
      # open: a probe that cannot run has to read as unknown, never as "on".
      # `exec ... test -f` alone cannot distinguish "banner absent" (exit 1)
      # from "exec failed" (container exited mid-command, exec denied), so
      # have the probe *print* its verdict and treat anything else as unknown.
      local probe
      # shellcheck disable=SC2086  # intentional word-splitting of $args
      probe=$($RUNTIME $args exec "$name" sh -c \
        'test -f /etc/profile.d/zz-fw-disabled-banner.sh && echo OFF || echo ON' 2>/dev/null) || true
      case "$probe" in
        OFF) fw="firewall OFF" ;;
        ON)  fw="firewall on" ;;
        *)   fw="firewall ? (probe failed)" ;;
      esac
      # shellcheck disable=SC2086  # intentional word-splitting of $args
      egress=$($RUNTIME $args exec "$name" printenv DEVCONTAINER_EGRESS 2>/dev/null) || true
      [[ -n "$egress" ]] || egress="open"
    fi
    printf '%-12s %-30s %s — %s — egress=%s\n' "$mode" "$name" "$st" "$fw" "$egress"
  }
  _status_one "$NORMAL_NAME" normal
  _status_one "$MAINT_NAME" maintenance
  _status_one "$DIND_NAME" dind "$DIND_RUNTIME_ARGS"
  _status_one "$PIND_NAME" pind "$DIND_RUNTIME_ARGS"
  [[ "$any" == true ]] || echo "Nothing running for this workspace. 'dev up' starts one."
}
