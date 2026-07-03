# Sandbox Hardening A+C+E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec areas A (allowlist approval gate), C (GITHUB_TOKEN guidance + scope preflight), and E (small-fix bundle) from `docs/superpowers/specs/2026-07-03-sandbox-hardening-design.md`.

**Architecture:** All changes ride on the current file layout (the area-D CLI refactor comes later, in its own plan, as does area B). `dev` gains a host-side per-workspace state directory that holds the *approved* copy of the project allowlist and the GITHUB_TOKEN scope-check cache; the state dir is mounted read-only into the container so the agent-writable workspace file is never consumed directly. Container-side scripts (`firewall-init.sh`, `firewall-disable.sh`, `Dockerfile`) get small, independent fixes.

**Tech Stack:** bash (dev script + container init scripts), Docker/podman, tinyproxy/iptables, the repo's own scenario + unit test harness under `scripts/test/`.

## Global Constraints

- `dev` runs under `set -euo pipefail`; new code must be errexit-safe (use `if` statements for guards that can "fail", never a bare `cmd-that-may-fail` as a statement).
- `dev` host code must run on Linux **and** macOS: no `sha256sum`-only assumptions (macOS has `shasum -a 256`), no GNU-only flags in host-side code. Container-side scripts are Ubuntu-only and may use GNU tools.
- Run `bash scripts/lint.sh` before **every** commit; it must pass (shellcheck is required; install dev tools with `mise install` from the repo root if missing).
- Conventional Commits (`type(scope): subject`, imperative, ≤72 chars). **NEVER `git push`.** End commit messages with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer when committed by an agent.
- Container-side changes (`firewall-init.sh`, `firewall-disable.sh`, `Dockerfile`) are baked into the image: rebuild with `DEV_ASSUME_YES=1 ./dev --build -- true` before any e2e verification of them.
- Unit tests: `bash scripts/test/unit/test-runner.sh` (needs a docker or podman on PATH, no sudo). E2E scenarios: `bash scripts/test/scenarios/<name>.sh` (need passwordless sudo + a runtime; each is self-contained).
- Spec of record: `docs/superpowers/specs/2026-07-03-sandbox-hardening-design.md`. Deviations must be raised, not silently made.

---

### Task 1: Allowlist approval gate in `dev` (host side)

**Files:**
- Modify: `dev` (three insertion points, anchors given below)
- Test: `scripts/test/unit/test-dev-allowlist-approval.sh` (create)

**Interfaces:**
- Consumes: existing globals `WORKSPACE_BASENAME`, `MAINTENANCE`, `DRY_RUN`, `DEV_ASSUME_YES`.
- Produces (used by Task 4): `sha256_portable` (stdin → sha256 hex on stdout), `ensure_state_dir` (sets global `STATE_DIR`, creates the dir), global `STATE_DIR`. Produces (used by Task 2's container side): the read-only mount `-v "$STATE_DIR:/etc/devcontainer/project:ro"` containing `allowlist.approved`.

- [ ] **Step 1: Write the failing unit test**

Create `scripts/test/unit/test-dev-allowlist-approval.sh`:

```bash
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
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `bash scripts/test/unit/test-dev-allowlist-approval.sh`
Expected: FAIL at check 2 with `missing dry-run prompt note` (the flow doesn't exist yet).

- [ ] **Step 3: Add the helpers and approval flow to `dev`**

Insertion point 1 — immediately **after** the `remove_volume_if_exists()` function (after its closing `}`), add:

```bash
# --- Per-workspace host-side state -----------------------------------------
# Holds the approved copy of the project allowlist and the GITHUB_TOKEN
# scope-check cache. Mounted read-only into the container so nothing the
# agent can write inside /workspace is consumed directly by the firewall.

# Portable sha256 of stdin (Linux: sha256sum, macOS: shasum -a 256).
sha256_portable() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# Resolve + create the state dir. Basename plus a 4-char path hash so two
# same-named workspaces at different paths don't share approval state.
STATE_DIR=""
ensure_state_dir() {
  local hash
  hash=$(printf '%s' "$(pwd)" | sha256_portable | cut -c1-4)
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WORKSPACE_BASENAME}-${hash}"
  mkdir -p "$STATE_DIR"
}

# Approval gate for the workspace allowlist. The workspace file is
# agent-writable, so it is never given to the firewall unreviewed: dev
# diffs it against the approved snapshot in STATE_DIR and asks. Decline or
# non-interactive => start WITHOUT the project allowlist (fail-safe, never
# blocks). Sets MOUNT_PROJECT_ALLOWLIST=true when the snapshot is current.
MOUNT_PROJECT_ALLOWLIST=false
approve_project_allowlist() {
  local src=".devcontainer-allowlist"
  local snap="$STATE_DIR/allowlist.approved"
  if [[ "$MAINTENANCE" == true ]]; then
    return 0   # maintenance mode has no firewall; nothing to approve
  fi
  if [[ ! -f "$src" ]]; then
    rm -f "$snap"   # allowlist deleted: drop the stale approval
    return 0
  fi
  if [[ -f "$snap" ]] && cmp -s "$src" "$snap"; then
    MOUNT_PROJECT_ALLOWLIST=true
    return 0
  fi
  local old=/dev/null
  if [[ -f "$snap" ]]; then
    old="$snap"
  fi
  echo "Project allowlist ${src} is new or changed since last approval:" >&2
  diff -u "$old" "$src" >&2 || true
  if [[ "${DEV_ASSUME_YES:-0}" == "1" ]]; then
    echo "DEV_ASSUME_YES set — approving project allowlist." >&2
    cp "$src" "$snap"
    MOUNT_PROJECT_ALLOWLIST=true
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "Would prompt to approve ${src}; continuing without it for --dry-run." >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Warning: stdin is not a TTY; starting WITHOUT the project allowlist." >&2
    echo "         Run 'dev' interactively (or set DEV_ASSUME_YES=1) to approve it." >&2
    return 0
  fi
  local reply
  read -r -p "Approve project allowlist changes? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      cp "$src" "$snap"
      MOUNT_PROJECT_ALLOWLIST=true
      ;;
    *)
      echo "Starting WITHOUT the project allowlist (approval declined)." >&2
      ;;
  esac
}
```

Insertion point 2 — in the main flow, immediately **before** the comment `# Compare host UID/GID and dev-script version to the labels on $IMAGE_TAG.` (i.e. after the three-way `refuse_if_running` block that sets `CONTAINER_NAME`), add:

```bash
ensure_state_dir
approve_project_allowlist
```

(Management commands — `--monitor*`, `--enable/disable-firewall` on a running container, `--reset` — all dispatch and exit earlier, so they never hit the prompt. The attach path execs away before mounts matter; a prompt there is harmless and keeps the snapshot fresh for the next create.)

Insertion point 3 — in the `DOCKER_CMD` construction, immediately **after** the line `DOCKER_CMD+=(-v devcontainer-home:/home/vscode)`, add:

```bash
# Approved project allowlist: mount the state dir read-only. firewall-init.sh
# reads allowlist.approved from here, never from the agent-writable workspace.
if [[ "$MOUNT_PROJECT_ALLOWLIST" == true ]]; then
  DOCKER_CMD+=(-v "$STATE_DIR:/etc/devcontainer/project:ro")
fi
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash scripts/test/unit/test-dev-allowlist-approval.sh`
Expected: `ok`, exit 0. Also run `bash scripts/test/unit/test-runner.sh` — all unit tests PASS.

- [ ] **Step 5: Lint and commit**

```bash
bash scripts/lint.sh
git add dev scripts/test/unit/test-dev-allowlist-approval.sh
git commit -m "feat(dev): gate workspace allowlist behind host-side approval

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `firewall-init.sh` reads the approved snapshot; update scenario 25

**Files:**
- Modify: `firewall-init.sh:9` (the `PROJECT=` assignment)
- Modify: `scripts/test/scenarios/25-private-registry-allowlist.sh:33-43`

**Interfaces:**
- Consumes: the `/etc/devcontainer/project` read-only mount produced by Task 1.
- Produces: nothing new — the merged-filter behavior is unchanged except for the source path.

- [ ] **Step 1: Make the change**

In `firewall-init.sh`, change:

```bash
PROJECT=/workspace/.devcontainer-allowlist
```

to:

```bash
# Approved snapshot mounted read-only by dev (see approve_project_allowlist).
# NEVER read the workspace copy here: /workspace is agent-writable, and an
# agent may not extend its own egress allowlist.
PROJECT=/etc/devcontainer/project/allowlist.approved
```

No other change — the existing `if [ -f "$PROJECT" ]` merge logic already handles the file being absent (unapproved/declined case).

- [ ] **Step 2: Update scenario 25 for the approval flow**

In `scripts/test/scenarios/25-private-registry-allowlist.sh`:

(a) Extend `cleanup_extra()` to also drop the approval snapshot this test creates:

```bash
# shellcheck disable=SC2317  # invoked via trap
cleanup_extra() {
    if [ -f "$ALLOWLIST.bak" ]; then
        mv "$ALLOWLIST.bak" "$ALLOWLIST"
    else
        rm -f "$ALLOWLIST"
    fi
    rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WS}"-*/allowlist.approved
}
```

(b) Change the container invocation to approve the just-written allowlist:

```bash
filter=$(DEV_ASSUME_YES=1 ./dev --dind -- cat /etc/tinyproxy/filter 2>&1) \
    || { log_fail "could not read /etc/tinyproxy/filter inside container"; exit 1; }
```

- [ ] **Step 3: Rebuild the image and run scenario 25**

```bash
DEV_ASSUME_YES=1 ./dev --dind --build -- true
bash scripts/test/scenarios/25-private-registry-allowlist.sh
```

Expected: `[PASS] 25-private-registry-allowlist … .devcontainer-allowlist entry merged into the DinD filter`

- [ ] **Step 4: Lint and commit**

```bash
bash scripts/lint.sh
git add firewall-init.sh scripts/test/scenarios/25-private-registry-allowlist.sh
git commit -m "feat(firewall): consume approved allowlist snapshot, not workspace file

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: E2E scenario for the approval gate + README allowlist docs

**Files:**
- Create: `scripts/test/scenarios/26-allowlist-approval-gate.sh`
- Modify: `README.md` (the "Allowlist files" section)

**Interfaces:**
- Consumes: Tasks 1+2 behavior end-to-end.
- Produces: nothing consumed later.

- [ ] **Step 1: Write the scenario**

Create `scripts/test/scenarios/26-allowlist-approval-gate.sh`:

```bash
#!/bin/bash
# scripts/test/scenarios/26-allowlist-approval-gate.sh
# platform: linux
#
# The workspace allowlist is agent-writable. Verify an entry added WITHOUT
# host-side approval never reaches the tinyproxy filter, and that the same
# entry IS merged once approved (DEV_ASSUME_YES=1 stands in for the prompt).
set -u
LIB="$(dirname "$0")/../lib"
# shellcheck source=scripts/test/lib/assert.sh
. "$LIB/assert.sh"
# shellcheck source=scripts/test/lib/restore.sh
. "$LIB/restore.sh"
require_platform linux
trap restore_host EXIT

cd "$(dirname "$0")/../../.." || exit 1
WS=$(basename "$(pwd)")
N="dev-${WS}"
remember_container "$N"
docker rm -f "$N" 2>/dev/null

ALLOWLIST=".devcontainer-allowlist"
SENTINEL="approval-gate-$(date +%s).example.com"
if [ -f "$ALLOWLIST" ]; then
    cp "$ALLOWLIST" "$ALLOWLIST.bak"
fi
# shellcheck disable=SC2317  # invoked via trap
cleanup_extra() {
    if [ -f "$ALLOWLIST.bak" ]; then
        mv "$ALLOWLIST.bak" "$ALLOWLIST"
    else
        rm -f "$ALLOWLIST"
    fi
    rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WS}"-*/allowlist.approved
}
trap 'cleanup_extra; restore_host' EXIT

# Simulate the agent extending its own allowlist: write the entry and start
# non-interactively with NO approval (fresh state, DEV_ASSUME_YES unset).
echo "$SENTINEL" >> "$ALLOWLIST"
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/devcontainer/${WS}"-*/allowlist.approved

filter=$(./dev -- cat /etc/tinyproxy/filter 2>&1) \
    || { log_fail "could not read filter (unapproved run)"; exit 1; }
escaped="${SENTINEL//./\\\\.}"
if echo "$filter" | grep -Eq "^\\^${escaped}\\\$$"; then
    log_fail "UNAPPROVED workspace allowlist entry reached the filter"
    exit 1
fi
docker rm -f "$N" 2>/dev/null

# Same entry, approved -> merged.
filter=$(DEV_ASSUME_YES=1 ./dev -- cat /etc/tinyproxy/filter 2>&1) \
    || { log_fail "could not read filter (approved run)"; exit 1; }
if ! echo "$filter" | grep -Eq "^\\^${escaped}\\\$$"; then
    log_fail "approved allowlist entry missing from filter"
    exit 1
fi
log_pass "workspace allowlist requires host-side approval before reaching the filter"
exit 0
```

- [ ] **Step 2: Run the scenario**

Run: `bash scripts/test/scenarios/26-allowlist-approval-gate.sh`
Expected: `[PASS] 26-allowlist-approval-gate … workspace allowlist requires host-side approval before reaching the filter`

- [ ] **Step 3: Update the README allowlist docs**

In `README.md`, in the "Allowlist files" section, replace the `.devcontainer-allowlist` bullet:

```markdown
- `.devcontainer-allowlist` at the workspace root — optional, project-specific.
  Because the workspace is writable by the sandboxed agent, `dev` never feeds
  this file to the firewall directly: on start it diffs the file against the
  last **approved** copy (kept under `~/.local/state/devcontainer/`) and asks
  you to approve changes. Declined or non-interactive runs start *without*
  the project allowlist. Restart the container after approving (no rebuild).
```

- [ ] **Step 4: Lint and commit**

```bash
bash scripts/lint.sh
git add scripts/test/scenarios/26-allowlist-approval-gate.sh README.md
git commit -m "test(firewall): prove agent-written allowlist entries need approval

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: GITHUB_TOKEN scope preflight + README guidance

**Files:**
- Modify: `dev` (one new function + one call site)
- Modify: `README.md` (Environment variables section)
- Test: `scripts/test/unit/test-dev-github-token.sh` (create)

**Interfaces:**
- Consumes: `sha256_portable`, `ensure_state_dir`/`STATE_DIR` from Task 1.
- Produces: nothing consumed later.

- [ ] **Step 1: Write the failing unit test**

Create `scripts/test/unit/test-dev-github-token.sh`:

```bash
#!/usr/bin/env bash
# Unit: dev GITHUB_TOKEN scope preflight (curl stubbed via PATH overlay).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { echo "no container runtime on PATH"; exit 1; }

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
        "$ROOT/dev" --dry-run </dev/null 2>&1)
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

echo ok
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `bash scripts/test/unit/test-dev-github-token.sh`
Expected: FAIL at check 1 with `missing scope warning` (function doesn't exist yet).

- [ ] **Step 3: Implement `check_github_token` in `dev`**

Insertion point 1 — immediately **after** the `approve_project_allowlist()` function added in Task 1, add:

```bash
# --- GITHUB_TOKEN scope guidance --------------------------------------------
# The passthrough exists for rate-limit identification; a no-permission
# fine-grained PAT is enough. Warn (never block) when a classic/OAuth token
# carries scopes an agent inside the container could misuse. Probed once per
# distinct token; the scopes string is cached in STATE_DIR and the warning
# re-printed from cache each run so it isn't missed. Probe failures are
# silent and uncached (retried next run).
check_github_token() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    return 0
  fi
  case "$GITHUB_TOKEN" in
    github_pat_*) return 0 ;;   # fine-grained PAT: scoped by construction
  esac
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  local hash cache scopes headers
  hash=$(printf '%s' "$GITHUB_TOKEN" | sha256_portable | cut -c1-16)
  cache="$STATE_DIR/github-token-$hash"
  if [[ ! -f "$cache" ]]; then
    if ! headers=$(curl -fsS -D - -o /dev/null -m 5 \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        https://api.github.com/rate_limit 2>/dev/null); then
      return 0
    fi
    scopes=$(printf '%s' "$headers" | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-oauth-scopes" {print $2; exit}')
    printf '%s\n' "$scopes" > "$cache"
  fi
  scopes=$(cat "$cache")
  if [[ -n "$scopes" ]]; then
    echo "Warning: GITHUB_TOKEN carries OAuth scopes: ${scopes}" >&2
    echo "         Rate-limit identification needs NO scopes — consider a" >&2
    echo "         no-permission fine-grained PAT. See README.md > 'GitHub token'." >&2
  fi
}
```

Insertion point 2 — in the main flow, extend the two lines added by Task 1 to:

```bash
ensure_state_dir
check_github_token
approve_project_allowlist
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash scripts/test/unit/test-dev-github-token.sh`
Expected: `ok`, exit 0. Also `bash scripts/test/unit/test-runner.sh` — all PASS.

- [ ] **Step 5: Add the README section**

In `README.md`, under "### Environment variables", extend the `GITHUB_TOKEN` bullet to:

```markdown
- `GITHUB_TOKEN` — passed through to the container if set on the host, and
  forwarded to image builds as a BuildKit secret. Its purpose is **rate-limit
  identification** (the anonymous GitHub API limit of 60 req/h is shared per
  IP and easily exhausted by `mise install`), so use a token with no power:
  create a **fine-grained PAT** with *no repository access* and *no
  permissions* (GitHub → Settings → Developer settings → Fine-grained tokens
  → "All repositories: none", zero permission grants). `dev` warns once per
  token if a classic token with OAuth scopes is detected — an agent inside
  the container can read the token, so scopes it carries are scopes you hand
  to the agent.
```

- [ ] **Step 6: Lint and commit**

```bash
bash scripts/lint.sh
git add dev README.md scripts/test/unit/test-dev-github-token.sh
git commit -m "feat(dev): warn when GITHUB_TOKEN carries OAuth scopes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Visible banner while the firewall is disabled

**Files:**
- Modify: `firewall-disable.sh` (add banner write before the final echo)
- Modify: `firewall-init.sh` (remove banner near the end)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `/etc/profile.d/zz-fw-disabled-banner.sh` inside the container (test-visible path).

- [ ] **Step 1: Baseline check (the "failing test")**

```bash
DEV_ASSUME_YES=1 ./dev --build -- true
docker rm -f "dev-$(basename "$(pwd)")" 2>/dev/null
DEV_ASSUME_YES=1 ./dev --disable-firewall -- bash -c \
  'test -f /etc/profile.d/zz-fw-disabled-banner.sh && echo BANNER-PRESENT || echo BANNER-MISSING'
```

Expected now: `BANNER-MISSING`.

- [ ] **Step 2: Implement**

In `firewall-disable.sh`, immediately **before** the final `echo 'firewall disabled'`, add:

```bash
# Visible signal for new shells: toggling the firewall does not change the
# container name, so leave a banner (mirrors the maintenance-mode banner).
cat > /etc/profile.d/zz-fw-disabled-banner.sh <<'EOF'
echo
echo "=========================================================="
echo "  FIREWALL DISABLED - all outbound traffic is allowed."
echo "  Re-enable with:  dev --enable-firewall"
echo "=========================================================="
echo
EOF
chmod 644 /etc/profile.d/zz-fw-disabled-banner.sh
```

In `firewall-init.sh`, immediately **before** the final `echo "firewall-init: ready …"` line, add:

```bash
# Clear the firewall-disabled banner if a previous toggle left one.
rm -f /etc/profile.d/zz-fw-disabled-banner.sh
```

- [ ] **Step 3: Verify both directions**

```bash
DEV_ASSUME_YES=1 ./dev --build -- true
docker rm -f "dev-$(basename "$(pwd)")" 2>/dev/null
# Fresh container with firewall pre-disabled -> banner present.
DEV_ASSUME_YES=1 ./dev --disable-firewall -- bash -c \
  'test -f /etc/profile.d/zz-fw-disabled-banner.sh && echo BANNER-PRESENT'
docker rm -f "dev-$(basename "$(pwd)")" 2>/dev/null
# Normal start -> no banner; toggle off -> banner; re-enable -> gone.
DEV_ASSUME_YES=1 ./dev -- sleep 120 &
sleep 20   # allow entrypoint + firewall-init to finish
./dev --disable-firewall
docker exec "dev-$(basename "$(pwd)")" test -f /etc/profile.d/zz-fw-disabled-banner.sh && echo TOGGLED-ON
./dev --enable-firewall
docker exec "dev-$(basename "$(pwd)")" test ! -f /etc/profile.d/zz-fw-disabled-banner.sh && echo CLEARED
docker rm -f "dev-$(basename "$(pwd)")" 2>/dev/null
wait 2>/dev/null
```

Expected: `BANNER-PRESENT`, `TOGGLED-ON`, `CLEARED`.

- [ ] **Step 4: Lint and commit**

```bash
bash scripts/lint.sh
git add firewall-disable.sh firewall-init.sh
git commit -m "feat(firewall): banner in new shells while the firewall is disabled

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Fail the dind build hard on a missing docker `.sha256` sidecar

**Files:**
- Modify: `Dockerfile` (the docker/rootless-extras download loop in the `dind` stage)

- [ ] **Step 1: Implement**

In the `dind` stage's docker-bundle `RUN` (the loop over `docker docker-rootless-extras`), replace the fallback block:

```dockerfile
        curl -fsSLo "${bundle}.tgz.sha256" "${url}.sha256" \
            || (cd /tmp && sha256sum "${bundle}.tgz" > "${bundle}.tgz.sha256.computed" \
                && echo "WARN: docker.com did not publish a .sha256 sidecar for ${bundle}; computed locally:" \
                && cat "${bundle}.tgz.sha256.computed" \
                && cp "${bundle}.tgz.sha256.computed" "${bundle}.tgz.sha256"); \
```

with:

```dockerfile
        curl -fsSLo "${bundle}.tgz.sha256" "${url}.sha256" \
            || { echo "ERROR: no .sha256 sidecar at ${url}.sha256 —" \
                      "refusing to install ${bundle} without checksum verification." \
                      "Pin a DOCKER_VERSION that publishes one." >&2; \
                 exit 1; }; \
```

(The old fallback verified the tarball against a checksum computed *from the same download* — a check that can never fail.)

- [ ] **Step 2: Verify the build still passes**

Run: `DEV_ASSUME_YES=1 ./dev --dind --build -- true`
Expected: image builds (the pinned `DOCKER_VERSION=27.3.1` publishes sidecars). The negative path (missing sidecar) can't be exercised without changing the pin; the code change is the review surface.

- [ ] **Step 3: Lint and commit**

```bash
bash scripts/lint.sh
git add Dockerfile
git commit -m "fix(dind): fail image build when docker checksum sidecar is missing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Single-source the flag docs in README

**Files:**
- Modify: `README.md` (the "## `dev` Flags" section)

- [ ] **Step 1: Implement**

Replace the entire fenced flags block in the "## `dev` Flags" section (the ``` block listing OPTIONS/COMMANDS — keep the "### Environment variables" subsection that follows) with the following markdown (shown in a `~~~` fence so the inner backtick fence nests):

~~~markdown
The authoritative flag reference is built into the script — it cannot drift
from the implementation:

```bash
dev --help
```

Highlights not covered above: `--reset` removes this workspace's containers
and prompts per named volume; `--self-update` updates a git-checkout install
to the latest tag; `--create-dev-container` scaffolds a `.devcontainer/` for
VS Code.
~~~

CLAUDE.md is intentionally untouched: it contains behavior notes and env vars, not a flag list.

- [ ] **Step 2: Verify no drift remains**

Run: `grep -n -- '--monitor-fw\|--default-ports' README.md`
Expected: matches only in prose sections (Daily Use / Firewall controls), not in a stale flags table.

- [ ] **Step 3: Commit**

```bash
bash scripts/lint.sh
git add README.md
git commit -m "docs(readme): point flag reference at dev --help to stop drift

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: `host_runtime()` helper; orchestrator + restore wiring

**Files:**
- Modify: `scripts/test/lib/runtime.sh` (add `host_runtime`)
- Modify: `scripts/test/lib/assert.sh` (resolve and export `RUNTIME`)
- Modify: `scripts/test/run-all.sh:113,118` (use the helper)

**Interfaces:**
- Produces (used by Task 9): `host_runtime` — echoes `docker` or `podman`; `DEV_RUNTIME` env wins; docker preferred (same order as `dev`). Also: every scenario sourcing `assert.sh` gets `RUNTIME` set + exported, which `restore.sh`'s `${RUNTIME:-docker}` then honors.

- [ ] **Step 1: Add `host_runtime` to `scripts/test/lib/runtime.sh`**

Append:

```bash
# Host-side runtime for cleanup/probing, mirroring dev's preference order
# (DEV_RUNTIME override, then docker, then podman). Scenarios and the
# orchestrator use this instead of hardcoding docker so podman-only hosts
# clean up correctly.
host_runtime() {
    if [ -n "${DEV_RUNTIME:-}" ] && command -v "$DEV_RUNTIME" >/dev/null 2>&1; then
        echo "$DEV_RUNTIME"
        return
    fi
    if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
        echo docker
        return
    fi
    echo podman
}
```

- [ ] **Step 2: Resolve `RUNTIME` for every scenario in `scripts/test/lib/assert.sh`**

After the existing `drop_privs_if_root "$@"` line, add:

```bash
# Resolve the host runtime once per scenario. restore.sh's cleanup and the
# scenarios' own container/volume commands use $RUNTIME.
# shellcheck source=scripts/test/lib/runtime.sh
. "$(dirname "${BASH_SOURCE[0]}")/runtime.sh"
RUNTIME="${RUNTIME:-$(host_runtime)}"
export RUNTIME
```

- [ ] **Step 3: Use it in `run-all.sh`**

After the `drop_privs_if_root "$@"` block, add:

```bash
# shellcheck source=scripts/test/lib/runtime.sh
. "$(dirname "$0")/lib/runtime.sh"
RT="$(host_runtime)"
```

and change the two hardcoded cleanup lines to:

```bash
"$RT" rm -f "dev-$(basename "$WORKSPACE")" 2>/dev/null || true
```
```bash
"$RT" rm -f "dev-$(basename "$WORKSPACE")"-dind 2>/dev/null || true
```

- [ ] **Step 4: Verify**

```bash
bash scripts/lint.sh
bash scripts/test/scenarios/30-attack-sudo-iptables.sh   # any cheap scenario: sources assert.sh, must still PASS
```

Expected: lint clean; scenario `[PASS]`.

- [ ] **Step 5: Commit**

```bash
git add scripts/test/lib/runtime.sh scripts/test/lib/assert.sh scripts/test/run-all.sh
git commit -m "fix(test): resolve host runtime instead of hardcoding docker

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Sweep hardcoded `docker` out of the scenario scripts

**Files:**
- Modify (host-side `docker` invocations only): `scripts/test/scenarios/10-cgroupv2-default.sh`, `11-userns-clone-disabled.sh`, `12-fuse-missing.sh`, `13-apparmor-enforcing.sh`, `14-selinux-enforcing.sh`, `15-apparmor-userns-restrict.sh`, `16-rootless-subid-preflight.sh`, `20-mode-conflict-pairs.sh`, `21-monitor-firewall-targets-dind.sh`, `22-cold-start-budget.sh`, `23-cache-persists-restart.sh`, `24-cache-persists-rebuild.sh`, `25-private-registry-allowlist.sh`, `26-allowlist-approval-gate.sh`, `30-attack-sudo-iptables.sh`, `31-attack-privileged-flag.sh`, `32-attack-host-mount.sh`, `33-attack-nested-egress.sh`, `40-uid-gid-default-build.sh`, `41-uid-gid-mismatch-no-tty.sh`, `42-uid-gid-mismatch-rebuild.sh`, `43-uid-gid-running-container.sh`, `44-uid-gid-rebuild-no-volumes.sh`, `46-version-mismatch.sh`

**Interfaces:**
- Consumes: `RUNTIME` (set + exported by `assert.sh`, Task 8).

- [ ] **Step 1: Apply the mechanical substitution**

Rule — in each listed file, replace **host-side** invocations:

- `docker rm …` → `"$RUNTIME" rm …`
- `docker stop …` → `"$RUNTIME" stop …`
- `docker ps …` → `"$RUNTIME" ps …`
- `docker volume …` → `"$RUNTIME" volume …`
- `docker rmi …` → `"$RUNTIME" rmi …`
- `docker images …` → `"$RUNTIME" images …`

Do **NOT** touch:

- Anything after `-- ` in a `./dev … -- docker …` invocation (that is the *nested* docker inside the container — e.g. `23-cache-persists-restart.sh:26`, `24-cache-persists-rebuild.sh:28`).
- `scripts/test/fixtures/pg-smoke.sh` (runs inside the container against nested docker).
- Runtime-specific scenarios `01`–`05` and `90`–`91` (their hardcoded runtimes are the point of the test).
- `scripts/test/lib/restore.sh` (already uses `${RUNTIME:-docker}`).

- [ ] **Step 2: Verify the sweep is complete and didn't overreach**

```bash
# No remaining host-side hardcoded docker (nested-docker lines excluded):
grep -rnE '(^|[[:space:]])docker (rm|stop|ps|volume|rmi|images)\b' \
    scripts/test/scenarios/ | grep -v -- '-- docker' \
    | grep -vE 'scenarios/(0[1-5]|9[01])-'
# Expected: no output.

# Nested-docker lines untouched:
grep -n -- '-- docker images' scripts/test/scenarios/23-cache-persists-restart.sh \
    scripts/test/scenarios/24-cache-persists-rebuild.sh
# Expected: both matches still present.
```

- [ ] **Step 3: Run a representative subset**

```bash
bash scripts/test/scenarios/22-cold-start-budget.sh
bash scripts/test/scenarios/30-attack-sudo-iptables.sh
bash scripts/test/scenarios/40-uid-gid-default-build.sh
```

Expected: all `[PASS]` (or the same `[SKIP]` they produced before the sweep on this host).

- [ ] **Step 4: Lint and commit**

```bash
bash scripts/lint.sh
git add scripts/test/scenarios/
git commit -m "fix(test): use resolved RUNTIME for host-side docker calls in scenarios

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (after Task 9)

```bash
bash scripts/test/unit/test-runner.sh          # all unit tests PASS
sudo bash scripts/test/run-all.sh              # full scenario matrix green
```

The full matrix run is the gate before considering areas A/C/E done. Areas D (CLI subcommands + module split) and B (per-workspace home volume) follow in separate plans, in that order, per the spec's "Implementation order" section.
