# shellcheck shell=bash
# lib/dev/checks-catalog.sh — the probe/fix function pairs (`_chk_*` /
# `_chk_*_fix`) and their probe-only helpers for the registry defined in
# lib/dev/checks.sh. Split out of checks.sh once the catalogue grew past its
# 300-line lint budget (scripts/lint.sh); see that file's header for the
# registry format and the run_check/checks_select machinery that calls into
# these functions by name. The block-if-nested checks (userns-sysctl,
# subid-grant, fuse-device, cgroup2) live in the sibling
# lib/dev/checks-catalog-nested.sh, split out for the same reason once this
# file hit the budget again.
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

# DEV_RUNTIME is an explicit override, so naming something absent is a user
# error worth reporting rather than a host condition. detect_runtime refuses
# outright in that case, which is why this has to be answerable in phase 0.
_chk_dev_runtime_valid() {
  [[ -z "${DEV_RUNTIME:-}" ]] && return 2   # unset: nothing to validate
  _have_cmd "$DEV_RUNTIME" && return 0
  return 1
}
_chk_dev_runtime_valid_fix() {
  # "not found on PATH" verbatim from the message detect_runtime used to
  # print: scripts/test/scenarios/05-runtime-env-override.sh greps for that
  # exact phrase, and it is the wording users have seen for this failure.
  echo "DEV_RUNTIME=${DEV_RUNTIME:-} but '${DEV_RUNTIME:-}' not found on PATH."
  echo "Unset it to let dev choose, or install that runtime:"
  echo "    unset DEV_RUNTIME"
}

_chk_runtime_present() {
  # Platform-aware, because detect_runtime is: its Darwin branch requires
  # podman specifically and refuses outright on anything else (Docker Desktop
  # is unsupported). A check that accepted "docker OR podman" everywhere would
  # pass on a Mac that detect_runtime is about to reject, and the report would
  # end there instead of explaining why.
  if [[ "$(_host_os)" == "Darwin" ]]; then
    _have_cmd podman && return 0
    return 1
  fi
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
# Severity is block-in-doctor (checks.sh), not block: this only refuses an
# invocation that is actually about to build; lib/dev/image.sh's
# runtime_build guards the build site itself with the same underlying probe.
_chk_buildx() {
  _have_cmd docker-buildx && return 0
  _have_cmd buildx && return 0
  _docker_buildx_present && return 0
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

# Severity is block-in-doctor (checks.sh), not block: lib/dev/runtime.sh's
# ensure_runtime_ready already guards every site that genuinely touches the
# engine (and is itself a no-op for --dry-run), so this only needs to refuse
# `dev doctor` readiness — the same reasoning that put buildx on this
# severity above.
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
# Total RAM in GiB, or EMPTY when it cannot be determined. Mirrors
# _free_disk_gb: returning empty rather than 0 matters, since 0 would read as
# "no RAM at all" and fail the check on a probe that simply couldn't run.
_total_mem_gb() {
  if [[ "$(_host_os)" == "Darwin" ]]; then
    local bytes; bytes="$(sysctl -n hw.memsize 2>/dev/null)"
    case "$bytes" in ''|*[!0-9]*) return 0 ;; esac
    echo $(( bytes / 1073741824 ))
  else
    awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo 2>/dev/null
  fi
}
# Scopes on GITHUB_TOKEN, or EMPTY when the request succeeded and reported
# none. Returns non-zero (rather than empty) when curl itself did not
# succeed — offline host, proxy interception, timeout — so a caller can tell
# "verified scopeless" apart from "learned nothing". --max-time bounds this:
# an offline host or a firewall that silently drops (rather than rejects) the
# connection must not hang the probe.
# The single source of truth for "what scopes does GITHUB_TOKEN carry".
# Consumed by _chk_github_token_scopes (dev doctor) AND resolve_github_token
# (lib/dev/approval.sh, the warning dev up prints). Those were two separate
# implementations that had already drifted: the registry copy lacked the
# fine-grained-PAT short-circuit and the per-token cache, so it made a network
# call on every doctor run and flagged tokens the other one correctly ignored.
#
# Prints the scopes string (possibly empty) and returns:
#   0  determined
#   1  undeterminable — no curl, or the request never completed. NEVER treat
#      this as "no scopes": that asserts the token is safe without checking.
#   2  not applicable — no token, or a fine-grained PAT, scoped by construction
_token_scopes() {
  [[ -z "${GITHUB_TOKEN:-}" ]] && return 2
  case "$GITHUB_TOKEN" in
    github_pat_*) return 2 ;;
  esac
  _have_cmd curl || return 1
  local cache="" hash headers rc scopes
  # Cache per token when a state dir exists (dev up path). doctor may run
  # before ensure_state_dir, so the cache is optional, not required.
  if [[ -n "${STATE_DIR:-}" ]] && command -v sha256_portable >/dev/null 2>&1; then
    hash=$(printf '%s' "$GITHUB_TOKEN" | sha256_portable | cut -c1-16)
    cache="$STATE_DIR/github-token-$hash"
    if [[ -f "$cache" ]]; then
      cat "$cache"
      return 0
    fi
  fi
  headers="$(curl -fsS -D - -o /dev/null -m 5 \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      https://api.github.com/rate_limit 2>/dev/null)"
  rc=$?
  [[ $rc -eq 0 ]] || return 1
  scopes=$(printf '%s' "$headers" | tr -d '\r' \
      | awk -F': ' 'tolower($1)=="x-oauth-scopes" {print $2; exit}')
  [[ -n "$cache" ]] && printf '%s\n' "$scopes" > "$cache"
  printf '%s\n' "$scopes"
  return 0
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

_chk_memory() {
  local mem; mem="$(_total_mem_gb)"
  case "$mem" in ''|*[!0-9]*) return 2 ;; esac
  [[ "$mem" -lt 6 ]] && return 1
  return 0
}
_chk_memory_fix() {
  echo "Nested engines (--dind/--pind) want ~6 GB; with less the kernel may"
  echo "OOM-kill the build. Normal mode is fine on less."
}

_chk_github_token_scopes() {
  local scopes rc
  scopes="$(_token_scopes)"; rc=$?
  # rc 1 (undeterminable) maps to not-applicable, never to pass: reporting
  # "carries no scopes" after a failed probe asserts something unverified.
  [[ "$rc" -ne 0 ]] && return 2
  [[ -n "$scopes" ]] && return 1
  return 0
}
_chk_github_token_scopes_fix() {
  echo "GITHUB_TOKEN carries OAuth scopes. An agent inside the container can"
  echo "read it, so those scopes are scopes you hand the agent. Its only job"
  echo "here is rate-limit identification: use a fine-grained PAT with no"
  echo "repository access and no permissions."
}
