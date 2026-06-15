#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"

run_box() {  # run box in a throwaway project dir, dry-run, provisioned, hermetic state
  local proj; proj="$(mktemp -d)"
  ( cd "$proj" && XDG_STATE_HOME="$proj/.state" BOX_DRY_RUN=1 BOX_ASSUME_PROVISIONED=1 "$ROOT/box" "$@" )
}

# default: boots a detached named sandbox then attaches a shell
def="$(run_box)"
assert_contains "$def" "msb run -d --name box-" "default boots detached sandbox"
assert_contains "$def" "--net-default-egress deny" "default run is locked down"
assert_contains "$def" "msb exec box-" "default attaches a shell"

# one-off command
oneoff="$(run_box -- echo hello)"
assert_contains "$oneoff" "msb exec box-" "one-off uses exec"
assert_contains "$oneoff" "-- echo hello" "one-off passes command"

# provision: open egress
prov="$(run_box provision)"
assert_contains "$prov" "--net-default-egress allow" "provision opens egress"
assert_contains "$prov" "mise install" "provision installs tools"

# net override none -> deny, no allow rules
none="$(run_box --net none)"
assert_contains "$none" "--net-default-egress deny" "net none denies"
assert_eq "" "$(echo "$none" | grep -o 'allow@' || true)" "net none has no allow rules"

# help
help="$(run_box --help)"
assert_contains "$help" "Usage" "help shows usage"

# --net validation: invalid value exits 2
rc=0; out_badnet="$(run_box --net bogus 2>&1)" || rc=$?
assert_eq "2" "$rc" "invalid --net value exits 2"
assert_contains "$out_badnet" "none|sanctioned|full" "invalid --net explains valid values"

# --net validation: missing value exits 2 (not an unbound-variable crash)
rc2=0; out_missing="$(run_box --net 2>&1)" || rc2=$?
assert_eq "2" "$rc2" "missing --net argument exits 2"

finish
