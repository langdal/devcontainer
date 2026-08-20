#!/bin/bash
# scripts/test/scenarios/49-agent-inject-podman.sh
# platform: linux
# privilege: user
#
# The docker path of `dev agent` (scenario 48) never exercises the
# runtime-specific behaviour that two real host bugs slipped through:
#   1. --userns=keep-id ownership on the copy/list/rm helper containers
#      (without it, rootless podman maps vscode to a subuid that cannot even
#      `cd /home/vscode`, so list/rm silently see nothing);
#   2. idempotent home-volume creation (`podman volume create` errors when
#      the volume already exists, unlike docker's, aborting the copy).
# This scenario forces rootless podman (even when a docker is also present)
# and runs the full add -> list -> rm cycle over a PRE-EXISTING volume.
#
# Why the `pi` agent and not `claude`: rootless podman keeps its image and
# volume storage under $HOME, so we must NOT override HOME (scenario 48's
# trick for faking the manifest source) — doing so points podman at an empty
# storage with no image/volumes. `pi` is the one agent whose source dir is
# relocatable via PI_CODING_AGENT_DIR, so we fake the source there and leave
# the real HOME (hence podman's real storage) intact.

# Force podman for both `dev` (DEV_RUNTIME) and our own probes/cleanup
# (RUNTIME). Set before sourcing assert.sh, which resolves RUNTIME once at
# source time; restore.sh also honours RUNTIME for cleanup.
export DEV_RUNTIME=podman
# shellcheck disable=SC2034  # consumed by assert.sh (RUNTIME resolution) and restore.sh (cleanup)
RUNTIME=podman

set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/runtime.sh
. "$LIB/runtime.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux

# --- preconditions (skip, don't fail, when podman isn't the right shape) ---
command -v podman >/dev/null 2>&1 || { log_skip "podman not installed"; exit 0; }
podman info >/dev/null 2>&1 || { log_skip "podman not usable (podman info failed)"; exit 0; }
if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" != "true" ]; then
    log_skip "podman is not rootless (keep-id path not applicable)"; exit 0
fi
# The helper image must exist in podman storage. run-all builds it when the
# detected runtime is podman; on a docker-only build it won't be here.
if ! podman image inspect generic-devcontainer >/dev/null 2>&1; then
    log_skip "generic-devcontainer not in podman storage (build: DEV_RUNTIME=podman ./dev up --build)"; exit 0
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEV="${ROOT}/dev"

WORK="$(mktemp -d)/proj-agent49"
mkdir -p "$WORK"
VOL="devcontainer-home-proj-agent49"
# Fake pi source dir (NOT under HOME); dev reads it via PI_CODING_AGENT_DIR.
PI_DIR="$(mktemp -d)"
export PI_CODING_AGENT_DIR="$PI_DIR"

# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup_extra() { rm -rf "$WORK" "$PI_DIR"; }
trap 'cleanup_extra; restore_host' EXIT

remember_volume "$VOL"
remember_container "dev-proj-agent49"
# Defensive pre-removal of stale state from an aborted prior run.
podman rm -f dev-proj-agent49 >/dev/null 2>&1 || true
podman volume rm "$VOL" >/dev/null 2>&1 || true

# Fake pi config: curated files that must be copied + excluded ones that must
# not. Layout matches ~/.pi/agent/ (PI_CODING_AGENT_DIR replaces that base).
printf '{}\n'        > "$PI_DIR/auth.json"       # secret -> 0600
printf '{}\n'        > "$PI_DIR/settings.json"
printf '{"k":"v"}\n' > "$PI_DIR/models.json"     # secret (inline API keys) -> 0600
mkdir -p "$PI_DIR/skills"       && printf 's\n' > "$PI_DIR/skills/demo.md"
mkdir -p "$PI_DIR/extensions"   && printf 'e\n' > "$PI_DIR/extensions/demo.md"
# Excluded (session/trust state) — must never land in the volume.
mkdir -p "$PI_DIR/sessions"     && printf 'log\n' > "$PI_DIR/sessions/s1.json"
printf '{}\n'        > "$PI_DIR/trust.json"

# Pre-create the home volume so `add` exercises the "volume already exists"
# path (the podman idempotency bug: it must not abort when present).
podman volume create "$VOL" >/dev/null

# Probe the volume the same way the real helpers do: as vscode under the exact
# keep-id form dev uses. Read, not hardcoded — dev passes
# keep-id:uid=1000,gid=1000 on podman 4.3+ and the bare flag below that
# (lib/dev/ids.sh). The bare flag was equivalent only on a uid-1000 host, so on
# CI (runner uid 1001) every probe here reported the copied files missing.
read -r _ _ KEEPID_FLAG <<< "$(expected_image_ids)"
# This scenario already skipped unless the host is rootless podman, so both
# ids.sh branches must yield a flag; an empty one would silently pass an empty
# argument to podman and is itself the regression worth catching.
if [ -z "$KEEPID_FLAG" ]; then
    log_fail "expected_image_ids reported no keep-id flag on a rootless-podman host"
    exit 1
fi
vol_has() {
    podman run --rm "$KEEPID_FLAG" -u vscode -v "$VOL":/home/vscode \
        --entrypoint sh generic-devcontainer -c "test -e /home/vscode/$1"
}
vol_mode() {
    podman run --rm "$KEEPID_FLAG" -u vscode -v "$VOL":/home/vscode \
        --entrypoint sh generic-devcontainer -c "stat -c %a /home/vscode/$1"
}

# --- add over a pre-existing volume (idempotency + keep-id copy) ---
if ( cd "$WORK" && "$DEV" agent add pi ) >/dev/null 2>&1; then
    log_pass "dev agent add pi succeeds over a pre-existing volume (podman idempotency)"
else
    log_fail "dev agent add pi failed under podman (volume-create idempotency regression?)"
fi

if vol_has ".pi/agent/auth.json"; then
    log_pass "auth.json landed in the volume (podman keep-id copy)"
else
    log_fail "auth.json missing from volume under podman"
fi
if vol_has ".pi/agent/skills/demo.md"; then
    log_pass "skills/ dir landed in the volume (podman)"
else
    log_fail "skills/demo.md missing from volume under podman"
fi
if [ "$(vol_mode .pi/agent/auth.json)" = "600" ]; then
    log_pass "auth.json is mode 600 in the volume (podman)"
else
    log_fail "auth.json mode is $(vol_mode .pi/agent/auth.json) under podman, want 600"
fi
if [ "$(vol_mode .pi/agent/models.json)" = "600" ]; then
    log_pass "models.json is mode 600 in the volume (podman)"
else
    log_fail "models.json mode is $(vol_mode .pi/agent/models.json) under podman, want 600"
fi
if vol_has ".pi/agent/sessions" || vol_has ".pi/agent/trust.json"; then
    log_fail "an excluded pi path leaked into the volume under podman"
else
    log_pass "excluded pi paths absent from the volume (podman)"
fi

# --- list: the keep-id probe must be able to traverse /home/vscode ---
listout="$( cd "$WORK" && "$DEV" agent list 2>&1 )"
if echo "$listout" | grep -q "can't cd to /home/vscode"; then
    log_fail "list probe hit the keep-id cd bug under podman: $listout"
elif echo "$listout" | grep -E "pi .* yes .* yes" >/dev/null; then
    log_pass "list shows pi injected under podman (keep-id probe works)"
else
    log_fail "list did not show pi injected under podman: $listout"
fi

# --- rm: the keep-id helper must be able to delete under /home/vscode ---
if ( cd "$WORK" && DEV_ASSUME_YES=1 "$DEV" agent rm pi ); then
    :
else
    log_fail "dev agent rm pi exited non-zero under podman"
fi
if vol_has ".pi/agent/auth.json"; then
    log_fail "rm did not remove files under podman (keep-id helper?)"
else
    log_pass "rm removed pi's injected files under podman"
fi

exit 0
