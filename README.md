# Generic Devcontainer

## Overview

This is a portable, editor-agnostic development environment designed to provide
a consistent experience across different projects and machines. It avoids the
complexity and editor-lock-in of standard devcontainers by using a simple
Dockerfile and a `dev` wrapper script. It features `mise` for seamless tool
management, allowing each project to define its own toolchain (Go, Node,
Python, etc.) while sharing a persistent base layer.

## Quick Start

Get up and running in 3 steps:

1. **Build the image**:

    ```bash
    docker build -t generic-devcontainer .
    ```

2. **Start the environment**:
    Run the `dev` script from your project root:

    ```bash
    ./dev
    ```

3. **Work**:
    You are now inside a Zsh shell with all your project tools automatically installed by `mise`.

## Architecture

The system consists of three main components:

- **Dockerfile**: Defines the base image (Ubuntu-based) with essential tools
like Git and `mise`. It bakes in common utilities like `ripgrep`, `eza`, and
`lazygit`.
- **entrypoint.sh**: Runs when the container starts. It checks for a
`mise.toml` in your project, installs any missing tools, and configures Git to
trust the `/workspace` directory.
- **dev script**: A bash wrapper that automates the `docker run` command. It
handles volume mounting and port forwarding.

## Per-Project Setup

To use this with your project, add a `mise.toml` (or `.mise.toml`) to your
project root. The container will automatically install the specified tools on
startup.

### Examples

**Go Setup**:

```toml
[tools]
go = "1.24"

[env]
GOPATH = "/workspace/.go"
```

**Node/Vite Setup**:

```toml
[tools]
node = "22"
pnpm = "latest"
```

**Python Setup**:

```toml
[tools]
python = "3.12"
poetry = "latest"
```

**Rust Setup**:

```toml
[tools]
rust = "latest"
```

## The `dev` Script

The `dev` script manages the container lifecycle.

**Flags**:

- `--help`: Show the help message and usage examples.
- `--dry-run`: Print the `docker run` command that would be executed without actually running it.
- `--build`: Force a rebuild of the `generic-devcontainer` image before starting.
- `--port PORT`: Add additional port forwarding (e.g., `--port 9000`). This flag can be repeated.
- `--no-ports`: Skip all default port forwarding.
- `--`: Pass any remaining arguments as a command to be executed inside the container (e.g., `./dev -- npm run dev`).

## Port Forwarding

By default, the following ports are forwarded from the container to your host:

- `5173`, `5174`: Standard Vite/Frontend ports.
- `8080`: Common web server port.
- `2345`: Default port for Delve (Go debugger).
- `3000`: Common Node.js/Rails/React port.

Use the `--port` flag to add more as needed.

## macOS Users

To ensure correct file permissions on macOS, you should build the image with
your local user's UID. By default, the image uses UID 1000. If your macOS UID
is 501 (the default), build with:

```bash
docker build -t generic-devcontainer --build-arg USER_UID=501 .
```

**Note**: If you change `USER_UID` after the `devcontainer-home` volume already
exists, you must remove it to avoid file permission mismatches: `docker volume
rm devcontainer-home`

## Volume Caching

Two named Docker volumes are used to persist data across container restarts and different projects:

- `devcontainer-mise:/mise` — persists all `mise` data (installed tools, caches)
- `devcontainer-home:/home/vscode` — persists user home directory (configs, history, dotfiles)

To clear the cache and reinstall tools from scratch:

```bash
docker volume rm devcontainer-mise
```

To reset all user settings and start fresh:

```bash
docker volume rm devcontainer-home
```

To reset both:

```bash
docker volume rm devcontainer-mise devcontainer-home
```

## Home Directory Persistence

The `devcontainer-home` named volume backs the entire `/home/vscode` directory.
This ensures your shell environment and personal configurations are preserved
even when the container is removed or the image is rebuilt.

User settings that persist:

- Zsh history and shell customizations (`.zshrc` aliases, functions)
- Git configuration (`.gitconfig`)
- Editor configurations (Nvim, etc.)
- SSH keys and known hosts

On first run, the volume is auto-populated from the image, including the
oh-my-zsh setup and mise activation. After image rebuilds, if the mise
activation line is ever missing from your `.zshrc`, the entrypoint re-adds it
automatically.

Reset (wipe all user settings and start fresh): `docker volume rm devcontainer-home`

## Troubleshooting

- **Mise Install Failures**: If tools fail to install on startup, check your
internet connection or `mise.toml` syntax. The container will still start, but
tools may be missing.
- **UID Mismatch**: If you experience permission issues with files in
`/workspace`, ensure you built the image with the correct `USER_UID` matching
your host user.
