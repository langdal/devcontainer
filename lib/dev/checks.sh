# shellcheck shell=bash
# lib/dev/checks.sh — the host-check registry shared by `dev doctor` and the
# blocking preflights in `dev up`. One source of truth: doctor runs every
# applicable entry, cmd_start runs the blocking subset, so the two can never
# disagree about whether a host is usable.
# Sourced by dev; not executed directly.
#
# Entry format:  id|phase|applies-to|severity|title
#   phase      0 = answerable before detect_runtime; 1 = needs $RUNTIME
#   applies-to platform[,platform]:runtime[,runtime], '*' = any
#   severity   block | block-if-nested | advise
#
# Each id has a `_chk_<id>` probe returning 0 pass / 1 fail / 2 not-applicable,
# and a `_chk_<id>_fix` printing remediation. Probes MUST reach the outside
# world only through the indirections in lib/dev/runtime.sh (_host_os,
# _have_cmd, _runtime_version, _read_sysfs) so they stay unit-testable from
# any platform.
CHECKS=(
  "platform-supported|0|*:*|block|supported platform (linux/darwin)"
  "runtime-present|0|*:*|block|a container runtime is installed"
  "buildx|1|linux,darwin:docker|block|docker buildx present"
  "not-docker-desktop|1|darwin:*|block|not Docker Desktop"
  "podman-machine|1|darwin:podman|block|podman machine running"
  "workspace-not-root|1|*:*|block|workspace not root-owned"
  "userns-sysctl|1|linux:*|block-if-nested|unprivileged userns permitted"
  "subid-grant|1|linux:podman|block-if-nested|subuid/subgid range >= 165535"
  "fuse-device|1|linux:*|block-if-nested|/dev/fuse accessible"
  "cgroup2|1|linux:*|block-if-nested|cgroup v2"
  "engine-cli-match|1|*:*|advise|CLI and engine agree"
  "home-volume-owner|1|*:podman|advise|home volume ownership matches uid"
  "selinux-enforcing|1|linux:*|advise|SELinux not enforcing"
  "disk-space|1|*:*|advise|at least 3 GB free"
  "memory|1|*:*|advise|at least 6 GB RAM for nested engines"
  "github-token-scopes|1|*:*|advise|GITHUB_TOKEN carries no scopes"
)

# Field n (1-indexed) of a registry entry.
check_field() {
  echo "$1" | cut -d'|' -f"$2"
}

# Does <applies-to> cover <os> + <runtime>? Case-insensitive on the OS so
# "Darwin" from uname matches "darwin" in the table (bash 3.2 has no
# ${var,,}, hence tr).
check_applies() {
  local spec="$1" os="$2" rt="$3" want_os want_rt
  want_os="${spec%%:*}"
  want_rt="${spec##*:}"
  os=$(echo "$os" | tr '[:upper:]' '[:lower:]')
  if [[ "$want_os" != "*" ]]; then
    case ",$want_os," in
      *",$os,"*) ;;
      *) return 1 ;;
    esac
  fi
  if [[ "$want_rt" != "*" ]]; then
    case ",$want_rt," in
      *",$rt,"*) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Run one probe. Sets CHECK_STATE to pass|fail|na and always returns 0 so a
# caller under `set -e` keeps going. A probe that does not exist is 'na',
# never 'pass' — an undetermined check must not read as a healthy host.
run_check() {
  local id="$1" fn rc
  # Registry ids are hyphenated; shell function names cannot be.
  fn="_chk_$(echo "$id" | tr '-' '_')"
  if ! command -v "$fn" >/dev/null 2>&1; then
    CHECK_STATE=na
    return 0
  fi
  rc=0
  "$fn" || rc=$?
  # shellcheck disable=SC2034  # CHECK_STATE is consumed by callers of run_check (dev doctor, cmd_start preflights)
  case "$rc" in
    0) CHECK_STATE=pass ;;
    1) CHECK_STATE=fail ;;
    *) CHECK_STATE=na ;;
  esac
  return 0
}

# Print the ids matching <phase> and <severity-filter> for <os>/<runtime>,
# one per line, in registry order. severity-filter is 'all' or 'blocking';
# 'blocking' includes block-if-nested only when $NESTED is true.
checks_select() {
  local want_phase="$1" filter="$2" os="$3" rt="$4"
  local entry id phase spec sev
  for entry in "${CHECKS[@]}"; do
    id=$(check_field "$entry" 1)
    phase=$(check_field "$entry" 2)
    spec=$(check_field "$entry" 3)
    sev=$(check_field "$entry" 4)
    [[ "$phase" == "$want_phase" ]] || continue
    check_applies "$spec" "$os" "$rt" || continue
    if [[ "$filter" == blocking ]]; then
      case "$sev" in
        block) ;;
        block-if-nested) [[ "${NESTED:-false}" == true ]] || continue ;;
        *) continue ;;
      esac
    fi
    echo "$id"
  done
}

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
