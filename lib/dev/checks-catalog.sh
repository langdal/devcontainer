# shellcheck shell=bash
# lib/dev/checks-catalog.sh — the probe/fix function pairs (`_chk_*` /
# `_chk_*_fix`) and their probe-only helpers for the registry defined in
# lib/dev/checks.sh. Split out of checks.sh once the catalogue grew past its
# 300-line lint budget (scripts/lint.sh); see that file's header for the
# registry format and the run_check/checks_select machinery that calls into
# these functions by name.
# Sourced by dev; not executed directly.

# --- phase 0 --------------------------------------------------------------

_chk_platform_supported() {
  case "$(_host_os)" in
    Linux|Darwin) return 0 ;;
    *) return 1 ;;
  esac
}
_chk_platform_supported_fix() {
  echo "dev supports Linux and macOS only; this host reports $(_host_os)."
}

_chk_runtime_present() {
  _have_cmd docker && return 0
  _have_cmd podman && return 0
  return 1
}
_chk_runtime_present_fix() {
  if [[ "$(_host_os)" == "Darwin" ]]; then
    echo "Install podman (Docker Desktop is not supported):"
    echo "    brew install podman && podman machine init && podman machine start"
  else
    echo "Install a container runtime, e.g.:"
    echo "    sudo apt-get install -y docker.io docker-buildx"
  fi
}

# --- phase 1, blocking ----------------------------------------------------

# The Dockerfile uses BuildKit's RUN --mount=type=secret, which the legacy
# builder cannot handle. Missing buildx therefore fails EVERY image build.
# On 2026-08-15 this went undetected: the test orchestrator installs buildx
# only when no runtime is present at all, so a host with docker and no buildx
# failed every scenario and still wrote a summary that read as clean.
_chk_buildx() {
  _have_cmd docker-buildx && return 0
  _have_cmd buildx && return 0
  return 1
}
_chk_buildx_fix() {
  echo "The Dockerfile uses RUN --mount=type=secret, which the legacy builder"
  echo "cannot handle, so buildx is mandatory."
  echo "    Debian/Ubuntu:  sudo apt-get install -y docker-buildx"
  echo "    other:          https://docs.docker.com/go/buildx/"
  echo "Or force podman instead:  DEV_RUNTIME=podman"
}

_chk_not_docker_desktop() {
  _runtime_version | grep -qi podman && return 0
  _runtime_version | grep -qi docker && return 1
  return 2
}
_chk_not_docker_desktop_fix() {
  echo "Docker Desktop is not supported on macOS; dev targets podman."
  echo "    brew install podman && podman machine init && podman machine start"
  echo "Then pin it:  DEV_RUNTIME=podman"
}

_chk_podman_machine() {
  _machine_running && return 0
  return 1
}
_chk_podman_machine_fix() {
  echo "Start the VM that backs podman on macOS:"
  echo "    podman machine start"
  echo "(First time:  podman machine init)"
}

_chk_workspace_not_root() {
  [[ "${HOST_UID:-$(id -u)}" == "0" ]] && return 1
  return 0
}
_chk_workspace_not_root_fix() {
  echo "Run dev as your normal user. The image creates a non-root 'vscode'"
  echo "user; UID 0 would collide with the image's existing root."
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

# --- phase 1, advisory ----------------------------------------------------

# The server's own component name, e.g. "Podman Engine" or "Engine".
_engine_server_name() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME ${RUNTIME_ARGS:-} version --format '{{.Server.Components}}' 2>/dev/null || true
}
# Free GiB on the filesystem holding the workspace, or EMPTY when it cannot
# be determined. `df -g` is BSD/macOS-only; GNU df needs -BG and prints a
# "40G" style figure that has to have its suffix stripped. Returning empty
# rather than 0 matters: 0 would read as "no space left" and fail the check.
_free_disk_gb() {
  if [[ "$(_host_os)" == "Darwin" ]]; then
    df -Pg . 2>/dev/null | awk 'NR==2{print $4}'
  else
    df -PBG . 2>/dev/null | awk 'NR==2{gsub(/G$/,"",$4); print $4}'
  fi
}
_total_mem_gb() {
  if [[ "$(_host_os)" == "Darwin" ]]; then
    echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  else
    awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 0
  fi
}
_token_scopes() {
  # --max-time bounds this: an offline host or a firewall that silently
  # drops (rather than rejects) the connection must not hang the probe.
  curl -sS --max-time 5 -I -H "Authorization: bearer ${GITHUB_TOKEN}" \
      https://api.github.com/ 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}'
}
_selinux_mode() { command -v getenforce >/dev/null 2>&1 && getenforce 2>/dev/null || echo ""; }

# A real Docker CLI can be pointed at a podman socket via DOCKER_HOST. dev
# auto-switches to the podman CLI (runtime.sh), but the user should know why
# their commands are being rewritten. Advisory, never blocking.
_chk_engine_cli_match() {
  # detect_runtime already rewired $RUNTIME to podman for exactly this
  # mismatch (_prefer_podman_cli_for_podman_engine in lib/dev/runtime.sh).
  # By the time this probe runs the CLI IS podman, so the checks below would
  # find nothing left to disagree about and wrongly report 'pass'. The flag
  # records what the CLI was before that rewrite.
  [[ "${ENGINE_CLI_SWITCHED:-false}" == true ]] && return 1
  _runtime_version | grep -qi podman && return 0     # CLI is podman: agrees
  local server; server="$(_engine_server_name)"
  [[ -z "$server" ]] && return 2                      # engine unreachable: undetermined
  echo "$server" | grep -qi podman && return 1        # CLI docker, engine podman
  return 0
}
_chk_engine_cli_match_fix() {
  if [[ "${ENGINE_CLI_SWITCHED:-false}" == true ]]; then
    echo "dev noticed \$DOCKER_HOST (or the default socket) points at a podman"
    echo "engine while the CLI you invoked was Docker, and switched this"
    echo "session to the podman CLI: --userns=keep-id (needed to keep"
    echo "/home/vscode and /mise writable under rootless podman) is"
    echo "podman-only, and the Docker CLI rejects that flag outright. This is"
    echo "working as intended: nothing to fix."
    echo "Pin it explicitly to silence this note:  DEV_RUNTIME=podman"
  else
    echo "DOCKER_HOST=${DOCKER_HOST:-unset} points at a podman engine, but"
    echo "DEV_RUNTIME=docker is pinning this session to the Docker CLI, so dev"
    echo "cannot redirect it to podman the way it normally would. The Docker"
    echo "CLI cannot pass --userns=keep-id, which rootless podman needs to keep"
    echo "/home/vscode and /mise writable: this pin is unsafe."
    echo "Drop the pin so dev can drive podman directly:"
    echo "    unset DEV_RUNTIME     # or: DEV_RUNTIME=podman"
  fi
}

_chk_selinux_enforcing() {
  local m; m=$(_selinux_mode)
  [[ -z "$m" ]] && return 2
  [[ "$m" == "Enforcing" ]] && return 1
  return 0
}
_chk_selinux_enforcing_fix() {
  echo "SELinux is enforcing. dev passes --security-opt label=disable for"
  echo "nested engines, so this is usually fine; if a nested mount is denied,"
  echo "that is the first thing to check."
}

_chk_disk_space() {
  local free; free="$(_free_disk_gb)"
  case "$free" in ''|*[!0-9]*) return 2 ;; esac
  [[ "$free" -lt 3 ]] && return 1
  return 0
}
_chk_disk_space_fix() { echo "Images and the mise cache need ~3 GB free; free some space."; }

_chk_memory() { [[ "$(_total_mem_gb)" -lt 6 ]] && return 1; return 0; }
_chk_memory_fix() {
  echo "Nested engines (--dind/--pind) want ~6 GB; with less the kernel may"
  echo "OOM-kill the build. Normal mode is fine on less."
}

_chk_github_token_scopes() {
  [[ -z "${GITHUB_TOKEN:-}" ]] && return 2
  [[ -n "$(_token_scopes)" ]] && return 1
  return 0
}
_chk_github_token_scopes_fix() {
  echo "GITHUB_TOKEN carries OAuth scopes. An agent inside the container can"
  echo "read it, so those scopes are scopes you hand the agent. Its only job"
  echo "here is rate-limit identification: use a fine-grained PAT with no"
  echo "repository access and no permissions."
}
