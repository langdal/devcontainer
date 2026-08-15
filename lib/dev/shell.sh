# shellcheck shell=bash
# lib/dev/shell.sh — the `dev shell` verb: attach a second shell to whichever
# container is already running for this workspace. Sourced by dev; not
# executed directly.

# cmd_shell: attach a shell to whichever container is already running for this
# workspace, in whatever mode it is running.
#
# This deliberately does NOT go through cmd_start (lib/dev/up.sh). Routing an
# attach-only verb through the start flow had three consequences, all wrong:
# the four-way mode guard refused to attach to a running dind/pind/maint
# container (cmd_shell left the mode flags false, so only the default arm was
# ever selected and a running dind container read as a conflict); a fresh host
# would run the allowlist approval prompt and a full image build before failing
# with "nothing running"; and the keep-id mismatch branch could `rm -f` a
# container other terminals were using. Resolving the running container
# directly avoids all three.
cmd_shell() {
  if [[ $# -gt 0 ]]; then
    echo "Error: 'dev shell' takes no arguments." >&2
    exit 2
  fi
  detect_runtime
  ensure_runtime_ready
  _resolve_workspace_names
  resolve_managed_container
  if [[ -z "$MANAGED_TARGET" ]]; then
    echo "Error: nothing running for this workspace — 'dev up' starts one." >&2
    exit 1
  fi
  CONTAINER_NAME="$MANAGED_NAME"
  RUNTIME_ARGS="$MANAGED_RUNTIME_ARGS"
  # shellcheck disable=SC2034  # consumed by attach_existing_container
  SHELL_ONLY=true
  # shellcheck disable=SC2034  # consumed by attach_existing_container
  DRY_RUN=false
  CMD_ARGS=()
  # shellcheck disable=SC2034  # consumed by attach_existing_container
  TTY_FLAGS=(-i)
  if [[ -t 0 && -t 1 ]]; then
    # shellcheck disable=SC2034  # consumed by attach_existing_container
    TTY_FLAGS=(-it)
  fi
  # The container already exists, so the keep-id mapping is whatever it was
  # created with; attach_existing_container only compares this to the label to
  # decide whether reuse is safe, and under SHELL_ONLY it errors rather than
  # recreating. Ask the runtime instead of assuming.
  # shellcheck disable=SC2034  # consumed by attach_existing_container
  EXPECT_KEEPID=false
  if engine_is_podman && runtime_is_rootless; then
    # shellcheck disable=SC2034  # consumed by attach_existing_container
    EXPECT_KEEPID=true
  fi
  attach_existing_container
  # attach_existing_container execs when it attaches, so reaching here means
  # the container vanished between the running check and the attach.
  echo "Error: $CONTAINER_NAME is no longer running." >&2
  exit 1
}
