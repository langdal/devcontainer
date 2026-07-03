#!/usr/bin/env bash
# Unit: dev subcommand dispatch + deprecation aliases (via --dry-run/--help;
# no containers started).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "no container runtime on PATH"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
dev() { (cd "$WORK" && "$ROOT/dev" "$@" </dev/null 2>&1); }

# 1. `update` subcommand == old `--self-update`. Match any self_update dry-run
#    output — its exact text depends on the checkout's state (clean tree =>
#    "Would run: git ... fetch"; dirty => "Self-update refuses..."; no repo =>
#    "not a git checkout"; etc.) — so the assertion must not assume one state.
out=$(dev update --dry-run); echo "$out" | grep -qiE 'self-update|git checkout|latest tag|would run: git|up to date|fetching tags' \
    || { echo "update subcommand not routed: $out"; exit 1; }

# 2. Deprecated alias prints a warning AND still works.
out=$(dev --self-update --dry-run)
echo "$out" | grep -q "deprecated" || { echo "no deprecation warning for --self-update: $out"; exit 1; }
echo "$out" | grep -qiE 'self-update|git checkout|latest tag|would run: git|up to date|fetching tags' \
    || { echo "--self-update alias did not run update: $out"; exit 1; }

# 3. `fw log` with no running container == old `--monitor`: same error.
out=$(dev fw log); echo "$out" | grep -q 'no dev container is running' \
    || { echo "fw log not routed: $out"; exit 1; }
out=$(dev --monitor); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --monitor: $out"; exit 1; }

# 4. `scaffold` writes .devcontainer/ (old --create-dev-container).
(cd "$WORK" && "$ROOT/dev" scaffold >/dev/null 2>&1)
[ -f "$WORK/.devcontainer/devcontainer.json" ] || { echo "scaffold did not write files"; exit 1; }
rm -rf "$WORK/.devcontainer"
out=$(dev --create-dev-container --force); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --create-dev-container: $out"; exit 1; }
rm -rf "$WORK/.devcontainer"

# 5. Default command (no subcommand) still starts: --dry-run prints a run command.
out=$(dev --dry-run -- echo hi); echo "$out" | grep -qE 'run .*--rm .*--name' \
    || { echo "default start path broken: $out"; exit 1; }

# 6. Unknown subcommand is an error with guidance.
if dev bogus >/dev/null 2>&1; then echo "unknown subcommand should fail"; exit 1; fi
out=$(dev bogus 2>&1); echo "$out" | grep -qiE 'unknown|usage' || { echo "no guidance on bad subcommand: $out"; exit 1; }

# 7. `reset` composes standalone; a start flag with it must be rejected —
#    assert it fails AND does NOT silently start a container.
if out=$(dev reset --dind 2>&1); then echo "reset --dind should be rejected: $out"; exit 1; fi
echo "$out" | grep -qE 'run .*--rm' && { echo "reset --dind wrongly started a container: $out"; exit 1; }

# 8. Final-review regression fixes: --help/--version stay position-independent
#    (not just first-token), and the --dind/--maintenance mutex is restored.
out=$(dev --help); echo "$out" | grep -qi 'usage' || { echo "help broke: $out"; exit 1; }
dev --dry-run --help | grep -qi usage || { echo "--help not position-independent"; exit 1; }
out=$(dev --dry-run --version); echo "$out" | grep -qi "^dev " \
    || { echo "--version not position-independent: $out"; exit 1; }
out=$(dev --dind --maintenance --dry-run -- echo hi 2>&1 || true)
echo "$out" | grep -qi 'mutually exclusive' || { echo "--dind+--maintenance mutex missing: $out"; exit 1; }

# 9. Remaining deprecated aliases: --monitor-fw, --disable-firewall,
#    --enable-firewall, --reset. Each must warn AND route to its subcommand.
out=$(dev --monitor-fw); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --monitor-fw: $out"; exit 1; }
echo "$out" | grep -q 'no dev container is running' \
    || { echo "--monitor-fw did not route to fw drops: $out"; exit 1; }

out=$(dev --disable-firewall --dry-run -- echo hi); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --disable-firewall: $out"; exit 1; }
echo "$out" | grep -q 'DEVCONTAINER_FW_DISABLED=1' \
    || { echo "--disable-firewall did not fall through to start with firewall disabled: $out"; exit 1; }

out=$(dev --enable-firewall); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --enable-firewall: $out"; exit 1; }
echo "$out" | grep -q 'no dev container is running' \
    || { echo "--enable-firewall did not route to fw enable: $out"; exit 1; }

out=$(DEV_ASSUME_YES=1 dev --reset); echo "$out" | grep -q "deprecated" \
    || { echo "no deprecation warning for --reset: $out"; exit 1; }
echo "$out" | grep -qiE 'nothing to reset|removing volume|removing container' \
    || { echo "--reset did not route to reset: $out"; exit 1; }

echo ok
