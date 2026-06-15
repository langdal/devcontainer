#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/msb.sh"

# --- net args ---
assert_eq "--net-default-egress"$'\n'"allow" "$(msb_net_args full)" "full = open egress"
assert_eq "--net-default-egress"$'\n'"deny" "$(msb_net_args none)" "none = deny, no rules"

san="$(msb_net_args sanctioned github.com '*.npmjs.org')"
assert_contains "$san" "--net-default-egress"$'\n'"deny" "sanctioned denies by default"
assert_contains "$san" "allow@github.com:tcp:443" "sanctioned allows listed host"
assert_contains "$san" "allow@*.npmjs.org:tcp:443" "sanctioned allows wildcard host"

# sanctioned with NO hosts emits just the deny default, no --net-rule
assert_eq "--net-default-egress"$'\n'"deny" "$(msb_net_args sanctioned)" "sanctioned no hosts = deny only"

# --- mount args ---
m="$(msb_mount_args /home/jakobl/proj box-mise:/mise box-home:/home/vscode)"
assert_contains "$m" "--mount-dir"$'\n'"/home/jakobl/proj:/workspace" "workspace bind mount"
assert_contains "$m" "--mount-named"$'\n'"box-mise:/mise" "mise volume"
assert_contains "$m" "--mount-named"$'\n'"box-home:/home/vscode" "home volume"

# --- secret args ---
s="$(msb_secret_args GITHUB_TOKEN@api.github.com ANTHROPIC_API_KEY@api.anthropic.com)"
assert_contains "$s" "--secret"$'\n'"GITHUB_TOKEN@api.github.com" "secret 1"
assert_contains "$s" "--secret"$'\n'"ANTHROPIC_API_KEY@api.anthropic.com" "secret 2"
assert_eq "" "$(msb_secret_args)" "no secrets -> empty"

finish
