# shellcheck shell=bash
# lib/dev/scaffold.sh — `dev scaffold` (.devcontainer/ generation).
# Sourced by dev; not executed directly.

write_devcontainer_json_normal() {
  local out="$1"
  cat > "$out" <<'JSON'
{
  "name": "generic-devcontainer",
  "build": {
    "dockerfile": "Dockerfile",
    "context": ".",
    "target": "base"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace",
  "remoteUser": "vscode",
  "updateRemoteUserUID": true,
  "overrideCommand": false,
  "runArgs": ["--cap-add=NET_ADMIN"],
  "mounts": [
    "source=${devcontainerId}-mise,target=/mise,type=volume",
    "source=${devcontainerId}-home,target=/home/vscode,type=volume"
  ]
}
JSON
}

write_devcontainer_json_dind() {
  local out="$1"
  cat > "$out" <<'JSON'
{
  // dind mode requires kernel.apparmor_restrict_unprivileged_userns=0
  // on Ubuntu 23.10+ / Linux 6.x hosts. See README.md for the
  // host-side preflight (rootless dockerd needs CLONE_NEWUSER).
  "name": "generic-devcontainer-dind",
  "build": {
    "dockerfile": "Dockerfile",
    "context": ".",
    "target": "dind"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace",
  "remoteUser": "vscode",
  "updateRemoteUserUID": true,
  "overrideCommand": false,
  "containerEnv": {
    "DEVCONTAINER_DIND": "1"
  },
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--cap-add=SYS_ADMIN",
    "--device=/dev/fuse",
    "--device=/dev/net/tun",
    "--security-opt", "apparmor=unconfined",
    "--security-opt", "seccomp=unconfined",
    "--security-opt", "systempaths=unconfined",
    "--security-opt", "label=disable"
  ],
  "mounts": [
    "source=${devcontainerId}-mise,target=/mise,type=volume",
    "source=${devcontainerId}-home,target=/home/vscode,type=volume",
    "source=${devcontainerId}-dind,target=/home/vscode/.local/share/docker,type=volume"
  ]
}
JSON
}

write_devcontainer_json_pind() {
  local out="$1"
  cat > "$out" <<'JSON'
{
  // pind mode requires kernel.apparmor_restrict_unprivileged_userns=0
  // on Ubuntu 23.10+ / Linux 6.x hosts. See README.md for the
  // host-side preflight (rootless podman needs CLONE_NEWUSER).
  "name": "generic-devcontainer-pind",
  "build": {
    "dockerfile": "Dockerfile",
    "context": ".",
    "target": "pind"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace",
  "remoteUser": "vscode",
  "updateRemoteUserUID": true,
  "overrideCommand": false,
  "containerEnv": {
    "DEVCONTAINER_PIND": "1"
  },
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--cap-add=SYS_ADMIN",
    "--device=/dev/fuse",
    "--device=/dev/net/tun",
    "--security-opt", "apparmor=unconfined",
    "--security-opt", "seccomp=unconfined",
    "--security-opt", "systempaths=unconfined",
    "--security-opt", "label=disable"
  ],
  "mounts": [
    "source=${devcontainerId}-mise,target=/mise,type=volume",
    "source=${devcontainerId}-home,target=/home/vscode,type=volume",
    "source=${devcontainerId}-pind,target=/home/vscode/.local/share/containers,type=volume"
  ]
}
JSON
}

create_dev_container() {
  local target_dir=".devcontainer"
  local sources=(Dockerfile entrypoint.sh firewall-init.sh \
                 firewall-disable.sh mise.base.toml allowlist.base)
  if [[ "$DIND" == true ]]; then
    sources+=(dind-init.sh allowlist.dind)
  elif [[ "$PIND" == true ]]; then
    # pind reuses allowlist.dind (see Dockerfile's pind target) — there is
    # no separate allowlist.pind.
    sources+=(pind-init.sh allowlist.dind)
  fi
  # devcontainer.json is generated, not copied — but it counts toward
  # the destination set for collision checking.
  local destinations=("${target_dir}/devcontainer.json")
  for f in "${sources[@]}"; do
    destinations+=("${target_dir}/${f}")
  done

  # Collision check.
  local existing=()
  for d in "${destinations[@]}"; do
    [[ -e "$d" ]] && existing+=("$d")
  done
  if [[ ${#existing[@]} -gt 0 && "$FORCE" != true ]]; then
    echo "Refusing to overwrite:" >&2
    for d in "${existing[@]}"; do
      echo "  $d" >&2
    done
    echo "Pass --force to overwrite." >&2
    exit 1
  fi

  mkdir -p "$target_dir"

  # Copy source files from $SCRIPT_DIR.
  for f in "${sources[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
      echo "Error: missing source file ${SCRIPT_DIR}/${f}" >&2
      exit 1
    fi
    cp "${SCRIPT_DIR}/${f}" "${target_dir}/${f}"
  done

  if [[ "$DIND" == true ]]; then
    write_devcontainer_json_dind "${target_dir}/devcontainer.json"
  elif [[ "$PIND" == true ]]; then
    write_devcontainer_json_pind "${target_dir}/devcontainer.json"
  else
    write_devcontainer_json_normal "${target_dir}/devcontainer.json"
  fi

  local mode_label="normal"
  [[ "$DIND" == true ]] && mode_label="dind"
  [[ "$PIND" == true ]] && mode_label="pind"
  echo "Wrote ${target_dir}/ (${mode_label} mode)."
  echo
  echo "Next steps:"
  echo "  1. Open this directory in VS Code:   code ."
  echo "  2. When prompted, choose 'Reopen in Container'."
  echo "  3. (Optional) Add a workspace-root .devcontainer-allowlist"
  echo "     for project-specific firewall hostnames; firewall-init.sh"
  echo "     merges it at container startup."
}
