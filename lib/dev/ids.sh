# shellcheck shell=bash
# lib/dev/ids.sh — which uid/gid the image is built for, and how
# --userns=keep-id maps the host user onto it. Sourced by dev; not executed
# directly.

# --- Image ids and the rootless-podman id mapping ---------------------------
# Two decisions that must agree: which uid/gid the image bakes into `vscode`,
# and how --userns=keep-id maps the host user onto it.
#
# Docker and rootful podman do not remap ids, so the image bakes the host's own
# uid/gid and the workspace bind mount lines up directly.
#
# Rootless podman remaps: every container id must land inside the invoking
# user's /etc/subuid + /etc/subgid grant (typically 65536 ids). Baking a host
# uid larger than that grant — routine on AD/LDAP-joined hosts, where uids run
# into the millions — breaks twice over: `usermod` cannot chown /home/vscode
# during the build (shadow exits 12, "Failed to change ownership of the home
# directory"), and bare keep-id could not map that uid at run time either. So
# keep `vscode` at 1000 there and map the host user onto 1000 with
# keep-id:uid=,gid= instead. The property dev depends on is unchanged —
# container uid 1000 IS the host user, so /workspace and the named volumes stay
# host-user-owned — and it needs no grant beyond the image's own id range.
#
# keep-id:uid=,gid= requires podman 4.3+ (Ubuntu 22.04 ships 3.4). Older podman
# falls back to the baked-host-uid form, with a warning when the grant is too
# small for it to work.
_podman_keepid_ids_supported() {
  local ver major minor
  # shellcheck disable=SC2086  # intentional word-splitting of RUNTIME_ARGS
  ver=$($RUNTIME $RUNTIME_ARGS info --format '{{.Version.Version}}' 2>/dev/null) || return 1
  IFS=. read -r major minor _ <<< "$ver"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
  [[ "$major" -gt 4 ]] && return 0
  [[ "$major" -eq 4 && "$minor" -ge 3 ]]
}

# How many subuids/subgids the bare-keep-id fallback needs. Rootless podman can
# only map ids inside the invoking user's /etc/subuid grant, and with the host
# uid baked into the image every id the image uses has to fit: the baked uid
# itself, plus the image's own ids up to `nobody` (65534) when the baked uid
# sits below them — so max(IMAGE_UID, 65536). Deliberately ONE number, used
# both to decide whether to warn and to size the remediation it prints, so the
# two cannot drift apart: a threshold looser than its own fix would stay quiet
# on grants that then fail the build.
_baked_uid_subid_requirement() {
  [[ "$IMAGE_UID" -gt 65536 ]] && { echo "$IMAGE_UID"; return 0; }
  echo 65536
}

_warn_baked_uid_needs_subids() {
  local granted required first last
  granted=$(subid_total /etc/subuid 2>/dev/null || echo 0)
  required=$(_baked_uid_subid_requirement)
  [[ "$granted" -ge "$required" ]] && return 0
  # --add-subuids FIRST-LAST is inclusive: LAST is FIRST + required - 1.
  first=10000000
  last=$((first + required - 1))
  echo "Note: podman is older than 4.3, so dev must bake your host uid" >&2
  echo "      ($IMAGE_UID) into the image, but /etc/subuid grants only" >&2
  echo "      $granted ids to $(id -un) — fewer than the $required needed to map" >&2
  echo "      every id the image uses. The build fails in usermod (exit 12)." >&2
  echo "      Either upgrade podman to 4.3+, or grant more ids:" >&2
  echo "        sudo usermod --add-subuids $first-$last \\" >&2
  echo "                     --add-subgids $first-$last $(id -un)" >&2
  echo "        podman system migrate" >&2
}

# Sets IMAGE_UID/IMAGE_GID (what the image is built for), EXPECT_KEEPID
# (whether this runtime creates containers with --userns=keep-id) and
# KEEPID_FLAG (the exact flag, empty when not applicable). Memoized; safe to
# call from any command path once HOST_UID/HOST_GID and RUNTIME_ARGS are final.
# shellcheck disable=SC2034  # IMAGE_UID/IMAGE_GID/EXPECT_KEEPID/KEEPID_FLAG are
# consumed by lib/dev/{image,lifecycle,inject,agent,dotfile}.sh
resolve_image_ids() {
  [[ -n "${IMAGE_UID:-}" ]] && return 0
  EXPECT_KEEPID=false
  KEEPID_FLAG=""
  IMAGE_UID="${HOST_UID:-$(id -u)}"
  IMAGE_GID="${HOST_GID:-$(id -g)}"
  if ! { engine_is_podman && runtime_is_rootless; }; then
    return 0
  fi
  EXPECT_KEEPID=true
  if _podman_keepid_ids_supported; then
    IMAGE_UID=1000
    IMAGE_GID=1000
    KEEPID_FLAG="--userns=keep-id:uid=1000,gid=1000"
    return 0
  fi
  KEEPID_FLAG="--userns=keep-id"
  _warn_baked_uid_needs_subids
}

# True when this runtime creates containers with --userns=keep-id. Call in the
# parent shell, never as $( ), so $KEEPID_FLAG is set for the caller.
keepid_active() {
  resolve_image_ids
  [[ "$EXPECT_KEEPID" == true ]]
}
