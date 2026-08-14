#!/bin/bash
# scripts/test/scenarios/15-apparmor-userns-restrict.sh
# platform: linux
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux

# This sysctl exists on Ubuntu 23.10+ / current Debian / Pop!_OS, gating
# unprivileged userns creation behind AppArmor. Older kernels and non-
# AppArmor distros don't expose it.
if ! sysctl -n kernel.apparmor_restrict_unprivileged_userns >/dev/null 2>&1; then
    log_skip "kernel.apparmor_restrict_unprivileged_userns not present on this kernel"
    exit 0
fi

snapshot_sysctl kernel.apparmor_restrict_unprivileged_userns
trap restore_host EXIT

sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=1 >/dev/null

cd "$(dirname "$0")/../../.." || exit 1
"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null

# The dev script preflights this and should refuse fast (well under 30s),
# emitting the remediation message on stderr.
out=$(timeout 30 ./dev exec --dind -- docker version 2>&1)
rc=$?

if [ "$rc" = 0 ]; then
    log_fail "expected --dind to refuse with apparmor_restrict_unprivileged_userns=1 but it succeeded"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null
    exit 1
fi

if ! expect_grep "$out" "apparmor_restrict_unprivileged_userns"; then
    log_fail "expected diagnostic mentioning apparmor_restrict_unprivileged_userns; got: $out"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null
    exit 1
fi

# Verify the bypass env var actually bypasses the preflight. We don't
# expect dockerd-rootless to succeed (the kernel will still block it),
# but the failure should now come from rootlesskit, not the preflight.
out=$(timeout 30 env DEV_SKIP_APPARMOR_CHECK=1 ./dev exec --dind -- docker version 2>&1)
if expect_grep "$out" "kernel.apparmor_restrict_unprivileged_userns=1 on this host"; then
    log_fail "DEV_SKIP_APPARMOR_CHECK=1 did not bypass the preflight"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null
    exit 1
fi

"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null

"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null

# --pind shares the same preflight and should refuse fast (well under
# 30s) with the same remediation message on stderr.
out=$(timeout 30 ./dev exec --pind -- docker version 2>&1)
rc=$?

if [ "$rc" = 0 ]; then
    log_fail "expected --pind to refuse with apparmor_restrict_unprivileged_userns=1 but it succeeded"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
    exit 1
fi

if ! expect_grep "$out" "apparmor_restrict_unprivileged_userns"; then
    log_fail "expected diagnostic mentioning apparmor_restrict_unprivileged_userns; got: $out"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
    exit 1
fi

# Verify the bypass env var actually bypasses the preflight for --pind too.
out=$(timeout 30 env DEV_SKIP_APPARMOR_CHECK=1 ./dev exec --pind -- docker version 2>&1)
if expect_grep "$out" "kernel.apparmor_restrict_unprivileged_userns=1 on this host"; then
    log_fail "DEV_SKIP_APPARMOR_CHECK=1 did not bypass the preflight for --pind"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
    exit 1
fi

"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
log_pass "apparmor_restrict_unprivileged_userns=1 produces a clean preflight failure with remediation for --dind and --pind"
exit 0
