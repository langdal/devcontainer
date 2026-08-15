#!/bin/bash
# scripts/test/scenarios/16-rootless-subid-preflight.sh
# platform: linux
# privilege: user
#
# Under a rootless runtime the dind container's user namespace only spans
# the ids granted in /etc/subuid + /etc/subgid (typically 65536). rootless
# dockerd inside the container must map container ids 100000-165535 (the
# image's vscode subuid range), so with the typical grant it dies ~15s in
# with "newuidmap: write to uid_map failed". dev preflights the grant and
# must refuse fast with a remediation message; with a sufficient grant it
# must not block.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
require_platform linux

cd "$(dirname "$0")/../../.." || exit 1

# The preflight only fires on rootless runtimes.
runtime=docker
command -v docker >/dev/null 2>&1 || runtime=podman
if "$runtime" --version 2>/dev/null | grep -qi podman; then
    [ "$("$runtime" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ] \
        || { log_skip "runtime is rootful; preflight cannot fire"; exit 0; }
else
    "$runtime" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless \
        || { log_skip "runtime is rootful; preflight cannot fire"; exit 0; }
fi

# Mirror dev's grant computation (file parse is enough for the scenario).
total=0
while IFS=: read -r owner _ count; do
    [ "$owner" = "$(id -un)" ] || [ "$owner" = "$(id -u)" ] || continue
    total=$((total + count))
done < /etc/subuid

if [ "$total" -ge 165535 ]; then
    # Sufficient grant: the preflight must NOT block. --dry-run exercises
    # the preflight (it runs before the dry-run printout) without starting
    # a container.
    out=$(timeout 60 ./dev exec --dry-run --dind -- docker version 2>&1)
    rc=$?
    if [ "$rc" != 0 ] || echo "$out" | grep -q "DEV_SKIP_SUBID_CHECK"; then
        log_fail "preflight blocked --dind despite a sufficient subuid grant ($total): $out"
        exit 1
    fi

    # --pind shares the same preflight; a sufficient grant must not block it either.
    out=$(timeout 60 ./dev exec --dry-run --pind -- docker version 2>&1)
    rc=$?
    if [ "$rc" != 0 ] || echo "$out" | grep -q "DEV_SKIP_SUBID_CHECK"; then
        log_fail "preflight blocked --pind despite a sufficient subuid grant ($total): $out"
        exit 1
    fi

    log_pass "sufficient subuid grant ($total) passes the preflight"
    exit 0
fi

"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null

# Insufficient grant: dev should refuse fast (well under 30s), emitting
# the remediation message on stderr.
out=$(timeout 30 ./dev exec --dind -- docker version 2>&1)
rc=$?

if [ "$rc" = 0 ]; then
    log_fail "expected --dind to refuse with a $total-id subuid grant but it succeeded"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null
    exit 1
fi

if ! expect_grep "$out" "usermod --add-subuids"; then
    log_fail "expected remediation mentioning usermod --add-subuids; got: $out"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null
    exit 1
fi

# Verify the bypass env var actually bypasses the preflight. We don't
# expect rootless dockerd to succeed (the grant is still too small), but
# the failure should now come from dind-init/rootlesskit, not the preflight.
out=$(timeout 60 env DEV_SKIP_SUBID_CHECK=1 ./dev exec --dind -- docker version 2>&1)
if expect_grep "$out" "DEV_SKIP_SUBID_CHECK=1 to bypass"; then
    log_fail "DEV_SKIP_SUBID_CHECK=1 did not bypass the preflight"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null
    exit 1
fi

"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-dind 2>/dev/null

"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null

# Insufficient grant: --pind shares the same preflight and should refuse
# fast (well under 30s), emitting the same remediation message on stderr.
out=$(timeout 30 ./dev exec --pind -- docker version 2>&1)
rc=$?

if [ "$rc" = 0 ]; then
    log_fail "expected --pind to refuse with a $total-id subuid grant but it succeeded"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
    exit 1
fi

if ! expect_grep "$out" "usermod --add-subuids"; then
    log_fail "expected remediation mentioning usermod --add-subuids; got: $out"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
    exit 1
fi

# Verify the bypass env var actually bypasses the preflight for --pind too.
out=$(timeout 60 env DEV_SKIP_SUBID_CHECK=1 ./dev exec --pind -- docker version 2>&1)
if expect_grep "$out" "DEV_SKIP_SUBID_CHECK=1 to bypass"; then
    log_fail "DEV_SKIP_SUBID_CHECK=1 did not bypass the preflight for --pind"
    "$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
    exit 1
fi

"$RUNTIME" rm -f "dev-$(basename "$(pwd)")"-pind 2>/dev/null
log_pass "insufficient subuid grant ($total) produces a clean preflight refusal for --dind and --pind"
exit 0
