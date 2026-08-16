# shellcheck shell=bash
# lib/dev/update.sh — `dev update` (self-update the git checkout to latest tag).
# Sourced by dev; not executed directly.

# cmd_update [--dry-run]: the `dev update` verb.
cmd_update() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) DRY_RUN=true; shift ;;
      *)
        echo "Error: dev update: unknown option: $1" >&2
        exit 1
        ;;
    esac
  done
  self_update
  exit 0
}

# --self-update: pull the latest tag in the script's git checkout in place.
# Detection model: we treat "installed via install.sh OR manual git clone" as
# the same case — both produce a git checkout at SCRIPT_DIR. The git checkout
# itself is the source of truth for the installed version (`git describe`),
# so there is no separate marker file to drift out of sync with reality.
self_update() {
  if ! command -v git >/dev/null 2>&1; then
    echo "Error: git is required for --self-update." >&2
    exit 1
  fi
  if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    echo "Error: $SCRIPT_DIR is not a git checkout — --self-update only works" >&2
    echo "       on install-script (or manual git-clone) installations." >&2
    echo "       Re-install via:" >&2
    echo "         curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]]; then
    echo "Error: uncommitted changes in $SCRIPT_DIR — commit, stash, or reset" >&2
    echo "       before retrying. Self-update refuses to clobber local edits." >&2
    exit 1
  fi
  local origin_url
  origin_url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$origin_url" ]]; then
    echo "Error: no 'origin' remote configured in $SCRIPT_DIR." >&2
    exit 1
  fi
  local current_desc current_tag
  current_desc="$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || echo "unknown")"
  current_tag="$(git -C "$SCRIPT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"

  if [[ "$DRY_RUN" == true ]]; then
    echo "Would run: git -C $SCRIPT_DIR fetch --tags --prune origin"
  else
    echo ">> fetching tags from $origin_url"
    git -C "$SCRIPT_DIR" fetch --tags --prune origin
  fi

  # Same sort AND prerelease filter as install.sh: version:refname picks the
  # highest semver tag, but without a versionsort.suffix hint it ranks
  # v1.0.0-rc.1 after v1.0.0 (longer string wins on tie) — so filter to
  # strict vMAJOR.MINOR.PATCH tags first, keeping prereleases (-rc, -beta,
  # ...) from ever becoming the update target.
  local latest
  latest="$(git -C "$SCRIPT_DIR" ls-remote --tags --refs --sort='version:refname' origin 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | tail -1)"
  if [[ -z "$latest" ]]; then
    echo "Error: no tags advertised by origin ($origin_url)." >&2
    exit 1
  fi

  if [[ -n "$current_tag" && "$current_tag" == "$latest" ]]; then
    echo "Already up to date: $current_tag"
    return 0
  fi

  echo ">> latest tag: $latest"
  echo ">> current:    ${current_tag:-$current_desc}"

  if [[ "$DRY_RUN" == true ]]; then
    echo "Would run: git -C $SCRIPT_DIR checkout --quiet --force $latest"
    return 0
  fi

  git -C "$SCRIPT_DIR" checkout --quiet --force "$latest"
  echo "Updated dev to $latest. The image will prompt for a rebuild on the"
  echo "next 'dev' run (or run 'dev up --build' now to rebuild immediately)."
}
