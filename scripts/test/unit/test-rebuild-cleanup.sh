#!/usr/bin/env bash
# Unit: which volumes a UID/GID-mismatch rebuild wipes (lib/dev/image.sh's
# cleanup_for_rebuild) and which one the start flow mounts for the same
# invocation (lib/dev/volumes.sh's append_nested_engine_volume).
#
# These two must name the SAME nested-engine volume. They did not: cleanup was
# handed a bare $DIND, so a --pind rebuild wiped devcontainer-dind (not even
# mounted) and left devcontainer-pind — podman storage written under the old id
# mapping — in place, so the freshly-rebuilt image started on stale
# /home/vscode/.local/share/containers state.
#
# No runtime is contacted: the destructive helpers are stubs that record calls.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck source=lib/dev/volumes.sh
. "$ROOT/lib/dev/volumes.sh"
# shellcheck source=lib/dev/image.sh
. "$ROOT/lib/dev/image.sh"

fail() { echo "FAIL: $1"; exit 1; }

RUNTIME_ARGS=""
HOME_VOLUME="devcontainer-home-proj"

REMOVED=""
CONTAINERS=""
remove_volume_if_exists() { REMOVED="$REMOVED $1"; }
remove_container_if_exists() { CONTAINERS="$CONTAINERS $1"; }

# $1=label $2=DIND $3=PIND $4=expected wiped volumes (space-separated, in order)
check_wipe() {
    local label=$1 want=$4
    DIND=$2 PIND=$3
    REMOVED=""; CONTAINERS=""
    cleanup_for_rebuild "dev-proj"
    # shellcheck disable=SC2086  # re-splitting to normalise whitespace
    [ "$(echo $REMOVED)" = "$want" ] \
        || fail "$label: wiped '$(echo $REMOVED)', want '$want'"
    # shellcheck disable=SC2086
    [ "$(echo $CONTAINERS)" = "dev-proj" ] \
        || fail "$label: removed containers '$(echo $CONTAINERS)', want 'dev-proj'"
}

# $1=label $2=DIND $3=PIND $4=expected -v argument
check_mount() {
    local label=$1 want=$4
    DIND=$2 PIND=$3
    DOCKER_CMD=()
    append_nested_engine_volume
    [ "${#DOCKER_CMD[@]}" = 2 ] || fail "$label: expected one -v pair, got ${DOCKER_CMD[*]}"
    [ "${DOCKER_CMD[1]}" = "$want" ] || fail "$label: mounted '${DOCKER_CMD[1]}', want '$want'"
}

# 1. Plain container: no nested engine, so only the two always-mounted volumes.
check_wipe normal false false "devcontainer-mise devcontainer-home-proj"

# 2. --dind: the docker image cache goes too.
check_wipe dind true false "devcontainer-mise devcontainer-home-proj devcontainer-dind"

# 3. --pind: the podman storage volume goes, and devcontainer-dind — which this
#    invocation never mounted — is left alone.
check_wipe pind false true "devcontainer-mise devcontainer-home-proj devcontainer-pind"

# 4. The wipe list has to match what the start flow actually mounts, per mode.
check_mount dind true false "devcontainer-dind:/home/vscode/.local/share/docker"
check_mount pind false true "devcontainer-pind:/home/vscode/.local/share/containers"

# 5. And the prompt must name every volume it is about to remove: a --pind user
#    who sees only mise+home listed cannot consent to losing podman storage.
DIND=false PIND=true
nested=$(nested_engine_volume)
[ "$nested" = "devcontainer-pind" ] || fail "nested_engine_volume under --pind: '$nested'"

echo "PASS: rebuild cleanup volume set"
