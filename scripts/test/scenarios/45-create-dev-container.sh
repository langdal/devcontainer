#!/bin/bash
# scripts/test/scenarios/45-create-dev-container.sh
# platform: any
#
# `dev --create-dev-container` writes a self-contained .devcontainer/
# in the CWD. Covers: normal mode, collision refusal, --force overwrite,
# dind mode. Pure host-side file manipulation; no container is started.
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEV="${ROOT}/dev"

if [ ! -x "$DEV" ]; then
    log_fail "dev script not found or not executable at $DEV"
    exit 1
fi

# JSON validator: jq is in the base image and on most test hosts.
parse_json() {
    jq -e . "$1" >/dev/null 2>&1
}

# JSONC validator: strip line comments, then validate as JSON.
parse_jsonc() {
    sed 's:^[[:space:]]*//.*$::' "$1" | jq -e . >/dev/null 2>&1
}

# ---------- normal mode: clean dir ----------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "${WORK}_b" "${WORK}_d"' EXIT

cd "$WORK" || exit 1
if ! "$DEV" --create-dev-container >/dev/null 2>&1; then
    log_fail "normal-mode generation failed in clean dir"
    exit 1
fi

for f in devcontainer.json Dockerfile entrypoint.sh firewall-init.sh \
         firewall-disable.sh mise.base.toml allowlist.base; do
    if [ ! -f ".devcontainer/$f" ]; then
        log_fail "normal-mode: expected .devcontainer/$f"
        exit 1
    fi
done
for f in dind-init.sh allowlist.dind; do
    if [ -e ".devcontainer/$f" ]; then
        log_fail "normal-mode: did not expect .devcontainer/$f"
        exit 1
    fi
done
if ! parse_json .devcontainer/devcontainer.json; then
    log_fail "normal-mode: devcontainer.json is not valid JSON"
    exit 1
fi
if ! grep -q '"target": "base"' .devcontainer/devcontainer.json; then
    log_fail "normal-mode: build.target should be \"base\""
    exit 1
fi
if ! grep -q '"--cap-add=NET_ADMIN"' .devcontainer/devcontainer.json; then
    log_fail "normal-mode: --cap-add=NET_ADMIN missing from runArgs"
    exit 1
fi
# VS Code's overrideCommand=true bypasses the image ENTRYPOINT (passes
# --entrypoint /bin/sh). The firewall lives in our entrypoint, so we
# MUST emit overrideCommand=false to keep it on the boot path.
if ! grep -q '"overrideCommand": false' .devcontainer/devcontainer.json; then
    log_fail "normal-mode: overrideCommand must be false (entrypoint runs firewall)"
    exit 1
fi

# ---------- collision: refuse without --force ----------
SHA_BEFORE=$(sha256sum .devcontainer/devcontainer.json | awk '{print $1}')
if "$DEV" --create-dev-container >/dev/null 2>&1; then
    log_fail "second generation should fail without --force"
    exit 1
fi
SHA_AFTER=$(sha256sum .devcontainer/devcontainer.json | awk '{print $1}')
if [ "$SHA_BEFORE" != "$SHA_AFTER" ]; then
    log_fail "refused run still mutated .devcontainer/devcontainer.json"
    exit 1
fi

# ---------- collision: --force overwrites ----------
echo "stub" > .devcontainer/Dockerfile
if ! "$DEV" --create-dev-container --force >/dev/null 2>&1; then
    log_fail "--force should succeed over existing files"
    exit 1
fi
if ! grep -q '^FROM ' .devcontainer/Dockerfile; then
    log_fail "--force did not refresh Dockerfile (still 'stub')"
    exit 1
fi

# ---------- dind mode: clean dir ----------
WORK_D="${WORK}_d"
mkdir -p "$WORK_D"
cd "$WORK_D" || exit 1
if ! "$DEV" --create-dev-container --dind >/dev/null 2>&1; then
    log_fail "dind-mode generation failed"
    exit 1
fi
for f in devcontainer.json Dockerfile entrypoint.sh firewall-init.sh \
         firewall-disable.sh mise.base.toml allowlist.base dind-init.sh allowlist.dind; do
    if [ ! -f ".devcontainer/$f" ]; then
        log_fail "dind-mode: expected .devcontainer/$f"
        exit 1
    fi
done
if ! parse_jsonc .devcontainer/devcontainer.json; then
    log_fail "dind-mode: devcontainer.json is not valid JSONC"
    exit 1
fi
if ! grep -q '"target": "dind"' .devcontainer/devcontainer.json; then
    log_fail "dind-mode: build.target should be \"dind\""
    exit 1
fi
if ! grep -q '"DEVCONTAINER_DIND": "1"' .devcontainer/devcontainer.json; then
    log_fail "dind-mode: containerEnv.DEVCONTAINER_DIND missing"
    exit 1
fi
if ! grep -q '/dev/fuse' .devcontainer/devcontainer.json; then
    log_fail "dind-mode: --device=/dev/fuse missing"
    exit 1
fi
if ! grep -q '"overrideCommand": false' .devcontainer/devcontainer.json; then
    log_fail "dind-mode: overrideCommand must be false (entrypoint runs firewall)"
    exit 1
fi

# ---------- mutual exclusion: rejects --build ----------
WORK_B="${WORK}_b"
mkdir -p "$WORK_B"
cd "$WORK_B" || exit 1
if "$DEV" --create-dev-container --build >/dev/null 2>&1; then
    log_fail "should reject --create-dev-container --build"
    exit 1
fi

log_pass "create-dev-container generates valid normal/dind .devcontainer/"
exit 0
