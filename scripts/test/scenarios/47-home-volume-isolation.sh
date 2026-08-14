#!/bin/bash
# scripts/test/scenarios/47-home-volume-isolation.sh
# platform: linux
#
# The home volume is per-workspace by default (devcontainer-home-<dir>,
# <dir> = basename of the launch directory), so one project's agent can't
# read another project's SSH keys/git creds/history out of a shared home.
# DEV_SHARED_HOME=1 opts back into the legacy single devcontainer-home
# volume, shared across every workspace regardless of basename.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEV="${ROOT}/dev"

WORK="$(mktemp -d)"

# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() {
    rm -rf "$WORK"
}
trap 'cleanup_extra; restore_host' EXIT

PROJ_A="${WORK}/proj-a"
PROJ_B="${WORK}/proj-b"
PROJ_C="${WORK}/proj-c"
PROJ_D="${WORK}/proj-d"
mkdir -p "$PROJ_A" "$PROJ_B" "$PROJ_C" "$PROJ_D"

remember_container "dev-proj-a"
remember_container "dev-proj-b"
remember_container "dev-proj-c"
remember_container "dev-proj-d"

# Defensive pre-removal: a stale container from an aborted prior run of
# this scenario would otherwise be reused by dev's attach path even
# though it's bound to a (now-deleted) mktemp workspace from that earlier
# run.
"$RUNTIME" rm -f dev-proj-a dev-proj-b dev-proj-c dev-proj-d >/dev/null 2>&1 || true

# ---------- per-workspace isolation (default: no DEV_SHARED_HOME) ----------

cd "$PROJ_A" || exit 1
remember_volume devcontainer-home-proj-a
if ! "$DEV" exec -- sh -c 'echo isolated > /home/vscode/.marker47' >/dev/null 2>&1; then
    log_fail "dev exec -- (write marker) failed in $PROJ_A"
    exit 1
fi
if ! "$RUNTIME" volume inspect devcontainer-home-proj-a >/dev/null 2>&1; then
    log_fail "expected devcontainer-home-proj-a to exist after starting in proj-a"
    exit 1
fi

cd "$PROJ_B" || exit 1
remember_volume devcontainer-home-proj-b
if "$DEV" exec -- test -e /home/vscode/.marker47 >/dev/null 2>&1; then
    log_fail "proj-b's home volume sees proj-a's marker — home volumes are not isolated"
    exit 1
fi
if ! "$RUNTIME" volume inspect devcontainer-home-proj-b >/dev/null 2>&1; then
    log_fail "expected devcontainer-home-proj-b to exist after starting in proj-b"
    exit 1
fi

log_pass "per-workspace home volumes are isolated (devcontainer-home-proj-a, devcontainer-home-proj-b)"

# ---------- DEV_SHARED_HOME=1 reuses the legacy shared volume ----------

cd "$PROJ_C" || exit 1
# devcontainer-home is the legacy shared volume; removing it on cleanup is
# safe on disposable CI VMs and matches scenarios 42/44's convention.
remember_volume devcontainer-home
if ! DEV_SHARED_HOME=1 "$DEV" exec -- sh -c 'echo shared > /home/vscode/.marker47-shared' >/dev/null 2>&1; then
    log_fail "DEV_SHARED_HOME=1 dev exec -- (write marker) failed in $PROJ_C"
    exit 1
fi
if ! "$RUNTIME" volume inspect devcontainer-home >/dev/null 2>&1; then
    log_fail "expected legacy devcontainer-home to exist under DEV_SHARED_HOME=1"
    exit 1
fi

cd "$PROJ_D" || exit 1
if ! DEV_SHARED_HOME=1 "$DEV" exec -- test -e /home/vscode/.marker47-shared >/dev/null 2>&1; then
    log_fail "DEV_SHARED_HOME=1 in proj-d did not see proj-c's marker — shared volume not reused"
    exit 1
fi
if "$RUNTIME" volume inspect devcontainer-home-proj-d >/dev/null 2>&1; then
    log_fail "DEV_SHARED_HOME=1 unexpectedly created a per-workspace devcontainer-home-proj-d"
    remember_volume devcontainer-home-proj-d
    exit 1
fi

log_pass "DEV_SHARED_HOME=1 reuses the shared devcontainer-home volume across workspaces"
exit 0
