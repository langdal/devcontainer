# shellcheck shell=bash
# lib/dev/runtime.sh — container-runtime detection and runtime probes.
# Sourced by dev; not executed directly.

# Probe: a binary is "really" a runtime only if it both resolves and
# answers --version. A bare `command -v` would be fooled by a stub
# (test scenarios that mask a runtime via PATH overlay; broken
# symlinks left on a stale PATH; etc.).
_runtime_works() {
  command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1
}

# A real Docker CLI can be pointed at a podman socket (DOCKER_HOST=.../
# podman.sock). It talks to podman fine, but it cannot express
# --userns=keep-id: that flag is podman-only and the Docker CLI rejects it
# client-side with "--userns: invalid USER mode". Without keep-id, rootless
# podman remaps vscode into the subuid range and every write to /home/vscode
# and /mise fails with EACCES. So when the CLI is Docker but the engine is
# podman, drive the same engine through the podman CLI instead.
#
# The podman-docker shim is deliberately NOT this case: it *is* podman, it
# forwards keep-id, and it reports podman in --version — so it stays on
# 'docker' (the contract scenario 03 asserts).
_prefer_podman_cli_for_podman_engine() {
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  $RUNTIME ${RUNTIME_ARGS:-} --version 2>/dev/null | grep -qi podman && return 0
  engine_is_podman || return 0
  if _runtime_works podman; then
    echo "Note: '$RUNTIME' is a Docker CLI talking to a podman engine; using the" >&2
    echo "      podman CLI instead (required for --userns=keep-id)." >&2
    echo "      Set DEV_RUNTIME=docker to override." >&2
    RUNTIME=podman
    # podman does not read DOCKER_HOST — it reads CONTAINER_HOST. Carry the
    # socket over so we keep talking to the engine we just identified rather
    # than the invoking user's default rootless one, which can be entirely
    # different storage (e.g. DOCKER_HOST=unix:///run/podman/podman.sock is
    # the rootful socket; bare `podman` would silently target rootless, and
    # the workspace's containers, images and volumes would appear to vanish).
    if [[ -n "${DOCKER_HOST:-}" ]]; then
      export CONTAINER_HOST="$DOCKER_HOST"
    fi
    unset _ENGINE_IS_PODMAN   # re-probe against the new CLI
    return 0
  fi
  echo "Error: '$RUNTIME' is a Docker CLI pointed at a podman engine" >&2
  echo "       (DOCKER_HOST=${DOCKER_HOST:-unset}), but the Docker CLI cannot pass" >&2
  echo "       --userns=keep-id, which rootless podman needs to keep /home/vscode" >&2
  echo "       and /mise writable. Install the podman CLI, or point DOCKER_HOST at" >&2
  echo "       a real Docker daemon." >&2
  exit 1
}

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
        _prefer_podman_cli_for_podman_engine
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

# Whether the engine we are talking to is podman. The CLI binary does not
# decide this: `docker` may be the podman-docker shim (--version says podman),
# but a real Docker CLI pointed at a rootless podman socket via DOCKER_HOST
# also speaks to podman while --version says "Docker version ...". Getting
# this wrong silently skips --userns=keep-id and the one-time volume chown
# migration, which leaves every write to /home/vscode and /mise failing with
# EACCES. So: ask the CLI first (cheap, no daemon needed), then fall back to
# the server's own component name. Memoized — callers hit this repeatedly.
engine_is_podman() {
  if [[ -n "${_ENGINE_IS_PODMAN:-}" ]]; then
    [[ "$_ENGINE_IS_PODMAN" == true ]]
    return
  fi
  _ENGINE_IS_PODMAN=false
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS, both branches
  if $RUNTIME $RUNTIME_ARGS --version 2>/dev/null | grep -qi podman; then
    _ENGINE_IS_PODMAN=true
  elif $RUNTIME $RUNTIME_ARGS version --format '{{.Server.Components}}' 2>/dev/null \
       | grep -qi podman; then
    # An unreachable daemon fails this call rather than answering; that is
    # correctly not-podman, and dev's normal runtime errors report it.
    _ENGINE_IS_PODMAN=true
  fi
  [[ "$_ENGINE_IS_PODMAN" == true ]]
}

runtime_is_rootless() {
  # Classify by engine, not by the CLI binary's name or version string.
  # Routed through $RUNTIME_ARGS so the macOS+dind rootful-connection override
  # (DIND_RUNTIME_ARGS) is honored once it's assigned; empty everywhere else.
  # Two info schemas, and the engine alone does not pick between them: it is
  # the CLI that renders the template. podman's own CLI exposes
  # .Host.Security.Rootless; a Docker CLI gets the docker-compat schema even
  # when the server is podman, and reports rootlessness in .SecurityOptions.
  # Try the native form first, then fall back, so all three CLI/engine
  # combinations resolve.
  # shellcheck disable=SC2086
  if [[ "$($RUNTIME $RUNTIME_ARGS info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" ]]; then
    return 0
  fi
  # shellcheck disable=SC2086
  $RUNTIME $RUNTIME_ARGS info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless
}
