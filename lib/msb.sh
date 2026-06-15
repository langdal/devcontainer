# shellcheck shell=bash
# === microsandbox boundary ===
# The ONLY file that knows `msb` syntax. If microsandbox changes, fix it here.
# Syntax confirmed in docs/superpowers/SPIKE-microsandbox.md (Task 0).
# Arg-builder functions emit one token per line; callers use `mapfile -t`.

# msb_net_args MODE [HOST...] -> egress flags.
#   full       = open egress (provision)
#   none       = deny all (airgapped)
#   sanctioned = deny by default, allow each HOST on tcp:443 (no DNS rule needed)
msb_net_args() {
  local mode="$1"; shift || true
  case "$mode" in
    full)
      printf '%s\n' --net-default-egress allow
      ;;
    none)
      printf '%s\n' --net-default-egress deny
      ;;
    sanctioned)
      printf '%s\n' --net-default-egress deny
      if [[ $# -gt 0 ]]; then
        local rules="" h
        for h in "$@"; do
          [[ -n "$rules" ]] && rules="${rules},"
          rules="${rules}allow@${h}:tcp:443"
        done
        printf '%s\n' --net-rule "$rules"
      fi
      ;;
    *)
      echo "msb_net_args: unknown mode '$mode'" >&2
      return 1
      ;;
  esac
}

# msb_mount_args WORKSPACE [VOLUME:GUEST...] -> mount flags.
msb_mount_args() {
  local workspace="$1"; shift || true
  printf '%s\n' --mount-dir "${workspace}:/workspace"
  local v
  for v in "$@"; do
    printf '%s\n' --mount-named "$v"
  done
}

# msb_secret_args [ENV@HOST...] -> secret flags (empty if none).
msb_secret_args() {
  local s
  for s in "$@"; do
    printf '%s\n' --secret "$s"
  done
}
