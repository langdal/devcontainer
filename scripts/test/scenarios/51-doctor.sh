#!/bin/bash
# scripts/test/scenarios/51-doctor.sh
# platform: linux
# privilege: user
# Contract for the `dev doctor` verb. Container-free: exit codes, report
# shape, and the severity split, all driven through DEV_FAKE_* stubs.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
require_platform linux
require_privilege user

cd "$(dirname "$0")/../../.." || exit 1

fail=0
chk() { # description, expected-exit, grep-pattern, cmd...
    local desc="$1" want_rc="$2" pat="$3"; shift 3
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        log_fail "$desc: expected exit $want_rc, got $rc — output: $out"; fail=1; return
    fi
    if [ -n "$pat" ] && ! echo "$out" | grep -qE "$pat"; then
        log_fail "$desc: output did not match /$pat/ — output: $out"; fail=1; return
    fi
}

# Runs on a bare host and always produces a tally.
chk "doctor reports a tally" 0 '[0-9]+ blocking, [0-9]+ advisory' ./dev doctor

# The header names the host and the runtime it resolved.
chk "doctor names the host"    0 '^Host '    ./dev doctor
chk "doctor names the runtime" 0 '^Runtime ' ./dev doctor

# Usage errors exit 2, matching the verb grammar.
chk "bad flag exits 2" 2 'Usage: dev doctor' ./dev doctor --bogus

# block-if-nested promotion. Force the condition rather than skipping past it:
# DEV_FAKE_SYSFS_VALUE=1 makes userns-sysctl fail on ANY host, so this tests
# the promotion instead of this machine's sysctl. Bare, the check is advisory
# and doctor still exits 0; under --dind it becomes blocking and exits 1. If
# both cases ever agree, the promotion has broken.
chk "block-if-nested is advisory when bare" 0 '0 blocking' \
    env DEV_FAKE_SYSFS_VALUE=1 ./dev doctor
chk "block-if-nested is promoted under --dind" 1 '1 blocking' \
    env DEV_FAKE_SYSFS_VALUE=1 ./dev doctor --dind

# A blocking failure exits 1 and names the check. buildx is scoped to docker;
# DEV_RUNTIME=docker is load-bearing: without the pin this host's DOCKER_HOST
# auto-switches RUNTIME to podman, making the check not-applicable and the
# assertion vacuous.
chk "blocking failure exits 1" 1 'buildx' \
    env DEV_RUNTIME=docker DEV_FAKE_BUILDX=false ./dev doctor

# The same failure must NOT block dev up: checks_select's 'blocking' filter
# (cmd_start's only consumer) drops block-in-doctor entirely, so a doctor-only
# failure never reaches dev up's preflight. This does not exercise
# image.sh's own buildx guard (runtime_build is never reached under
# --dry-run) — it pins the other half of the asymmetry: doctor's severity
# model itself, not the real build site.
chk "block-in-doctor does not block dev up" 0 '' \
    env DEV_RUNTIME=docker DEV_FAKE_BUILDX=false ./dev up --dry-run

# An unconfigured host still gets a full report rather than one bare error.
chk "bad DEV_RUNTIME still reports" 1 '[0-9]+ blocking' \
    env DEV_RUNTIME=nosuchruntime ./dev doctor

# Non-tty output is ASCII: this gets pasted into chat.
out=$(./dev doctor 2>&1)
if echo "$out" | LC_ALL=C grep -q '[^ -~]'; then
    log_fail "non-ASCII leaked into non-tty output"; fail=1
fi

[ "$fail" -eq 0 ] || exit 1
log_pass "dev doctor contract: tally, header, exit codes, severity split"
