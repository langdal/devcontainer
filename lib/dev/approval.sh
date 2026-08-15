# shellcheck shell=bash
# lib/dev/approval.sh — per-workspace host-side state: the state directory
# itself, the approval gate for the agent-writable project allowlist, and the
# GITHUB_TOKEN scope warning cached beside it. Sourced by dev; not executed
# directly.

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
approve_project_allowlist() {
  local src=".devcontainer-allowlist"
  local snap="$STATE_DIR/allowlist.approved"
  if [[ "$MAINTENANCE" == true ]]; then
    return 0   # maintenance mode has no firewall; nothing to approve
  fi
  if [[ -L "$src" ]]; then
    echo "Warning: $src is a symlink; refusing to follow it. Starting WITHOUT the project allowlist." >&2
    rm -f "$snap"
    return 0
  fi
  if [[ ! -f "$src" ]]; then
    rm -f "$snap"   # allowlist absent (or not a regular file): drop the stale approval
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
  diff -u "$old" "$src" 2>&1 | head -n 200 >&2 || true
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
  local reply=""
  read -r -p "Approve project allowlist changes? [y/N] " reply || reply=""
  case "$reply" in
    y|Y|yes|YES)
      cp "$src" "$snap"
      # shellcheck disable=SC2034  # consumed by append_volume_mounts in lib/dev/volumes.sh
      MOUNT_PROJECT_ALLOWLIST=true
      ;;
    *)
      echo "Starting WITHOUT the project allowlist (approval declined)." >&2
      ;;
  esac
}

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
