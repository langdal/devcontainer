#!/usr/bin/env bash
# Unit: dev project-allowlist approval gate (exercised via --dry-run; no
# containers are started). Isolated state via XDG_STATE_HOME tmpdir.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "no container runtime on PATH"; exit 1; }

STATE_HOME=$(mktemp -d)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$STATE_HOME" "$WORKDIR"' EXIT

# Run dev from a scratch workspace so the repo's own allowlist can't
# interfere. Extra env (e.g. DEV_ASSUME_YES=1) is passed as leading args.
run_dev() {
    (cd "$WORKDIR" && env XDG_STATE_HOME="$STATE_HOME" "$@" \
        "$ROOT/dev" --dry-run </dev/null 2>&1)
}

snapshot() {
    find "$STATE_HOME" -name allowlist.approved 2>/dev/null
}

# 1. No allowlist file -> no project mount, no snapshot.
out=$(run_dev)
echo "$out" | grep -q '/etc/devcontainer/project' \
    && { echo "unexpected project mount without allowlist: $out"; exit 1; }
[ -z "$(snapshot)" ] || { echo "snapshot without allowlist file"; exit 1; }

# 2. Unapproved allowlist in dry-run -> 'Would prompt', no mount, no snapshot.
echo "example.com" > "$WORKDIR/.devcontainer-allowlist"
out=$(run_dev)
echo "$out" | grep -q 'Would prompt to approve' \
    || { echo "missing dry-run prompt note: $out"; exit 1; }
echo "$out" | grep -q '/etc/devcontainer/project' \
    && { echo "mounted despite no approval: $out"; exit 1; }
[ -z "$(snapshot)" ] || { echo "snapshot created without approval"; exit 1; }

# 3. DEV_ASSUME_YES=1 approves: snapshot written, mount present.
out=$(run_dev DEV_ASSUME_YES=1)
echo "$out" | grep -q '/etc/devcontainer/project:ro' \
    || { echo "missing ro mount after approval: $out"; exit 1; }
snap=$(snapshot)
[ -n "$snap" ] || { echo "no snapshot after approval"; exit 1; }
grep -qx 'example.com' "$snap" || { echo "snapshot content wrong"; exit 1; }

# 4. Unchanged file on a later run -> mounted without re-approval prompts.
out=$(run_dev)
echo "$out" | grep -q '/etc/devcontainer/project:ro' \
    || { echo "approved allowlist not mounted on later run: $out"; exit 1; }
echo "$out" | grep -q 'Would prompt' \
    && { echo "re-prompted despite unchanged file"; exit 1; }

# 5. Changed file -> unapproved again (no mount in plain dry-run).
echo "another.example.com" >> "$WORKDIR/.devcontainer-allowlist"
out=$(run_dev)
echo "$out" | grep -q 'Would prompt to approve' \
    || { echo "no prompt note after change: $out"; exit 1; }
echo "$out" | grep -q '/etc/devcontainer/project' \
    && { echo "stale approval still mounted: $out"; exit 1; }

# 6. Allowlist removed -> snapshot cleaned up, no mount.
rm "$WORKDIR/.devcontainer-allowlist"
out=$(run_dev)
[ -z "$(snapshot)" ] || { echo "stale snapshot survived file removal"; exit 1; }
echo "$out" | grep -q '/etc/devcontainer/project' \
    && { echo "mount despite removed allowlist"; exit 1; }

# 7. Maintenance mode skips the whole flow (no prompt note even if changed).
echo "example.com" > "$WORKDIR/.devcontainer-allowlist"
out=$(run_dev)   # plain run: establishes the 'Would prompt' baseline
echo "$out" | grep -q 'Would prompt' || { echo "baseline prompt missing: $out"; exit 1; }
out=$( (cd "$WORKDIR" && env XDG_STATE_HOME="$STATE_HOME" \
    "$ROOT/dev" --dry-run --maintenance </dev/null 2>&1) )
echo "$out" | grep -q 'Would prompt' \
    && { echo "maintenance mode prompted for allowlist"; exit 1; }

echo ok
