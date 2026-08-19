#!/bin/bash
# scripts/test/scenarios/54-ls.sh
# platform: linux
# privilege: user
#
# `dev ls` is the one verb that is NOT scoped to the current workspace: every
# other verb resolves dev-<basename-of-cwd> and looks only at that. So the
# assertions here are deliberately cross-workspace — a container and volume
# created in one directory must still be listed, unmarked, from another — plus
# the container-less volume that `dev status` can never show.
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

PROJ="${WORK}/lsproj"
OTHER="${WORK}/lsother"
mkdir -p "$PROJ" "$OTHER"

GHOST="devcontainer-home-lsghost"
remember_container "dev-lsproj"
remember_volume "devcontainer-home-lsproj"
remember_volume "$GHOST"

# Defensive pre-removal: a stale container from an aborted prior run is bound
# to a now-deleted mktemp workspace and would be reused by dev's attach path.
"$RUNTIME" rm -f dev-lsproj >/dev/null 2>&1 || true

run_bg() {
    nohup "$@" >/dev/null 2>&1 &
    disown
    sleep 4
}

# A per-workspace home volume with no container: the "can I delete this?" case
# the verb exists to answer. No workspace named lsghost is ever created.
"$RUNTIME" volume create "$GHOST" >/dev/null 2>&1 || {
    log_fail "could not create the orphan test volume $GHOST"
    exit 1
}

cd "$PROJ" || exit 1
run_bg "$DEV" exec -- sleep 60
if ! "$RUNTIME" ps -q -f name='^dev-lsproj$' | grep -q .; then
    log_fail "precondition: dev-lsproj did not start"
    exit 1
fi

# ---------- listed from a DIFFERENT workspace, unmarked ----------

cd "$OTHER" || exit 1
if ! out=$("$DEV" ls 2>&1); then
    log_fail "dev ls failed from another workspace: $out"
    exit 1
fi
expect_grep "$out" '^CONTAINERS$' \
    || { log_fail "no CONTAINERS section: $out"; exit 1; }
# The row carries the real bind-mount source, which is what distinguishes two
# workspaces that share a basename.
expect_grep "$out" "^ +normal +dev-lsproj +.*${PROJ}\$" \
    || { log_fail "dev-lsproj not listed with its workspace path from $OTHER: $out"; exit 1; }
expect_grep "$out" '^ +\* +normal +dev-lsproj' \
    && { log_fail "dev-lsproj marked as current workspace while cwd is $OTHER: $out"; exit 1; }
expect_grep "$out" '^ +devcontainer-home-lsproj +workspace +yes$' \
    || { log_fail "lsproj home volume missing or not in use: $out"; exit 1; }
expect_grep "$out" '^ +devcontainer-mise +shared +yes$' \
    || { log_fail "mise volume not listed as shared + in use: $out"; exit 1; }

# The orphan, and the hint that names it.
expect_grep "$out" "^ +${GHOST} +workspace +no\$" \
    || { log_fail "orphan volume $GHOST not listed as unused: $out"; exit 1; }
hint=$(echo "$out" | sed -n '/No container is using/,$p')
expect_grep "$hint" "$GHOST" \
    || { log_fail "delete hint does not name $GHOST: $out"; exit 1; }
expect_grep "$hint" 'devcontainer-mise' \
    && { log_fail "delete hint names the shared mise volume: $out"; exit 1; }

log_pass "dev ls lists another workspace's container + volumes, unmarked, and names the orphan"

# ---------- marked from its own workspace ----------

cd "$PROJ" || exit 1
if ! out=$("$DEV" ls 2>&1); then
    log_fail "dev ls failed from its own workspace: $out"
    exit 1
fi
expect_grep "$out" '^ +\* +normal +dev-lsproj' \
    || { log_fail "dev-lsproj not marked from its own workspace: $out"; exit 1; }
expect_grep "$out" '^ +\* +devcontainer-home-lsproj' \
    || { log_fail "lsproj home volume not marked from its own workspace: $out"; exit 1; }
expect_grep "$out" "belongs to this directory's workspace \(lsproj\)" \
    || { log_fail "marker legend missing or names the wrong workspace: $out"; exit 1; }

# ---------- --sizes ----------
# The column must appear and the verb must still exit 0; the values themselves
# are the engine's and may legitimately be '?' on some hosts, so they are not
# asserted here (the unit test covers the parsing against a fixture).
if ! out=$("$DEV" ls --sizes 2>&1); then
    log_fail "dev ls --sizes failed: $out"
    exit 1
fi
expect_grep "$out" 'SIZE' \
    || { log_fail "--sizes did not add the SIZE column: $out"; exit 1; }
expect_grep "$out" "^ +\* +devcontainer-home-lsproj +workspace +yes +\S+" \
    || { log_fail "--sizes left the volume row without a size cell: $out"; exit 1; }

# ---------- read-only + argument contract ----------
# Nothing above may have removed anything: this verb only ever reports.
if ! "$RUNTIME" volume inspect "$GHOST" >/dev/null 2>&1; then
    log_fail "dev ls removed the orphan volume $GHOST — the verb must be read-only"
    exit 1
fi
if ! "$RUNTIME" ps -q -f name='^dev-lsproj$' | grep -q .; then
    log_fail "dev ls stopped dev-lsproj — the verb must be read-only"
    exit 1
fi
out=$("$DEV" ls --bogus 2>&1); rc=$?
if [ "$rc" -ne 2 ]; then
    log_fail "dev ls --bogus should exit 2, got $rc: $out"
    exit 1
fi

log_pass "dev ls marks the current workspace, adds SIZE under --sizes, and changes nothing"
exit 0
