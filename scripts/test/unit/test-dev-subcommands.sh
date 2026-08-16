#!/usr/bin/env bash
# Unit: dev verb dispatch (up/exec/shell/down/status/fw/reset). No
# containers are started; every check uses --dry-run, usage output, or an
# error path that fires before any container/runtime work happens.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "SKIP: no container runtime on PATH"; exit 77; }
# Every dev() call below runs with $WORK as cwd, so the workspace basename is
# a fresh mktemp name — never "devcontainer" (this repo's own workspace). That
# guarantees the runtime-detection assertions (fw log / status) see no
# containers for their workspace, even while a real dev-devcontainer* container
# may be running for this checkout; we never touch that one.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
dev() { (cd "$WORK" && "$ROOT/dev" "$@" </dev/null 2>&1); }

# 1. `dev update --dry-run`. Match any self_update dry-run output — its exact
#    text depends on the checkout's state (clean tree => "Would run: git ...
#    fetch"; dirty => "Self-update refuses..."; no repo => "not a git
#    checkout"; etc.) — so the assertion must not assume one state.
out=$(dev update --dry-run); echo "$out" | grep -qiE 'self-update|git checkout|latest tag|would run: git|up to date|fetching tags' \
    || { echo "update subcommand not routed: $out"; exit 1; }

# 2. `dev fw log` with no running container is an error, not a hang.
out=$(dev fw log); echo "$out" | grep -q 'no dev container is running' \
    || { echo "fw log not routed: $out"; exit 1; }

# 3. `dev exec` without `--' is a usage error (exit 2), not a container start.
out=$(dev exec --dry-run); rc=$?
[ "$rc" -eq 2 ] || { echo "exec without -- should exit 2, got $rc: $out"; exit 1; }
echo "$out" | grep -qi 'requires' || { echo "exec without -- missing 'requires': $out"; exit 1; }

# 4. `dev up -- true` rejects the command payload and points at `dev exec`.
out=$(dev up --dry-run -- true); rc=$?
[ "$rc" -eq 2 ] || { echo "up -- true should exit 2, got $rc: $out"; exit 1; }
echo "$out" | grep -q 'dev exec' || { echo "up -- true missing 'dev exec' guidance: $out"; exit 1; }

# 5. `dev status` with nothing running for this (scratch) workspace.
out=$(dev status); echo "$out" | grep -qi 'Nothing running' \
    || { echo "status did not report nothing running: $out"; exit 1; }

# 6. `dev up --dry-run` (no subcommand-specific args): the shim falls through
#    to the start path and prints the run command without executing it.
out=$(dev up --dry-run); echo "$out" | grep -qE 'run .*--rm .*--name' \
    || { echo "up --dry-run start path broken: $out"; exit 1; }

# 7. Unknown verb is an error with guidance.
if dev bogus >/dev/null 2>&1; then echo "unknown verb should fail"; exit 1; fi
out=$(dev bogus 2>&1); echo "$out" | grep -qiE 'unknown|usage' || { echo "no guidance on bad verb: $out"; exit 1; }

# 8. `reset` composes standalone; a start flag with it must be rejected —
#    assert it fails AND does NOT silently start a container.
if out=$(dev reset --dind 2>&1); then echo "reset --dind should be rejected: $out"; exit 1; fi
echo "$out" | grep -qE 'run .*--rm' && { echo "reset --dind wrongly started a container: $out"; exit 1; }

# 9. --help/--version stay position-independent through the `up` verb shim
#     (not just as the bare first token), and the --dind/--maintenance mutex
#     is enforced through the `up` verb path too.
out=$(dev --help); echo "$out" | grep -qi 'usage' || { echo "help broke: $out"; exit 1; }
dev up --dry-run --help | grep -qi usage || { echo "--help not position-independent through 'up'"; exit 1; }
out=$(dev up --dry-run --version); echo "$out" | grep -qi "^dev " \
    || { echo "--version not position-independent through 'up': $out"; exit 1; }
out=$(dev up --dind --maintenance --dry-run 2>&1 || true)
echo "$out" | grep -qi 'mutually exclusive' || { echo "--dind+--maintenance mutex missing via 'up': $out"; exit 1; }

echo ok
