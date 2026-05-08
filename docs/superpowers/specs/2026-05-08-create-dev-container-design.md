# `dev --create-dev-container`

Date: 2026-05-08
Status: draft

## Problem

Today the project's only entry point is `./dev`. A user who wants to
open the same workspace in VS Code and use "Reopen in Container" gets
nothing: there is no `.devcontainer/devcontainer.json`, the Dockerfile
references files that live outside `.devcontainer/`, and the runtime
flags `dev` injects (named volumes, `--cap-add=NET_ADMIN`, `dind`
security-opts, etc.) are not encoded anywhere VS Code can read.

We want a one-shot generator that materialises a working,
editor-agnostic devcontainer in *another* project's CWD, faithful
enough to the `./dev` experience that the firewall and mise stack
keep working under VS Code's "Reopen in Container" flow.

## Goal

`dev --create-dev-container` (optionally with `--dind`) writes a
self-contained `.devcontainer/` directory in the CWD that VS Code's
dev-containers extension can build and attach to with no further
manual steps, producing a container with the same security boundary
and tool stack that `./dev` produces today.

## Non-goals

- Replacing the `./dev` wrapper. The generated devcontainer is for
  consumers that prefer VS Code's container UX; `./dev` remains the
  primary entry point inside this repo.
- Sharing volume state with `./dev` runs of the same workspace. The
  generated devcontainer uses `${devcontainerId}`-scoped volumes; a
  parallel `./dev` invocation against the same checkout would use the
  shared `devcontainer-mise`/`devcontainer-home` volumes, and the two
  states are intentionally independent.
- Devcontainer Features (`features` block), VS Code-specific settings,
  recommended extensions. The output is editor-agnostic.
- Copying any project-specific `.devcontainer-allowlist` content.
  `firewall-init.sh` already merges `.devcontainer-allowlist` from the
  workspace root at runtime if it exists; generated projects keep
  using that mechanism.
- Preflighting host-kernel state (AppArmor sysctl, fuse availability,
  etc.) for `--dind`. VS Code can't run host-side checks from
  devcontainer.json. The generated file points at the README section
  in a comment instead.
- Running the generated container. The command is pure file
  manipulation in the host shell; it does not touch docker/podman.

## Architecture

The generator is a new top-level branch in the `dev` script that runs
to completion before `detect_runtime` is reached. Three components:

1. **Argument parsing.** `--create-dev-container` and `--force` join
   the existing flag loop. The new flag is mutually exclusive with
   every other action flag (`--build`, `--monitor`, `--monitor-fw`,
   `--disable-firewall`, `--enable-firewall`, `--maintenance`,
   `--dry-run`); only `--dind` and `--force` compose with it.
2. **File set selection.** Based on `$DIND`, the generator computes
   the source/destination file pairs:
   - Always: `Dockerfile`, `entrypoint.sh`, `firewall-init.sh`,
     `mise.base.toml`, `allowlist.base`.
   - `--dind` only: `dind-init.sh`, `allowlist.dind`.
   - Plus the generated `devcontainer.json`, mode-specific.
3. **Write phase.** Per-file collision check first; if any
   destination exists and `--force` is unset, list them all and exit
   non-zero. Otherwise `mkdir -p .devcontainer`, copy each source
   from `$SCRIPT_DIR` (already used by `--build`), and emit
   `devcontainer.json` via heredoc.

Source paths are resolved relative to `$SCRIPT_DIR` so the generator
works the same when invoked through the `dev install` symlink.

## devcontainer.json — normal mode

```jsonc
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
  "overrideCommand": true,
  "runArgs": ["--cap-add=NET_ADMIN"],
  "mounts": [
    "source=${devcontainerId}-mise,target=/mise,type=volume",
    "source=${devcontainerId}-home,target=/home/vscode,type=volume"
  ]
}
```

Key choices:

- **`build.context: "."`** points at `.devcontainer/`, so the Dockerfile's
  `COPY` directives (`mise.base.toml`, `allowlist.base`,
  `firewall-init.sh`, `entrypoint.sh`) resolve against the files we
  just dropped next to it. The source repo is no longer required.
- **`build.target: "base"`** is explicit even though the Dockerfile's
  base stage is the default — the generator emits the same field for
  `dind` mode (`"target": "dind"`), and matching shape across the two
  modes makes the diff easier to read.
- **`updateRemoteUserUID: true`** replaces the host-UID build-arg
  machinery `./dev` uses. Inside firewall-init.sh, the iptables rules
  key on the `proxy` user UID, not on vscode; renumbering vscode at
  start does not break the policy.
- **`overrideCommand: true`** (the default; emitted explicitly for
  clarity) lets VS Code substitute its sleep-loop CMD. Our
  `entrypoint.sh` still runs first, performs firewall init / mise
  install / git safe.directory, then `exec gosu vscode <sleep-loop>`.
  The container stays alive; VS Code attaches via `exec --user vscode`
  exactly the way `./dev` does on its second terminal.
- **`${devcontainerId}`-scoped named volumes** for `/mise` and
  `/home/vscode`. Per-project isolation matches VS Code conventions
  and avoids cross-project state bleed; we accept the trade-off of
  not sharing with `./dev`'s shared volumes.
- **`--cap-add=NET_ADMIN`** is required by `firewall-init.sh` to load
  iptables/ipset rules. Without it, the entrypoint aborts with
  "FATAL: firewall-init.sh failed".

## devcontainer.json — dind mode

Identical to normal mode except:

```jsonc
{
  "build": { "...": "...", "target": "dind" },
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
  "containerEnv": { "DEVCONTAINER_DIND": "1" },
  "mounts": [
    "source=${devcontainerId}-mise,target=/mise,type=volume",
    "source=${devcontainerId}-home,target=/home/vscode,type=volume",
    "source=${devcontainerId}-dind,target=/home/vscode/.local/share/docker,type=volume"
  ]
}
```

A leading JSON comment in the generated file points at
`README.md` for the AppArmor sysctl prerequisite on Ubuntu 23.10+ /
Linux 6.x hosts (`kernel.apparmor_restrict_unprivileged_userns=0`).
VS Code surfaces a generic build/start error if the user has not set
this; the comment tells them where to look.

## Output layout

```
<CWD>/.devcontainer/
├── devcontainer.json          # generated, mode-specific
├── Dockerfile                 # copied verbatim from $SCRIPT_DIR
├── entrypoint.sh              # copied
├── firewall-init.sh           # copied
├── mise.base.toml             # copied
├── allowlist.base             # copied
└── (--dind only)
    ├── dind-init.sh
    └── allowlist.dind
```

The Dockerfile is copied unchanged: every `COPY` directive inside it
already names the file by basename (`COPY mise.base.toml …`,
`COPY allowlist.base …`), and with `build.context: "."` those
basenames now resolve inside `.devcontainer/`.

## Collision behaviour

Before any write, the generator builds the target file list and stats
each destination. If one or more already exist and `--force` is not
set, the script prints all conflicting paths and exits 1:

```
Refusing to overwrite:
  .devcontainer/devcontainer.json
  .devcontainer/Dockerfile
Pass --force to overwrite.
```

With `--force`, the generator overwrites every file in the target
list. It does **not** delete unrelated files in `.devcontainer/`
(e.g. an existing `.devcontainer/devcontainer.json.bak` is left
alone), and it does not remove `.devcontainer/` itself.

## CLI surface

```
dev --create-dev-container          # normal-mode .devcontainer/
dev --create-dev-container --dind   # dind-mode .devcontainer/
dev --create-dev-container --force  # overwrite existing files
```

Mutual-exclusion guard: `--create-dev-container` composes **only** with
`--dind` and `--force`. Every other flag (`--build`, `--port`,
`--default-ports`, `--maintenance`, `--monitor`, `--monitor-fw`,
`--disable-firewall`, `--enable-firewall`, `--dry-run`, and any
trailing `--` command) is rejected with a clear error. Reject rather
than silently ignore: a silently-accepted flag becomes a future
support question when a user expects it to do something.

Post-write stdout summary includes a copyable `code .` invitation and
a one-liner pointing at `.devcontainer-allowlist` for project-specific
firewall entries.

## Testing

A single new scenario script under
`scripts/test/scenarios/NN-create-dev-container.sh` covering:

1. Run `dev --create-dev-container` in an empty tmp dir; assert the
   expected files are present, `devcontainer.json` parses as JSON
   (`python3 -m json.tool` or similar that's already on the test
   host).
2. Re-run without `--force`; assert non-zero exit and that no files
   change (mtime check or content hash).
3. Re-run with `--force`; assert success and that files are
   refreshed.
4. Run `dev --create-dev-container --dind`; assert the dind-only
   files are present and `devcontainer.json` contains the dind
   `runArgs` and `target`.

End-to-end "actually build the generated devcontainer with the
devcontainer CLI" is intentionally out of scope for the orchestrator.

## Open questions

None.
