# shellcheck shell=bash
# lib/dev/status.sh — `dev down` and `dev status` handlers.
# Sourced by dev; not executed directly.

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

# One line per running container: mode, name, engine status, firewall state.
# Firewall state is inferred from the banner file that firewall-disable.sh
# writes and firewall-init.sh removes — no firewall logic re-implemented here.
status_workspace() {
  local any=false
  _status_one() {
    local name="$1" mode="$2" args="${3-}"
    local st fw
    if ! container_running "$name" "$args"; then
      return 0
    fi
    # shellcheck disable=SC2086  # intentional word-splitting of $args
    st=$($RUNTIME $args ps --filter "name=^${name}\$" --format '{{.Status}}' 2>/dev/null | head -1) || true
    [[ -n "$st" ]] || return 0
    any=true
    fw="firewall on"
    # shellcheck disable=SC2086  # intentional word-splitting of $args
    if [[ "$mode" == maintenance ]]; then
      fw="no firewall (maintenance)"
    elif $RUNTIME $args exec "$name" test -f /etc/profile.d/zz-fw-disabled-banner.sh >/dev/null 2>&1; then
      fw="firewall OFF"
    fi
    printf '%-12s %-30s %s — %s\n' "$mode" "$name" "$st" "$fw"
  }
  _status_one "$NORMAL_NAME" normal
  _status_one "$MAINT_NAME" maintenance
  _status_one "$DIND_NAME" dind "$DIND_RUNTIME_ARGS"
  _status_one "$PIND_NAME" pind "$DIND_RUNTIME_ARGS"
  [[ "$any" == true ]] || echo "Nothing running for this workspace. 'dev up' starts one."
}
