#!/bin/bash
set -u

# --- Firewall (skipped in maintenance mode) ---
if [ -z "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    if ! /usr/local/sbin/firewall-init.sh; then
        echo "FATAL: firewall-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    export HTTPS_PROXY=http://127.0.0.1:8888
    export HTTP_PROXY=http://127.0.0.1:8888
    export NO_PROXY=localhost,127.0.0.1
    cat > /etc/profile.d/proxy.sh <<'EOF'
export HTTPS_PROXY=http://127.0.0.1:8888
export HTTP_PROXY=http://127.0.0.1:8888
export NO_PROXY=localhost,127.0.0.1
EOF
    chmod 644 /etc/profile.d/proxy.sh
fi

# --- Maintenance mode: re-grant sudo for vscode and warn loudly ---
if [ -n "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    cat > /etc/sudoers.d/vscode-maint <<'EOF'
vscode ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 /etc/sudoers.d/vscode-maint
    cat > /etc/profile.d/zz-maint-banner.sh <<'EOF'
echo
echo "=========================================================="
echo "  MAINTENANCE MODE - firewall disabled, sudo enabled."
echo "  Do not run untrusted code in this container."
echo "=========================================================="
echo
EOF
    chmod 644 /etc/profile.d/zz-maint-banner.sh
fi

# --- DinD mode: launch rootless dockerd ---
if [ -n "${DEVCONTAINER_DIND:-}" ]; then
    if ! /usr/local/sbin/dind-init.sh; then
        echo "FATAL: dind-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    # Export to entrypoint's env so non-login children (gosu vscode CMD)
    # see DOCKER_HOST / XDG_RUNTIME_DIR. dind-init.sh also writes these to
    # /etc/profile.d/dind.sh for interactive shells, but profile.d is only
    # sourced by login shells.
    export DOCKER_HOST=unix:///home/vscode/.dind-run/docker.sock
    export XDG_RUNTIME_DIR=/home/vscode/.dind-run
fi

# Run user-context startup tasks as vscode (preserves file ownership under
# /home/vscode and /mise; ensures 'git config --global' lands in
# /home/vscode/.gitconfig).
gosu vscode bash <<'INNER'
set -u

# Seed .zshrc from the Dockerfile's staged copy if the home volume came up
# empty (the volume mount shadows the .zshrc baked into the image).
if [[ ! -f /home/vscode/.zshrc ]] && [[ -f /etc/skel.devcontainer/.zshrc ]]; then
    cp /etc/skel.devcontainer/.zshrc /home/vscode/.zshrc
fi

# Try to install mise-managed tools if a project mise.toml exists.
if [[ -f /workspace/mise.toml ]] || [[ -f /workspace/.mise.toml ]]; then
    if ! mise install; then
        echo "WARNING: mise install failed, but continuing with container startup" >&2
    fi
fi

# Configure git to trust /workspace as a safe directory.
git config --global --add safe.directory /workspace
INNER

# Drop privileges to vscode for the actual command.
exec gosu vscode "$@"
