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

# Resolve the msb binary once (it is often not on the default non-login PATH).
MSB_BIN="${MSB_BIN:-$(command -v msb 2>/dev/null || echo "$HOME/.local/bin/msb")}"

# _msb ARGS...  -> run `msb` unless BOX_DRY_RUN is set, then just print.
# This is the test seam: all execution goes through here.
_msb() {
  if [[ -n "${BOX_DRY_RUN:-}" ]]; then
    printf 'msb %s\n' "$*"
  else
    "$MSB_BIN" "$@"
  fi
}

# msb_is_running NAME -> 0 if a named sandbox is currently running.
# Dry-run short-circuits to "not running".
msb_is_running() {
  [[ -n "${BOX_DRY_RUN:-}" ]] && return 1
  "$MSB_BIN" ps -q 2>/dev/null | grep -Fxq "$1"
}

# msb_up NAME IMAGE WORKSPACE MODE [HOST...]
# Boots a detached, persistent named sandbox with volumes, workspace, egress.
# Detached run ignores a trailing command, so callers exec separately (msb_attach).
msb_up() {
  local name="$1" image="$2" workspace="$3" mode="$4"; shift 4
  local hosts=("$@")
  local args=(run -d --name "$name")
  mapfile -t mounts < <(msb_mount_args "$workspace" box-mise:/mise box-home:/home/vscode)
  mapfile -t net < <(msb_net_args "$mode" "${hosts[@]}")
  args+=("${mounts[@]}" "${net[@]}" "$image")
  _msb "${args[@]}"
}

# msb_attach NAME -- CMD...  -> run CMD in an already-running named sandbox.
msb_attach() {
  local name="$1"; shift
  if [[ "${1:-}" == "--" ]]; then shift; fi
  _msb exec "$name" -- "$@"
}
