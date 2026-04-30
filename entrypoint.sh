#!/bin/bash
set -u

# entrypoint.sh runs as root. It runs user-context tasks via gosu vscode,
# then exec's gosu vscode for the actual command. The firewall hook (Task 4)
# slots in at the top of this file.

# Run user-context startup tasks as vscode (preserves file ownership under
# /home/vscode and /mise; ensures 'git config --global' lands in
# /home/vscode/.gitconfig).
gosu vscode bash <<'INNER'
set -u

# Ensure mise shell activation is present in .zshrc (idempotent).
if [[ -f /home/vscode/.zshrc ]] && ! grep -q 'mise activate zsh' /home/vscode/.zshrc; then
    # shellcheck disable=SC2016
    echo 'eval "$(mise activate zsh)"' >> /home/vscode/.zshrc
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
