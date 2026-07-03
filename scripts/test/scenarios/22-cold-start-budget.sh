#!/bin/bash
# scripts/test/scenarios/22-cold-start-budget.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
D="dev-${WS}-dind"
remember_container "$D"
"$RUNTIME" rm -f "$D" 2>/dev/null

start=$(date +%s)
if ! ./dev --dind -- docker version >/dev/null 2>&1; then
    log_fail "dev --dind -- docker version did not succeed"
    exit 1
fi
end=$(date +%s)
elapsed=$((end - start))

if [ "$elapsed" -gt 30 ]; then
    log_fail "cold start took ${elapsed}s (> 30s budget)"
    exit 1
fi
if [ "$elapsed" -gt 10 ]; then
    log_pass "cold start ${elapsed}s (over Linux 10s target but within 30s budget)"
else
    log_pass "cold start ${elapsed}s (within Linux 10s target)"
fi

# Git-identity seeding: the container's git identity is seeded from the
# host's `git config` whenever the in-container identity is empty (see
# dev's DEV_GIT_NAME/DEV_GIT_EMAIL + entrypoint.sh's gosu-vscode block).
#
# These checks run as one-shot `./dev --dind -- git config ...`
# invocations, never a bare `$RUNTIME exec "$D" ...`: (a) `--dind`
# containers are `--rm`, so a container from an earlier step can already
# be gone by the time a separate `exec` would target it; (b) a bare
# `docker exec` defaults to the image's root USER and would read
# /root/.gitconfig instead of vscode's seeded /home/vscode/.gitconfig.
# `./dev --dind -- ...` always lands as vscode instead — either by
# attaching with `exec --user vscode` (see start_container in
# lib/dev/lifecycle.sh) or, on a fresh container, via the entrypoint's
# `gosu vscode` block.
#
# Force a known host identity via the workspace's local git config so
# this check can't silently skip on a host with no git identity
# configured. Save whatever was there (present or absent) so it can be
# restored in cleanup regardless of pass/fail.
_had_local_name=1
orig_local_name=$(git config --local --get user.name 2>/dev/null) || _had_local_name=0
_had_local_email=1
orig_local_email=$(git config --local --get user.email 2>/dev/null) || _had_local_email=0
git config --local user.name "dev-scenario22-host"
git config --local user.email "dev-scenario22-host@example.invalid"

# Whatever identity ends up seeded below, captured so cleanup can put it
# back — the override plant later in this block must not leak.
orig_in_name=""

# shellcheck disable=SC2317,SC2329  # invoked via trap
restore_git_identity() {
    if [ "$_had_local_name" = "1" ]; then
        git config --local user.name "$orig_local_name"
    else
        git config --local --unset user.name 2>/dev/null || true
    fi
    if [ "$_had_local_email" = "1" ]; then
        git config --local user.email "$orig_local_email"
    else
        git config --local --unset user.email 2>/dev/null || true
    fi
    if [ -n "$orig_in_name" ]; then
        ./dev --dind -- git config --global user.name "$orig_in_name" </dev/null >/dev/null 2>&1
    fi
}
trap 'restore_git_identity; restore_host' EXIT

# Clear any identity already in the (persisted) home volume so the fresh
# start below genuinely exercises seeding rather than reading a stale value
# left by a prior run. Without this the check would depend on volume state.
./dev --dind -- git config --global --unset-all user.name  </dev/null >/dev/null 2>&1 || true
./dev --dind -- git config --global --unset-all user.email </dev/null >/dev/null 2>&1 || true

# Force a fresh container so the entrypoint's seeding logic runs against
# the empty in-container identity and the host identity forced above.
"$RUNTIME" rm -f "$D" >/dev/null 2>&1
in_name=$(./dev --dind -- git config --global user.name </dev/null 2>/dev/null | tr -d '\r')
orig_in_name="$in_name"
# Assert the exact forced host value, not merely non-empty: a non-empty
# check false-passes if startup diagnostics ever leak onto stdout.
if [ "$in_name" != "dev-scenario22-host" ]; then
    log_fail "git identity not seeded from host (got: '${in_name}', want 'dev-scenario22-host')"
    exit 1
fi
log_pass "git identity seeded into container ($in_name)"

# Non-clobber: an identity set inside the container after seeding must
# survive a restart, i.e. the entrypoint only fills in an empty
# identity, never overwrites an existing one.
if ! ./dev --dind -- git config --global user.name "in-container-override" </dev/null >/dev/null 2>&1; then
    log_fail "failed to plant in-container git identity override"
    exit 1
fi
"$RUNTIME" rm -f "$D" >/dev/null 2>&1
if ! ./dev --dind -- true >/dev/null 2>&1; then
    log_fail "dev --dind restart after planting in-container identity failed"
    exit 1
fi
in_name_after=$(./dev --dind -- git config --global user.name </dev/null 2>/dev/null | tr -d '\r')
if [ "$in_name_after" != "in-container-override" ]; then
    log_fail "pre-existing in-container git identity was overwritten on restart (got: $in_name_after)"
    exit 1
fi
log_pass "pre-existing in-container git identity is not clobbered on restart"

exit 0
