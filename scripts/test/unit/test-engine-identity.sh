#!/usr/bin/env bash
# Unit: engine identity detection (lib/dev/runtime.sh).
#
# The CLI binary does not determine the engine. Three combinations must be
# classified correctly, and only the middle one is covered by the older
# `--version | grep podman` check:
#
#   1. real Docker CLI  -> real dockerd            => not podman
#   2. podman CLI (or the podman-docker shim)      => podman
#   3. real Docker CLI  -> podman socket           => podman
#
# (3) is the case that regressed: on a host with DOCKER_HOST pointed at
# rootless podman, `docker --version` says "Docker version ...", so dev
# skipped --userns=keep-id and the one-time volume chown migration, and
# every write to /home/vscode and /mise failed with EACCES.
#
# No runtime is contacted: each case is a stub script on PATH.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Build a stub CLI. $1=name, $2=--version output, $3=Server.Components output
# ('' => the stub fails the `version` call, like an unreachable daemon).
make_stub() {
    local name=$1 ver=$2 comps=$3
    cat >"$WORK/$name" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo '$ver' ;;
  version)   [ -n '$comps' ] || exit 1; echo '$comps' ;;
  info)      echo '[name=seccomp,profile=default name=rootless]' ;;
  *)         exit 1 ;;
esac
EOF
    chmod +x "$WORK/$name"
}

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
RUNTIME_ARGS=""

fail() { echo "FAIL: $1"; exit 1; }

command -v engine_is_podman >/dev/null 2>&1 \
    || fail "engine_is_podman is not defined in lib/dev/runtime.sh"

# 1. Real Docker CLI against real dockerd: not podman.
make_stub docker-real 'Docker version 29.1.3, build 29.1.3-0ubuntu4.1' \
    '[{Engine 29.1.3 map[ApiVersion:1.52]}]'
RUNTIME="$WORK/docker-real"; unset _ENGINE_IS_PODMAN
engine_is_podman && fail "real docker+dockerd misclassified as podman"

# 2. podman CLI (and the podman-docker shim, which is podman under another
#    name): podman, decided from --version without contacting a daemon.
make_stub podman-cli 'podman version 5.7.0' ''
RUNTIME="$WORK/podman-cli"; unset _ENGINE_IS_PODMAN
engine_is_podman || fail "podman CLI not classified as podman"

# 3. THE REGRESSION: real Docker CLI, podman socket. --version says Docker;
#    only the server's component name reveals the truth.
make_stub docker-to-podman 'Docker version 29.1.3, build 29.1.3-0ubuntu4.1' \
    '[{Podman Engine 5.7.0 map[APIVersion:5.7.0 Arch:amd64]} {Conmon conmon version 2.1.13}]'
RUNTIME="$WORK/docker-to-podman"; unset _ENGINE_IS_PODMAN
engine_is_podman || fail "docker CLI against a podman socket not classified as podman"

# 4. Unreachable daemon must not hang or crash; it simply is not podman.
make_stub docker-dead 'Docker version 29.1.3, build 29.1.3-0ubuntu4.1' ''
RUNTIME="$WORK/docker-dead"; unset _ENGINE_IS_PODMAN
engine_is_podman && fail "unreachable daemon should not classify as podman"

# 5. The result is memoized: the probe must not re-shell out per call. Point
#    RUNTIME at a stub that fails outright and confirm the cached answer holds.
RUNTIME="$WORK/docker-to-podman"; unset _ENGINE_IS_PODMAN
engine_is_podman || fail "precondition: expected podman before memo check"
RUNTIME="$WORK/nonexistent-runtime"
engine_is_podman || fail "engine_is_podman did not memoize its result"

# --- CLI selection -------------------------------------------------------
#
# Classifying the engine is necessary but not sufficient. --userns=keep-id is
# a podman-only flag that a real Docker CLI rejects client-side ("--userns:
# invalid USER mode"), so on a docker-CLI-to-podman-socket host dev must drive
# the same engine through the podman CLI. The podman-docker shim is NOT this
# case: it is podman, forwards the flag, and says podman in --version.
STUBS="$WORK/bin"; mkdir -p "$STUBS"

# Stubs are looked up on PATH by detect_runtime, so they must live under
# $STUBS with the exact binary names.
place() { make_stub "$1" "$2" "$3"; mv "$WORK/$1" "$STUBS/$1"; }

detect_with_stubs() {
    RUNTIME=""; unset _ENGINE_IS_PODMAN
    PATH="$STUBS:$PATH" DEV_RUNTIME="" detect_runtime
}

# A. podman-docker shim: docker resolves to podman. Stay on 'docker'; the
#    shim forwards keep-id. (Contract asserted by scenario 03.)
rm -f "$STUBS"/*
place docker 'podman version 5.7.0' ''
place podman 'podman version 5.7.0' ''
detect_with_stubs
[ "$RUNTIME" = "docker" ] || fail "podman-docker shim should keep RUNTIME=docker, got '$RUNTIME'"

# B. Real Docker CLI against a podman socket, podman CLI available: switch.
rm -f "$STUBS"/*
place docker 'Docker version 29.1.3, build 29.1.3-0ubuntu4.1' \
    '[{Podman Engine 5.7.0 map[APIVersion:5.7.0]}]'
place podman 'podman version 5.7.0' ''
detect_with_stubs 2>/dev/null
[ "$RUNTIME" = "podman" ] \
    || fail "docker CLI on a podman socket should switch to the podman CLI, got '$RUNTIME'"

# B2. The switch must carry the socket over. podman reads CONTAINER_HOST, not
#     DOCKER_HOST, so a bare `podman` would target the invoking user's default
#     rootless storage — not necessarily the engine we just identified.
rm -f "$STUBS"/*
place docker 'Docker version 29.1.3, build 29.1.3-0ubuntu4.1' \
    '[{Podman Engine 5.7.0 map[APIVersion:5.7.0]}]'
place podman 'podman version 5.7.0' ''
unset CONTAINER_HOST
RUNTIME=""; unset _ENGINE_IS_PODMAN
PATH="$STUBS:$PATH" DEV_RUNTIME="" DOCKER_HOST=unix:///run/podman/podman.sock \
    detect_runtime 2>/dev/null
[ "${CONTAINER_HOST:-}" = "unix:///run/podman/podman.sock" ] \
    || fail "switch dropped DOCKER_HOST targeting; CONTAINER_HOST='${CONTAINER_HOST:-unset}'"
unset CONTAINER_HOST

# C. Real Docker CLI against real dockerd: untouched.
rm -f "$STUBS"/*
place docker 'Docker version 29.1.3, build 29.1.3-0ubuntu4.1' \
    '[{Engine 29.1.3 map[ApiVersion:1.52]}]'
place podman 'podman version 5.7.0' ''
detect_with_stubs
[ "$RUNTIME" = "docker" ] || fail "real docker+dockerd should keep RUNTIME=docker, got '$RUNTIME'"

# D. Explicit DEV_RUNTIME is honored, not second-guessed.
rm -f "$STUBS"/*
place docker 'Docker version 29.1.3, build 29.1.3-0ubuntu4.1' \
    '[{Podman Engine 5.7.0 map[APIVersion:5.7.0]}]'
place podman 'podman version 5.7.0' ''
RUNTIME=""; unset _ENGINE_IS_PODMAN
PATH="$STUBS:$PATH" DEV_RUNTIME=docker detect_runtime
[ "$RUNTIME" = "docker" ] || fail "explicit DEV_RUNTIME=docker was overridden, got '$RUNTIME'"

echo "PASS: engine identity classified from the server, not the CLI binary"
