#!/bin/bash
set -u

# Ensure mise shell activation is present in .zshrc (idempotent — safe to run every start)
if [[ -f /home/vscode/.zshrc ]] && ! grep -q 'mise activate zsh' /home/vscode/.zshrc; then
	# shellcheck disable=SC2016
	echo 'eval "$(mise activate zsh)"' >>/home/vscode/.zshrc
fi

# Try to install mise-managed tools if mise.toml exists
if [[ -f /workspace/mise.toml ]] || [[ -f /workspace/.mise.toml ]]; then
	if ! mise install; then
		echo "WARNING: mise install failed, but continuing with container startup" >&2
	fi
fi

# Configure git to trust /workspace as a safe directory
git config --global safe.directory /workspace

# Execute the provided command (defaults to CMD from Dockerfile)
exec "$@"
