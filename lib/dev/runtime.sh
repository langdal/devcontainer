# shellcheck shell=bash
# lib/dev/runtime.sh — container-runtime detection and runtime probes.
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
