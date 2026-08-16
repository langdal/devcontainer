#!/usr/bin/env bash
# scripts/test/run-rootless.sh — the unprivileged subset under rootless
# podman, with no sudo anywhere.
#
# Why this exists: run-all.sh requires passwordless sudo and drops privileges
# through runuser, so every cell it produces is ROOTFUL. The project's own
# recommended setup on Linux is ROOTLESS podman, and until this cell existed
# nothing tested it — which is how scenarios 41-44 and 46 were able to rot
# undetected under a runtime nobody exercised.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if ! command -v podman >/dev/null 2>&1; then
    echo "FATAL: podman is required for the rootless cell." >&2
    exit 1
fi
if [[ "$(id -u)" -eq 0 ]]; then
    echo "FATAL: run this as your normal user — the point is that it needs no root." >&2
    exit 1
fi
if [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" != "true" ]]; then
    echo "FATAL: podman here is not rootless; this cell would duplicate the rootful one." >&2
    exit 1
fi

export DEV_RUNTIME=podman
export DEV_TEST_PRIVILEGE=user
exec bash scripts/test/run-all.sh "$@"
