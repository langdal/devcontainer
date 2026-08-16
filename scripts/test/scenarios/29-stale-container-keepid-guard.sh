#!/bin/bash
# scripts/test/scenarios/29-stale-container-keepid-guard.sh
# platform: linux
# privilege: user
#
# dev reuses a name-matched container via `exec`. A container created before
# --userns=keep-id was applied (older dev version, or a different runtime)
# carries the default rootless uid mapping, under which vscode cannot write
# /mise or $HOME -- so reusing it silently breaks mise activation (the
# "java/JAVA_HOME missing after an upgrade" trap). Verify dev detects the
# mismatch via the dev.keepid label and recreates the container instead of
# attaching, restoring a writable /mise.
#
# keep-id only applies under rootless podman; the guard is a no-op elsewhere,
# so skip on any other runtime.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

if ! "$RUNTIME" --version 2>/dev/null | grep -qi podman \
   || [[ "$("$RUNTIME" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" != "true" ]]; then
    log_skip "keep-id guard only applies under rootless podman"
    exit 0
fi

cd "$(dirname "$0")/../../.." || exit 1
N="dev-$(basename "$(pwd)")"
remember_container "$N"
"$RUNTIME" rm -f "$N" >/dev/null 2>&1

# Simulate a stale container: default userns (no keep-id), no dev.keepid label.
if ! "$RUNTIME" run -d --name "$N" -v devcontainer-mise:/mise \
        --entrypoint /bin/sleep generic-devcontainer 300 >/dev/null 2>&1; then
    log_fail "could not create the stale container fixture"
    exit 1
fi

out=$(DEV_ASSUME_YES=1 ./dev exec -- bash -c \
    'touch /mise/cache/_guard_probe 2>/dev/null && { echo MISE_WRITABLE; rm -f /mise/cache/_guard_probe; } || echo MISE_DENIED' \
    </dev/null 2>&1)

if ! echo "$out" | grep -q "Recreating $N"; then
    log_fail "dev attached to the stale (non-keep-id) container instead of recreating it"
    echo "$out" | tail -10 >&2
    exit 1
fi
if ! echo "$out" | grep -q "MISE_WRITABLE"; then
    log_fail "/mise not writable after recreation — keep-id was not applied to the new container"
    echo "$out" | tail -10 >&2
    exit 1
fi

log_pass "dev recreates a stale non-keep-id container instead of reusing it"
exit 0
