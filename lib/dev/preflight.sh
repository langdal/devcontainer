# shellcheck shell=bash
# lib/dev/preflight.sh — host/runtime detection and --dind preflights.
# Sourced by dev; not executed directly.

# Pick host runtime once at startup. Linux: prefer docker, fall back to
# podman. macOS: podman only — Docker Desktop is explicitly unsupported.
# Override with DEV_RUNTIME=docker | DEV_RUNTIME=podman.
detect_runtime() {
  if [[ -n "${DEV_RUNTIME:-}" ]]; then
    if ! command -v "$DEV_RUNTIME" >/dev/null 2>&1; then
      echo "Error: DEV_RUNTIME=$DEV_RUNTIME but '$DEV_RUNTIME' not found on PATH." >&2
      exit 1
    fi
    RUNTIME="$DEV_RUNTIME"
    return
  fi
  # Probe: a binary is "really" a runtime only if it both resolves and
  # answers --version. A bare `command -v` would be fooled by a stub
  # (test scenarios that mask a runtime via PATH overlay; broken
  # symlinks left on a stale PATH; etc.).
  _runtime_works() {
    command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1
  }
  case "$(uname -s)" in
    Darwin)
      if _runtime_works podman; then
        RUNTIME=podman
        return
      fi
      echo "Error: On macOS, podman is required (Docker Desktop is not supported)." >&2
      echo "       Install with:  brew install podman && podman machine init && podman machine start" >&2
      exit 1
      ;;
    Linux)
      if _runtime_works docker; then
        RUNTIME=docker
        return
      fi
      if _runtime_works podman; then
        RUNTIME=podman
        return
      fi
      echo "Error: Neither docker nor podman found on PATH." >&2
      exit 1
      ;;
    *)
      echo "Error: Unsupported platform: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

# On macOS with podman, the VM must be running.
ensure_runtime_ready() {
  if [[ "$(uname -s)" == "Darwin" && "$RUNTIME" == "podman" ]]; then
    if ! podman machine list --format '{{.Running}}' 2>/dev/null | grep -q '^true$'; then
      echo "Error: podman machine is not running." >&2
      echo "       Start it with:  podman machine start" >&2
      exit 1
    fi
  fi
}

# --dind/--pind AppArmor userns preflight (Ubuntu 23.10+/Linux 6.x). No-op
# unless DIND or PIND. Linux 6.x kernels gate unprivileged user namespace
# creation behind an AppArmor check (Ubuntu 23.10+, Pop!_OS, current Debian
# testing). The sysctl is on by default. Rootless dockerd/podman inside
# --dind/--pind needs to unshare(CLONE_NEWUSER); --security-opt
# apparmor=unconfined does NOT bypass this — the kernel applies the
# restriction to "unconfined" tasks too. Without this preflight the
# container starts, then rootlesskit fails ~15s in with a confusing
# "fork/exec /proc/self/exe: operation not permitted". Catch it here with
# a clear remediation instead.
preflight_apparmor_userns() {
  [[ ("$DIND" == true || "$PIND" == true) && -z "${DEV_SKIP_APPARMOR_CHECK:-}" ]] || return 0
  local _aa_sysfs=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  if [[ -r "$_aa_sysfs" ]] && [[ "$(cat "$_aa_sysfs" 2>/dev/null)" == "1" ]]; then
    cat >&2 <<'EOF'
Error: kernel.apparmor_restrict_unprivileged_userns=1 on this host.

This blocks rootless dockerd inside --dind from creating its user
namespace. --security-opt apparmor=unconfined does not bypass this
kernel-level restriction.

Allow it on this host:
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

Persist across reboots:
    echo 'kernel.apparmor_restrict_unprivileged_userns=0' \
      | sudo tee /etc/sysctl.d/99-rootless-userns.conf

Set DEV_SKIP_APPARMOR_CHECK=1 to bypass this preflight (e.g. if you
have a custom AppArmor profile that grants `userns,`).
EOF
    exit 1
  fi
  unset _aa_sysfs
}

runtime_is_rootless() {
  # docker may be the podman-docker shim, so classify by --version, not name.
  # Routed through $RUNTIME_ARGS so the macOS+dind rootful-connection override
  # (DIND_RUNTIME_ARGS) is honored once it's assigned; empty everywhere else.
  # shellcheck disable=SC2086  # intentional word-splitting, same as call sites below
  if $RUNTIME $RUNTIME_ARGS --version 2>/dev/null | grep -qi podman; then
    # shellcheck disable=SC2086
    [[ "$($RUNTIME $RUNTIME_ARGS info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" ]]
  else
    # shellcheck disable=SC2086
    $RUNTIME $RUNTIME_ARGS info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless
  fi
}
subid_total() {
  # Sum the current user's ranges in /etc/subuid or /etc/subgid ($1).
  # Prefer getsubids (shadow >= 4.10), which also sees SSSD/nsswitch
  # sources; fall back to parsing the file. Entries may be keyed by name
  # or numeric id.
  local file="$1" gflag="" total=0 count owner
  [[ "$file" == *subgid* ]] && gflag="-g"
  if command -v getsubids >/dev/null 2>&1; then
    # Output lines look like: "0: jakob 100000 65536"
    # shellcheck disable=SC2086  # $gflag is deliberately unquoted (empty or -g)
    while read -r _ _ _ count; do
      total=$((total + count))
    done < <(getsubids $gflag "$(id -un)" 2>/dev/null)
  fi
  if [[ "$total" -eq 0 && -r "$file" ]]; then
    while IFS=: read -r owner _ count; do
      [[ "$owner" == "$(id -un)" || "$owner" == "$(id -u)" ]] || continue
      total=$((total + count))
    done < "$file"
  fi
  echo "$total"
}

# --dind/--pind rootless subuid/subgid grant preflight (Linux rootless
# runtimes). Under a ROOTLESS runtime the dind/pind container's user
# namespace only spans as many IDs as the host grants this user in
# /etc/subuid + /etc/subgid (typically 65536, so container ids 0-65536).
# rootless dockerd/podman inside the container must map the image's baked
# vscode subuid range — container ids 100000-165535 — so the namespace has
# to span at least 165536 ids or rootlesskit dies ~15s in with "newuidmap:
# write to uid_map failed: Operation not permitted" (the kernel cannot map
# the extent down to a real id). Rootful runtimes are unaffected: the
# container sits in the initial user namespace where every id exists.
# Check the grant up front and refuse with a remediation instead.
#
# The 165536 floor is the image contract: Dockerfile writes
# "vscode:100000:65536" into the image's /etc/subuid, and 100000+65536
# container ids must exist for rootless dockerd's two-line map.
preflight_subid_grant() {
  [[ ("$DIND" == true || "$PIND" == true) && "$(uname -s)" == "Linux" && -z "${DEV_SKIP_SUBID_CHECK:-}" ]] || return 0
  if runtime_is_rootless; then
    _uid_total=$(subid_total /etc/subuid)
    _gid_total=$(subid_total /etc/subgid)
    if [[ "$_uid_total" -lt "$DIND_MIN_SUBIDS" || "$_gid_total" -lt "$DIND_MIN_SUBIDS" ]]; then
      _next_id=$((100000 + _uid_total)) # append after the conventional base range
      _migrate_hint=""
      if "$RUNTIME" --version 2>/dev/null | grep -qi podman; then
        _migrate_hint="
    podman system migrate    # restart podman's user namespace with the new grant"
      fi
      cat >&2 <<EOF
Error: --dind on a rootless runtime needs a larger subuid/subgid grant.

The runtime ($RUNTIME) is rootless, so the dind container's user
namespace only spans the ids granted to $(id -un) in /etc/subuid and
/etc/subgid (currently $_uid_total uids / $_gid_total gids). rootless
dockerd inside the container must map container ids 100000-165535 (the
image's vscode subuid range), so at least $DIND_MIN_SUBIDS are needed or it
fails at startup with:
    newuidmap: write to uid_map failed: Operation not permitted

Grant more ids (any range not colliding with other users), e.g.:
    sudo usermod --add-subuids ${_next_id}-365535 --add-subgids ${_next_id}-365535 $(id -un)${_migrate_hint}

Set DEV_SKIP_SUBID_CHECK=1 to bypass this preflight.
EOF
      exit 1
    fi
    unset _uid_total _gid_total _next_id _migrate_hint
  fi
}

# Refuse to run as root: the image's vscode user would collide with UID 0.
refuse_root_uid() {
  if [[ "$HOST_UID" == "0" ]]; then
    echo "Error: refusing to run dev as root (UID 0). The image creates a non-root 'vscode' user; using UID 0 would conflict with the image's existing root user." >&2
    exit 1
  fi
}
