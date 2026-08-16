# shellcheck shell=bash
# lib/dev/checks-catalog-nested.sh — the `_chk_*` / `_chk_*_fix` pairs (and
# their probe-only helpers) for the checks that only block --dind/--pind
# (severity block-if-nested in the registry: userns-sysctl, subid-grant,
# fuse-device, cgroup2). Split out of lib/dev/checks-catalog.sh once that
# file grew past its 300-line lint budget (scripts/lint.sh); see
# lib/dev/checks.sh's header for the registry format and the
# run_check/checks_select machinery that calls into these functions by name.
# Sourced by dev; not executed directly.

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

# --- phase 1, blocking only under --dind/--pind ---------------------------

_have_dev_fuse() { [[ -r /dev/fuse ]]; }
_cgroup_version() { [[ -d /sys/fs/cgroup/cgroup.controllers || -f /sys/fs/cgroup/cgroup.controllers ]] && echo 2 || echo 1; }

_chk_userns_sysctl() {
  [[ -n "${DEV_SKIP_APPARMOR_CHECK:-}" ]] && return 2
  local v
  v=$(_read_sysfs /proc/sys/kernel/apparmor_restrict_unprivileged_userns)
  [[ -z "$v" ]] && return 2       # kernel does not have the knob: not applicable
  [[ "$v" == "1" ]] && return 1
  return 0
}
_chk_userns_sysctl_fix() {
  cat <<'EOF'
kernel.apparmor_restrict_unprivileged_userns=1 on this host.

This blocks rootless dockerd/podman inside --dind/--pind from creating
its user namespace. --security-opt apparmor=unconfined does not bypass
this kernel-level restriction.

Allow it on this host:
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

Persist across reboots:
    echo 'kernel.apparmor_restrict_unprivileged_userns=0' \
      | sudo tee /etc/sysctl.d/99-rootless-userns.conf

Set DEV_SKIP_APPARMOR_CHECK=1 to bypass this check (e.g. if you have a
custom AppArmor profile that grants `userns,`).
EOF
}

_chk_subid_grant() {
  [[ -n "${DEV_SKIP_SUBID_CHECK:-}" ]] && return 2
  runtime_is_rootless || return 2   # rootful maps every id already
  local u g
  u=$(subid_total /etc/subuid)
  g=$(subid_total /etc/subgid)
  [[ "$u" -lt "${DIND_MIN_SUBIDS:-165535}" ]] && return 1
  [[ "$g" -lt "${DIND_MIN_SUBIDS:-165535}" ]] && return 1
  return 0
}
_chk_subid_grant_fix() {
  local u g next
  u=$(subid_total /etc/subuid)
  g=$(subid_total /etc/subgid)
  next=$((100000 + u))
  echo "--dind/--pind on a rootless runtime needs a larger subuid/subgid grant."
  echo
  echo "Rootless runtimes give the container only the ids granted to $(id -un)"
  echo "in /etc/subuid and /etc/subgid (currently $u uids / $g gids). rootless"
  echo "dockerd/podman inside the container must map container ids"
  echo "100000-165535 (the image's vscode subuid range), so at least"
  echo "${DIND_MIN_SUBIDS:-165535} are needed or it fails at startup with:"
  echo "    newuidmap: write to uid_map failed: Operation not permitted"
  echo
  echo "Grant more ids (any range not colliding with other users), e.g.:"
  echo "    sudo usermod --add-subuids ${next}-365535 --add-subgids ${next}-365535 $(id -un)"
  _runtime_version | grep -qi podman && \
    echo "    podman system migrate    # restart podman's userns with the new grant"
  echo "Set DEV_SKIP_SUBID_CHECK=1 to bypass this check."
}

_chk_fuse_device() { _have_dev_fuse && return 0; return 1; }
_chk_fuse_device_fix() {
  echo "Nested engines need /dev/fuse for fuse-overlayfs."
  echo "    sudo modprobe fuse"
  echo "and ensure your user can read /dev/fuse."
}

_chk_cgroup2() { [[ "$(_cgroup_version)" == 2 ]] && return 0; return 1; }
_chk_cgroup2_fix() {
  echo "Nested rootless engines require cgroup v2 (unified hierarchy)."
  echo "Boot with:  systemd.unified_cgroup_hierarchy=1"
}
