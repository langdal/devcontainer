#!/bin/bash
# scripts/test/scenarios/50-cli-verbs.sh
# platform: linux
# privilege: user
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
    out=$("$@" </dev/null 2>&1); rc=$?
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
chk "usage lists fw open"   0 'fw open'     ./dev --help

# up: verb parses, --dry-run prints the run command without executing.
chk "up --dry-run works"    0 'Would\|docker\|podman' ./dev up --dry-run
# up rejects a command payload.
chk "up rejects --"         2 "use 'dev exec'" ./dev up --dry-run -- true
# exec requires --.
chk "exec without -- errors" 2 'requires' ./dev exec --dry-run
# ... and a command after it: a bare -- must not become an interactive attach.
chk "exec with empty -- errors" 2 'command' ./dev exec --dry-run --
# exec --dry-run with a command parses through the verb path.
chk "exec --dry-run works"  0 'Would\|docker\|podman' ./dev exec --dry-run -- true
# --maint spelling accepted (translated to maintenance mode).
chk "up --maint accepted"   0 '' ./dev up --maint --dry-run
# Mode mutual exclusion still enforced through the verb path.
chk "up --dind --pind mutex" 1 'mutually exclusive' ./dev up --dind --pind --dry-run
# --closed is accepted as an explicit egress mode.
chk "up --closed accepted"  0 '' ./dev up --closed --dry-run
# DEV_EGRESS host env sets the default egress mode.
chk "DEV_EGRESS closed resolves" 0 '' env DEV_EGRESS=closed ./dev up --dry-run
# A bogus DEV_EGRESS value is a hard error, not a silent fallback.
chk "DEV_EGRESS bogus rejected" 2 "open' or 'closed" env DEV_EGRESS=bogus ./dev up --dry-run

# fw: new action names exist; action list names open/close/log/drops.
chk "fw bad action lists open|close" 1 'open|close' ./dev fw bogus

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
chk "fw off removed"      1 "renamed: use 'dev fw open'"  ./dev fw off
chk "fw on removed"       1 "renamed: use 'dev fw close'" ./dev fw on
chk "fw disable removed" 1 "renamed: use 'dev fw open'"  ./dev fw disable
chk "fw enable removed"  1 "renamed: use 'dev fw close'" ./dev fw enable
chk "--disable-firewall removed"   2 ''     ./dev --disable-firewall

[ "$fail" -eq 0 ] || exit 1
log_pass "verb grammar surface: up/exec/shell/down/status/fw parse and error contracts hold"
exit 0
