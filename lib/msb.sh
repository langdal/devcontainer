# shellcheck shell=bash
# === microsandbox boundary ===
# The ONLY file that knows `msb` syntax. If microsandbox changes, fix it here.
# Syntax confirmed in docs/superpowers/SPIKE-microsandbox.md (Task 0).
# Arg-builder functions emit one token per line; callers use `mapfile -t`.

# msb_net_args MODE [HOST...] -> egress flags.
#   full       = open egress (provision)
#   none       = deny all (airgapped)
#   sanctioned = deny by default, allow each HOST on tcp:443 (no DNS rule needed)
msb_net_args() {
  local mode="$1"; shift || true
  case "$mode" in
    full)
      printf '%s\n' --net-default-egress allow
      ;;
    none)
      printf '%s\n' --net-default-egress deny
      ;;
    sanctioned)
      printf '%s\n' --net-default-egress deny
      if [[ $# -gt 0 ]]; then
        local rules="" h
        for h in "$@"; do
          [[ -n "$rules" ]] && rules="${rules},"
          rules="${rules}allow@${h}:tcp:443"
        done
        printf '%s\n' --net-rule "$rules"
      fi
      ;;
    *)
      echo "msb_net_args: unknown mode '$mode'" >&2
      return 1
      ;;
  esac
}

# msb_mount_args WORKSPACE [VOLUME:GUEST...] -> mount flags.
msb_mount_args() {
  local workspace="$1"; shift || true
  printf '%s\n' --mount-dir "${workspace}:/workspace"
  local v
  for v in "$@"; do
    printf '%s\n' --mount-named "$v"
  done
}

# msb_secret_args [ENV@HOST...] -> secret flags (empty if none).
msb_secret_args() {
  local s
  for s in "$@"; do
    printf '%s\n' --secret "$s"
  done
}

# Resolve the msb binary once (it is often not on the default non-login PATH).
MSB_BIN="${MSB_BIN:-$(command -v msb 2>/dev/null || echo "$HOME/.local/bin/msb")}"

# msb_available -> 0 if the resolved msb binary is runnable.
msb_available() { [[ -x "$MSB_BIN" ]]; }

# _msb ARGS...  -> run `msb` unless BOX_DRY_RUN is set, then just print.
# This is the test seam: all execution goes through here.
_msb() {
  if [[ -n "${BOX_DRY_RUN:-}" ]]; then
    printf 'msb %s\n' "$*"
  else
    "$MSB_BIN" "$@"
  fi
}

# msb_is_running NAME -> 0 if a named sandbox is currently running.
# Dry-run short-circuits to "not running".
msb_is_running() {
  [[ -n "${BOX_DRY_RUN:-}" ]] && return 1
  "$MSB_BIN" ps -q 2>/dev/null | grep -Fxq "$1"
}

# msb_up NAME IMAGE WORKSPACE MODE [HOST...]
# Boots a detached, persistent named sandbox with volumes, workspace, egress.
# Detached run ignores a trailing command, so callers exec separately (msb_attach).
msb_up() {
  local name="$1" image="$2" workspace="$3" mode="$4"; shift 4
  local hosts=("$@")
  # --replace: callers only reach here when the sandbox is NOT running, but a
  # *stopped* sandbox of the same name still exists (e.g. after `box down`).
  # Without --replace, `msb run -d --name X` restarts that stale sandbox with
  # its ORIGINAL flags and silently ignores the new mounts/net rules/secrets.
  # --replace forces a fresh boot so allowlist/secret changes take effect.
  local args=(run -d --replace --name "$name")
  mapfile -t mounts < <(msb_mount_args "$workspace" box-mise:/mise box-home:/home/vscode)
  mapfile -t net < <(msb_net_args "$mode" "${hosts[@]}")
  local secrets=()
  if [[ -n "${BOX_SECRETS:-}" ]]; then
    mapfile -t _secret_tokens <<< "$BOX_SECRETS"
    mapfile -t secrets < <(msb_secret_args "${_secret_tokens[@]}")
  fi
  args+=("${mounts[@]}" "${net[@]}" "${secrets[@]}" "$image")
  _msb "${args[@]}"
}

# mise environment injected into every exec'd command (and the provision step).
# Why --env rather than relying on shell rc files:
#   * `msb exec` runs as ROOT, whose HOME is /root in the EPHEMERAL guest rootfs
#     (not the persistent box-home volume), so rc seeding there would not stick.
#   * Running as the `vscode` user instead would source a seeded rc, but the
#     /workspace bind mount is owned by guest-root (host-user maps to guest-root),
#     so a uid-1000 process cannot WRITE the workspace. Root can, and its writes
#     map back to the host user — the correct two-way mount behaviour.
# Therefore: exec as root (writable workspace) and inject the mise env directly.
# /mise (box-mise volume) holds the real mise binary + shims, so PATH alone makes
# `mise` and every mise-managed tool resolve in a non-interactive `bash -lc`.
_MSB_GUEST_PATH=/mise/shims:/mise/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
msb_mise_env_args() {
  printf '%s\n' \
    --env "PATH=$_MSB_GUEST_PATH" \
    --env "MISE_DATA_DIR=/mise" \
    --env "MISE_CONFIG_DIR=/mise" \
    --env "MISE_CACHE_DIR=/mise/cache"
}

# msb_stop NAME / msb_remove NAME -> sandbox lifecycle teardown.
msb_stop()   { _msb stop "$1"; }
msb_remove() { _msb rm "$1"; }

# msb_attach NAME -- CMD...  -> run CMD in an already-running named sandbox.
# Injects the mise env (above) so mise + project tools are on PATH.
msb_attach() {
  local name="$1"; shift
  if [[ "${1:-}" == "--" ]]; then shift; fi
  mapfile -t env < <(msb_mise_env_args)
  # --workdir /workspace: land the shell/command in the mounted workspace,
  # not the image default (/ or /root).
  _msb exec --workdir /workspace "${env[@]}" "$name" -- "$@"
}

# msb_provision IMAGE WORKSPACE
# Ephemeral, open-egress sandbox that populates the box-mise/box-home volumes:
# installs mise into /mise, then `mise install` (base + project mise.toml).
# Foreground run (no -d) so the trailing provisioning command is honored.
msb_provision() {
  local image="$1" workspace="$2"
  mapfile -t mounts < <(msb_mount_args "$workspace" box-mise:/mise box-home:/home/vscode)
  mapfile -t net < <(msb_net_args full)
  # Guest-side provisioning script (runs as root, open egress). mise
  # data/config/cache all live on the persistent /mise (box-mise) volume.
  # Install mise into /mise/bin if absent, then install the project tools.
  # Run-time PATH/activation is handled by msb_attach injecting --env (the
  # /mise volume persists, so the installed binaries are all that is needed);
  # no shell-rc seeding is required here.
  local script='set -e
export MISE_DATA_DIR=/mise MISE_CONFIG_DIR=/mise MISE_CACHE_DIR=/mise/cache
export PATH=/mise/bin:$PATH
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | MISE_INSTALL_PATH=/mise/bin/mise sh
fi
mise trust --yes /workspace 2>/dev/null || true
mise install -C /workspace || mise install
'
  _msb run "${mounts[@]}" "${net[@]}" "$image" -- bash -lc "$script"
}

# msb_provision_shell IMAGE WORKSPACE [CMD...]
# Ephemeral, OPEN-egress, foreground sandbox for manual provisioning. With no
# CMD it opens an interactive root shell in /workspace; with CMD it runs a
# one-off. The /mise and /home volumes and the /workspace bind mount persist;
# system-root (/usr, /etc, ...) changes are discarded when the VM exits.
msb_provision_shell() {
  local image="$1" workspace="$2"; shift 2
  local cmd=("$@")
  if [[ ${#cmd[@]} -eq 0 ]]; then cmd=(/usr/bin/bash); fi
  mapfile -t mounts < <(msb_mount_args "$workspace" box-mise:/mise box-home:/home/vscode)
  mapfile -t net < <(msb_net_args full)
  mapfile -t env < <(msb_mise_env_args)
  _msb run "${mounts[@]}" "${net[@]}" "${env[@]}" --workdir /workspace "$image" -- "${cmd[@]}"
}

# msb_load_built BUILDER TAG -> import a locally-built image into microsandbox.
# microsandbox can't read the host Docker store directly, so we stream
# `<builder> save TAG` into `msb image load` (which reads a tar from stdin).
msb_load_built() {
  local builder="$1" tag="$2"
  if [[ -n "${BOX_DRY_RUN:-}" ]]; then
    printf 'host %s save %s | msb image load --tag %s\n' "$builder" "$tag" "$tag"
    return 0
  fi
  "$builder" save "$tag" | "$MSB_BIN" image load --tag "$tag"
}
