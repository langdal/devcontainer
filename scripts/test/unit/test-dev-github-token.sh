#!/usr/bin/env bash
# Unit: dev GITHUB_TOKEN scope preflight (curl stubbed via PATH overlay).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "SKIP: no container runtime on PATH"; exit 77; }

STATE_HOME=$(mktemp -d)
WORKDIR=$(mktemp -d)
STUB=$(mktemp -d)
trap 'rm -rf "$STATE_HOME" "$WORKDIR" "$STUB"' EXIT

# curl stub: classic-token response with scopes; counts invocations.
cat > "$STUB/curl" <<EOF
#!/bin/bash
echo called >> "$STUB/calls"
printf 'HTTP/2 200\r\nx-oauth-scopes: repo, workflow\r\n\r\n'
EOF
chmod +x "$STUB/curl"

run_dev() {
    (cd "$WORKDIR" && env PATH="$STUB:$PATH" XDG_STATE_HOME="$STATE_HOME" "$@" \
        "$ROOT/dev" up --dry-run </dev/null 2>&1)
}

# 1. Scoped classic token -> warning naming the scopes.
out=$(run_dev GITHUB_TOKEN=ghp_dummy123)
echo "$out" | grep -q 'carries OAuth scopes: repo, workflow' \
    || { echo "missing scope warning: $out"; exit 1; }

# 2. Cached verdict: warning repeats, curl is NOT called again.
out=$(run_dev GITHUB_TOKEN=ghp_dummy123)
echo "$out" | grep -q 'carries OAuth scopes' \
    || { echo "cached warning missing: $out"; exit 1; }
[ "$(wc -l < "$STUB/calls")" -eq 1 ] \
    || { echo "curl called more than once for the same token"; exit 1; }

# 3. Fine-grained PAT -> no probe, no warning.
rm -f "$STUB/calls"
out=$(run_dev GITHUB_TOKEN=github_pat_dummy)
echo "$out" | grep -q 'OAuth scopes' \
    && { echo "unexpected warning for fine-grained PAT: $out"; exit 1; }
[ ! -f "$STUB/calls" ] || { echo "curl probed a fine-grained PAT"; exit 1; }

# 4. Unscoped classic token -> silent.
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
printf 'HTTP/2 200\r\nx-oauth-scopes: \r\n\r\n'
EOF
chmod +x "$STUB/curl"
out=$(run_dev GITHUB_TOKEN=ghp_other456)
echo "$out" | grep -q 'OAuth scopes' \
    && { echo "warning for unscoped token: $out"; exit 1; }

# 5. Network failure -> silent, and NOT cached (no cache file written).
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
exit 6
EOF
chmod +x "$STUB/curl"
out=$(run_dev GITHUB_TOKEN=ghp_broken789)
echo "$out" | grep -q 'OAuth scopes' \
    && { echo "warning despite curl failure: $out"; exit 1; }
# Exactly the two earlier tokens (ghp_dummy123, ghp_other456) may have cache
# files; the failed probe must not have written one.
n=$(find "$STATE_HOME" -name 'github-token-*' | wc -l)
[ "$n" -eq 2 ] || { echo "failure verdict was cached ($n cache files, expected 2)"; exit 1; }

# --- injection decisions ----------------------------------------------------
# The value-less `-e GITHUB_TOKEN` in the printed run command is the signal
# that the token was injected; its VALUE never appears (kept out of argv).

# 6. Scoped classic token, --dry-run + non-TTY -> declined, NOT injected.
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
printf 'HTTP/2 200\r\nx-oauth-scopes: repo, workflow\r\n\r\n'
EOF
chmod +x "$STUB/curl"
out=$(run_dev GITHUB_TOKEN=ghp_scoped_a)
echo "$out" | grep -q 'continuing WITHOUT it for --dry-run' \
    || { echo "scoped token under --dry-run should decline: $out"; exit 1; }
echo "$out" | grep -q -- '-e GITHUB_TOKEN' \
    && { echo "declined scoped token must NOT be injected: $out"; exit 1; }

# 7. Same scoped token + DEV_ASSUME_YES=1 -> auto-approved and injected.
out=$(run_dev GITHUB_TOKEN=ghp_scoped_b DEV_ASSUME_YES=1)
echo "$out" | grep -q 'DEV_ASSUME_YES set' \
    || { echo "DEV_ASSUME_YES should auto-approve the scoped token: $out"; exit 1; }
echo "$out" | grep -q -- '-e GITHUB_TOKEN' \
    || { echo "auto-approved scoped token must be injected: $out"; exit 1; }

# 8. DEV_GITHUB_TOKEN -> injected explicitly, unprobed (curl not called), even
#    though its value looks like a scoped classic token.
rm -f "$STUB/calls"
out=$(run_dev DEV_GITHUB_TOKEN=ghp_explicit GITHUB_TOKEN=)
echo "$out" | grep -q 'Injecting DEV_GITHUB_TOKEN' \
    || { echo "DEV_GITHUB_TOKEN should be injected explicitly: $out"; exit 1; }
echo "$out" | grep -q -- '-e GITHUB_TOKEN' \
    || { echo "DEV_GITHUB_TOKEN must reach the container as -e GITHUB_TOKEN: $out"; exit 1; }
[ ! -f "$STUB/calls" ] || { echo "DEV_GITHUB_TOKEN must not be probed for scopes"; exit 1; }

# 9. Fine-grained PAT -> minimal by construction, injected silently.
out=$(run_dev GITHUB_TOKEN=github_pat_minimal)
echo "$out" | grep -q -- '-e GITHUB_TOKEN' \
    || { echo "fine-grained PAT should be injected: $out"; exit 1; }

echo ok
