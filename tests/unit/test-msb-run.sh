#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/msb.sh"

export BOX_DRY_RUN=1

# _msb prints instead of executing under dry-run.
assert_eq "msb ps" "$(_msb ps)" "_msb prints under dry-run"

# is_running is always false under dry-run (no daemon contacted).
if msb_is_running anything; then
  assert_eq "running" "not-running" "is_running must be false in dry-run"
else
  assert_eq "ok" "ok" "is_running false in dry-run"
fi

# msb_up builds a detached `run -d --name` command with mounts, net, image, NO trailing cmd.
out="$(msb_up box-proj mcr.microsoft.com/devcontainers/base:ubuntu /tmp/p sanctioned github.com)"
assert_contains "$out" "msb run -d --name box-proj" "detached named run"
assert_contains "$out" "--mount-dir /tmp/p:/workspace" "mounts workspace"
assert_contains "$out" "--mount-named box-mise:/mise" "mounts mise volume"
assert_contains "$out" "--net-default-egress deny" "locked egress"
# image is the LAST token, with no trailing `-- cmd`
assert_eq "mcr.microsoft.com/devcontainers/base:ubuntu" "$(echo "$out" | sed 's/.* //')" "image is last token"

# msb_up with no hosts still works (sanctioned, deny only).
out_nohost="$(msb_up box-proj img /tmp/p sanctioned)"
assert_contains "$out_nohost" "msb run -d --name box-proj" "detached run with no hosts"

# attach uses exec against the named sandbox.
assert_contains "$(msb_attach box-proj -- echo hi)" "msb exec box-proj -- echo hi" "attach via exec"

# start_run forwards secrets when provided via BOX_SECRETS env (newline list).
out2="$(BOX_SECRETS=$'GITHUB_TOKEN@api.github.com' \
        msb_up box-proj img /tmp/p sanctioned github.com)"
assert_contains "$out2" "--secret GITHUB_TOKEN@api.github.com" "msb_up forwards secrets"

# No BOX_SECRETS -> no --secret flag.
out3="$(msb_up box-proj img /tmp/p sanctioned github.com)"
assert_eq "" "$(echo "$out3" | grep -o -- '--secret' || true)" "no secrets -> no --secret flag"

finish
