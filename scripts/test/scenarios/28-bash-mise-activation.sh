#!/bin/bash
# scripts/test/scenarios/28-bash-mise-activation.sh
# platform: linux
#
# mise must be *activated* (not merely reachable via the /mise/shims PATH
# entry) in an interactive shell, because activation is what exports tool env
# vars like JAVA_HOME. Historically only .zshrc carried `mise activate`, so a
# bash shell resolved tool binaries via the shim but left JAVA_HOME unset,
# breaking gradlew and other JAVA_HOME-dependent tooling. Verify bash AND zsh
# both activate mise (activation defines a `mise` shell function).
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
N="dev-$(basename "$(pwd)")"
remember_container "$N"

for shell in bash zsh; do
    # shellcheck disable=SC2016  # runs in the container shell, not the host
    out=$(DEV_ASSUME_YES=1 ./dev -- "$shell" -ic 'echo "MISEFN:$(type -t mise 2>/dev/null || whence -w mise)"' </dev/null 2>&1)
    if ! echo "$out" | grep -Eq 'MISEFN:.*function'; then
        log_fail "mise is not activated in an interactive $shell shell (JAVA_HOME et al. would be unset)"
        echo "$out" | tail -10 >&2
        exit 1
    fi
done

log_pass "mise activation is present in both interactive bash and zsh"
exit 0
