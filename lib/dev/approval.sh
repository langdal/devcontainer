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

# A freshly approved allowlist only reaches the *live* firewall on the next
# firewall-init.sh run (fresh container start, or `dev fw close`) — it is
# never hot-reloaded into an already-running tinyproxy/iptables. When
# approve_project_allowlist runs, CONTAINER_NAME is already resolved for this
# invocation (resolve_container_name_and_guard runs first in cmd_start), so a
# running container at that point means this call is about to take the
# attach path in attach_existing_container, not a fresh start — the one case
# where approving here does NOT make the new entries live. Print a hint so
# the user doesn't approve the diff and then wonder why the host is still
# blocked.
hint_restart_for_new_allowlist() {
  if container_running "$CONTAINER_NAME" 2>/dev/null; then
    echo "Approved. Restart for the new entries to take effect: 'dev down && dev up', or 'dev fw close' to re-init the filter in place." >&2
  fi
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
    hint_restart_for_new_allowlist
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
      hint_restart_for_new_allowlist
      ;;
    *)
      echo "Starting WITHOUT the project allowlist (approval declined)." >&2
      ;;
  esac
}

# --- GITHUB_TOKEN resolution ------------------------------------------------
# Two ways a token reaches the container as GITHUB_TOKEN:
#
#   1. Ambient GITHUB_TOKEN (the ecosystem-standard name) — scope-guarded.
#      A no-permission fine-grained PAT, or a classic token with zero scopes,
#      is minimal and injected silently. A classic token that carries OAuth
#      scopes is non-minimal: an agent inside the container can read it, so
#      those scopes become the agent's. dev warns and asks [y/N] before
#      injecting it (same idiom as the allowlist gate: DEV_ASSUME_YES
#      auto-approves; --dry-run and a non-TTY stdin fail safe, WITHOUT the
#      token). A token whose scopes can't be verified (offline / probe failed)
#      is injected anyway — that case buys nothing on an offline host, so
#      blocking would only break it.
#
#   2. DEV_GITHUB_TOKEN — an explicit, dev-prefixed opt-in. Setting it IS the
#      act of intent, so its value is injected with no scope check and no
#      prompt (a broad token here is legitimate). Takes precedence over the
#      ambient GITHUB_TOKEN.
#
# Exports the resolved value into dev's own GITHUB_TOKEN and sets
# GH_TOKEN_INJECT. lifecycle.sh gates the value-less `-e GITHUB_TOKEN`
# passthrough on the flag, so the token never appears in the printed --dry-run
# command. The image-build BuildKit secret (lib/dev/image.sh) reads the
# exported GITHUB_TOKEN too; it is host-side only and never reaches the running
# agent, so it stays in use even when container injection is declined. The
# scope probe (_token_scopes) lives in lib/dev/checks-catalog.sh and is shared
# with `dev doctor`'s github-token-scopes check, cached once per token.
resolve_github_token() {
  local inject=false

  # Method 2: explicit dev-prefixed opt-in wins outright, unprobed.
  if [[ -n "${DEV_GITHUB_TOKEN:-}" ]]; then
    export GITHUB_TOKEN="$DEV_GITHUB_TOKEN"
    echo "Injecting DEV_GITHUB_TOKEN into the container as GITHUB_TOKEN (explicit opt-in; scopes not checked)." >&2
    inject=true
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    # Method 1: scope-guard the ambient token. _token_scopes returns non-zero
    # for a fine-grained PAT (rc 2) or an unverifiable probe (rc 1); capture
    # that via `if` so it doesn't trip `set -e` (dev runs -euo pipefail).
    local scopes rc
    if scopes="$(_token_scopes)"; then rc=0; else rc=$?; fi
    if [[ "$rc" -eq 2 ]]; then
      inject=true                       # fine-grained PAT: minimal by construction
    elif [[ "$rc" -eq 1 ]]; then
      echo "Note: could not verify GITHUB_TOKEN scopes (offline or probe failed); injecting it anyway." >&2
      inject=true
    elif [[ -z "$scopes" ]]; then
      inject=true                       # classic token, zero scopes: minimal
    else
      echo "Warning: GITHUB_TOKEN carries OAuth scopes: ${scopes}" >&2
      echo "         An agent inside the container can read it, so those scopes" >&2
      echo "         become the agent's. Rate-limit identification needs NONE —" >&2
      echo "         a no-permission fine-grained PAT is enough (README.md >" >&2
      echo "         'GitHub token'). To hand this token to the agent on purpose," >&2
      echo "         set DEV_GITHUB_TOKEN instead and this prompt is skipped." >&2
      if [[ "${DEV_ASSUME_YES:-0}" == "1" ]]; then
        echo "DEV_ASSUME_YES set — injecting the scoped GITHUB_TOKEN." >&2
        inject=true
      elif [[ "$DRY_RUN" == true ]]; then
        echo "Would prompt to inject the scoped GITHUB_TOKEN; continuing WITHOUT it for --dry-run." >&2
      elif [[ ! -t 0 ]]; then
        echo "         stdin is not a TTY; starting WITHOUT GITHUB_TOKEN. Run dev" >&2
        echo "         interactively, set DEV_ASSUME_YES=1, or use DEV_GITHUB_TOKEN." >&2
      else
        local reply=""
        read -r -p "Inject this scoped GITHUB_TOKEN into the container? [y/N] " reply || reply=""
        case "$reply" in
          y|Y|yes|YES) inject=true ;;
          *) echo "Starting WITHOUT GITHUB_TOKEN (declined)." >&2 ;;
        esac
      fi
    fi
  fi

  # shellcheck disable=SC2034  # consumed by start_container in lib/dev/lifecycle.sh
  GH_TOKEN_INJECT=$inject
}
