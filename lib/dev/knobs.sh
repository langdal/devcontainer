# shellcheck shell=bash
# lib/dev/knobs.sh — validation of the host env knobs the start flow consumes
# before it parses a single flag: DEV_EGRESS (the egress-mode default) and
# DEV_MTU (the container interface MTU). Split out of lib/dev/up.sh's
# cmd_start when that file reached its 300-line lint budget (scripts/lint.sh).
# Sourced by dev; not executed directly.

# Resolve/validate the env knobs. Sets EGRESS_MODE (global, refined later by
# --open/--closed in cmd_start). Exits 2 on a malformed value, so a typo fails
# fast rather than being silently ignored inside the container.
resolve_env_knobs() {
  # Precedence: explicit --open/--closed (cmd_start) > DEV_EGRESS > default open.
  case "${DEV_EGRESS:-open}" in
    open|closed) EGRESS_MODE="${DEV_EGRESS:-open}" ;;
    *) echo "Error: DEV_EGRESS must be 'open' or 'closed', got '$DEV_EGRESS'" >&2; exit 2 ;;
  esac
  # DEV_MTU: container interface MTU, applied by entrypoint.sh at creation
  # (lib/dev/lifecycle.sh forwards it as DEVCONTAINER_MTU). For hosts whose
  # VPN shrank the uplink below 1500; `dev doctor` (uplink-mtu) suggests a
  # value. 576 is the IPv4 minimum.
  if [[ -n "${DEV_MTU:-}" ]]; then
    if ! [[ "$DEV_MTU" =~ ^[0-9]+$ ]] || [[ "$DEV_MTU" -lt 576 || "$DEV_MTU" -gt 65535 ]]; then
      echo "Error: DEV_MTU must be an integer between 576 and 65535, got '$DEV_MTU'" >&2; exit 2
    fi
  fi
}
