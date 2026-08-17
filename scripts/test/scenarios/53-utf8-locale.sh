#!/bin/bash
# scripts/test/scenarios/53-utf8-locale.sh
# platform: linux
# privilege: user
#
# The container must run under a UTF-8 LC_CTYPE. The base image ships no
# LANG/LC_* at all, which leaves LC_CTYPE=POSIX, and then zsh counts every
# byte of a multi-byte character as its own single-width character. The
# oh-my-zsh `devcontainers` theme puts U+279C (➜, three UTF-8 bytes) in
# PROMPT, so zsh measured the prompt two columns wider than the terminal
# rendered it. Every cursor move after a redraw was off by two: tab-completing
# `mis` and then backspacing left two characters ("mi") painted on screen that
# no keystroke could erase, because the line editor's buffer was already empty
# and it believed those cells belonged to the prompt.
#
# Assert both the cause and the consequence, without needing a pty:
#   1. LC_CTYPE's charmap is UTF-8 in interactive bash and zsh.
#   2. zsh counts the theme's arrow as ONE character (3 under POSIX) — that
#      count is exactly the quantity zsh uses to compute prompt width.
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
    out=$(DEV_ASSUME_YES=1 ./dev exec -- "$shell" -ic \
        'echo "CHARMAP:$(locale charmap 2>/dev/null)"' </dev/null 2>&1)
    if ! echo "$out" | grep -Eqi 'CHARMAP:.*UTF-?8'; then
        log_fail "$shell in the container is not using a UTF-8 charmap"
        echo "$out" | tail -10 >&2
        exit 1
    fi
done

# The prompt-width invariant. printf with octal escapes emits the three bytes
# of U+279C regardless of locale, so the only variable under test is how zsh
# counts them.
# shellcheck disable=SC2016  # runs in the container shell, not the host
out=$(DEV_ASSUME_YES=1 ./dev exec -- zsh -ic \
    'a=$(printf "\342\236\234"); echo "ARROWLEN:${#a}"' </dev/null 2>&1)
if ! echo "$out" | grep -q 'ARROWLEN:1'; then
    log_fail "zsh miscounts the theme's ➜ (expected ARROWLEN:1) — prompt width will be wrong"
    echo "$out" | tail -10 >&2
    exit 1
fi

log_pass "container shells use a UTF-8 charmap and zsh measures the prompt arrow correctly"
exit 0
