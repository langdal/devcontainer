#!/bin/bash
# scripts/test/scenarios/50-cli-verbs.sh
# platform: linux
# CLI surface contract for the compose-style verb grammar. Container-free:
# every check uses --dry-run, usage output, or error paths only.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
require_platform linux

cd "$(dirname "$0")/../../.." || exit 1

fail=0
chk() { # description, expected-exit, grep-pattern, cmd...
    local desc="$1" want_rc="$2" pat="$3"; shift 3
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        log_fail "$desc: expected exit $want_rc, got $rc — output: $out"; fail=1; return
    fi
    if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
        log_fail "$desc: output missing '$pat' — got: $out"; fail=1
    fi
}

# Usage lists the verb surface.
chk "usage lists up"        0 'dev up'      ./dev --help
chk "usage lists exec"      0 'dev exec'    ./dev --help
chk "usage lists status"    0 'dev status'  ./dev --help
chk "usage lists fw off"    0 'off'         ./dev --help

# up: verb parses, --dry-run prints the run command without executing.
chk "up --dry-run works"    0 'Would\|docker\|podman' ./dev up --dry-run
# up rejects a command payload.
chk "up rejects --"         2 "use 'dev exec'" ./dev up --dry-run -- true
# exec requires --.
chk "exec without -- errors" 2 'requires' ./dev exec --dry-run
# exec --dry-run with a command parses through the verb path.
chk "exec --dry-run works"  0 'Would\|docker\|podman' ./dev exec --dry-run -- true
# --maint spelling accepted (translated to maintenance mode).
chk "up --maint accepted"   0 '' ./dev up --maint --dry-run
# Mode mutual exclusion still enforced through the verb path.
chk "up --dind --pind mutex" 1 'mutually exclusive' ./dev up --dind --pind --dry-run

# fw: new action names exist; action list names off/on.
chk "fw bad action lists off|on" 1 'off' ./dev fw bogus

# shell/status/down are container-free when nothing is running.
# (Scenario harness guarantees no dev-<ws> containers; be defensive anyway.)
WS=$(basename "$(pwd)")
"$RUNTIME" rm -f "dev-${WS}" "dev-${WS}-maint" "dev-${WS}-dind" "dev-${WS}-pind" 2>/dev/null
chk "shell errors when nothing running" 1 "dev up" ./dev shell
chk "status reports nothing running"    0 'Nothing running' ./dev status
chk "down reports nothing running"      0 'Nothing running' ./dev down

# Unknown verb is a hard error.
chk "unknown verb exits 2" 2 '' ./dev frobnicate

# Clean break: legacy spellings are gone.
chk "bare dev prints usage"        0 'VERBS' ./dev
chk "legacy --dind start rejected" 2 '' ./dev --dind -- true
chk "legacy -- start rejected"     2 '' ./dev -- true
chk "fw disable removed"           1 'off'  ./dev fw disable
chk "fw enable removed"            1 'on'   ./dev fw enable
chk "--disable-firewall removed"   2 ''     ./dev --disable-firewall

[ "$fail" -eq 0 ] || exit 1
log_pass "verb grammar surface: up/exec/shell/down/status/fw parse and error contracts hold"
exit 0
