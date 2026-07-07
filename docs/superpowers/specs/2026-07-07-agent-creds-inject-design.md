# `dev agent` — inject agent credentials & settings

- **Date:** 2026-07-07
- **Status:** Approved — manifests confirmed against real installs
- **Branch:** `feat/agent-creds-inject` (off `feat/podman-in-podman`)

## Summary

Add a `dev agent` subcommand group that **copies** a curated, per-agent
allowlist of credentials and settings from the host into this workspace's
per-workspace home volume. Supported agents: `claude`, `opencode`, `pi`.

The copy is a **one-way, one-time snapshot** — not a host mount. Files land
in the home volume and stay there until refreshed (re-run `add`) or removed
(`rm` / `dev reset`). Nothing is mirrored back to the host, and the host
files are never bind-mounted into the container.

## Goal

Let a user authenticate and configure an AI coding agent inside the sandbox
without re-running each tool's interactive login and without hand-copying
config every time. Today `dev` deliberately exposes *no* agent credentials
(SSH keys, git creds, and shell history are also withheld), so every fresh
home volume starts logged-out.

## Non-goals

- **No live mount of host config.** The threat model is "copy in", so the
  running agent works against a snapshot; it cannot read or write the host's
  live credential files.
- **No image-level baking.** Credentials must never enter an image layer:
  the base/`:dind`/`:pind` images are shared across every workspace and their
  layers are cacheable/pullable. Secrets live only in the per-workspace home
  *volume*.
- **No two-way sync.** Changes made inside the container are not propagated
  back to the host.
- **No cross-project history.** The per-workspace home volume exists so one
  project's agent can't read another project's data; the manifests
  deliberately exclude every tool's conversation/project/session history.

## Background — existing patterns this builds on

- **Per-workspace home volume** (`devcontainer-home-<dir>`): isolates each
  workspace's home so agents can't read another project's SSH keys, git
  creds, or history. See `_resolve_home_volume` in `lib/dev/lifecycle.sh`.
- **Git identity seeding**: `dev` reads the host's `git config user.name` /
  `user.email` and passes them as `DEV_GIT_NAME` / `DEV_GIT_EMAIL`;
  `entrypoint.sh` seeds them only if the container has none yet. This is the
  precedent for "host-side read, seed into the volume". The new feature
  differs in being explicit (a command) rather than automatic-on-first-run.
- **keep-id volume ownership**: under rootless podman, volume writes must go
  through the `--userns=keep-id` mapping so files end up owned by the host
  user (see `migrate_volume_for_keepid` and the keep-id block in
  `start_container`). The copy mechanism reuses this mapping (see below).
- **`lib/dev/*.sh` module layout**: `fw.sh`, `image.sh`, `lifecycle.sh`,
  `preflight.sh`, `scaffold.sh`, `update.sh`. New code lands in
  `lib/dev/agent.sh`.
- **`fw <subcommand>` router pattern**: the `agent` group mirrors it.

## Command surface

```
dev agent add  <name>...     # copy curated creds+settings for each named agent
dev agent add  all           # every agent detected on the host
dev agent list               # table: detected-on-host? / injected-here?
dev agent rm   <name>...      # delete injected files for each named agent (confirms)
dev agent                    # no args → prints usage
```

- **Names:** `claude`, `opencode`, `pi`. Unknown names error with the valid
  list.
- **`add` is idempotent** and is itself the refresh path: credentials expire,
  so re-running `dev agent add claude` re-snapshots the current host files
  (overwriting the in-volume copy for the manifest paths).
- **`--dry-run`** prints the resolved file list per agent instead of copying.
- **`DEV_ASSUME_YES=1`** skips the `rm` confirmation prompt (consistent with
  its use elsewhere).
- **Deprecated aliases:** none — this is a new surface.

`add` works whether or not a container is currently running, and creates the
home volume if it does not yet exist (so you can pre-seed before the first
`dev` start).

## Manifests

Per-agent source→dest tables live in `lib/dev/agent.sh`. Rules:

- Sources are resolved under the host `$HOME`; **only sources that exist are
  copied**, missing ones are skipped silently (an agent you don't use
  contributes nothing).
- Dest paths are relative to `/home/vscode` in the home volume.
- A file source copies the file; a directory source copies the tree.
- Every manifest **excludes** conversation/project/session history and
  large mutable caches — that is the isolation guarantee.

### claude (confirmed against this host's `~/.claude`)

| Source (under `~/`) | Dest (under home volume) | Kind |
|---|---|---|
| `.claude/.credentials.json` | `.claude/.credentials.json` | file (auth) |
| `.claude/settings.json` | `.claude/settings.json` | file |
| `.claude/CLAUDE.md` | `.claude/CLAUDE.md` | file (optional) |
| `.claude/commands/` | `.claude/commands/` | dir |
| `.claude/agents/` | `.claude/agents/` | dir |
| `.claude/skills/` | `.claude/skills/` | dir |

**Excluded (by design):** `.claude.json` (holds global MCP config *and*
per-project history/pastes), `projects/`, `sessions/`, `history.jsonl`,
`file-history/`, `plugins/`, `cache/`, `daemon*`, `shell-snapshots/`,
`uploads/`, `paste-cache/`, `tasks/`, `jobs/`.

> Consequence: globally-configured MCP servers do **not** carry over, because
> they live in the excluded `.claude.json`. Accepted trade-off for this
> iteration; a future `--with-mcp` flag could `jq`-extract just the
> `mcpServers` key into a minimal `.claude.json`.

### opencode (confirmed against this host's install)

| Source (under `~/`) | Dest | Kind |
|---|---|---|
| `.local/share/opencode/auth.json` | `.local/share/opencode/auth.json` | file (auth, mode 0600) |
| `.local/share/opencode/mcp-auth.json` | `.local/share/opencode/mcp-auth.json` | file (auth, mode 0600, optional) |
| `.config/opencode/opencode.json` | `.config/opencode/opencode.json` | file (**contains plaintext provider `apiKey`s** → mode 0600) |
| `.config/opencode/tui.json` | `.config/opencode/tui.json` | file (optional) |
| `.config/opencode/agents/` | `.config/opencode/agents/` | dir (optional) |
| `.config/opencode/commands/` | `.config/opencode/commands/` | dir (optional) |
| `.config/opencode/skills/` | `.config/opencode/skills/` | dir (optional) |

Confirmed on a real install (2026-07-07): `auth.json` does live at
`~/.local/share/opencode/auth.json`, mode 0600, holding provider
credentials (e.g. a github-copilot OAuth refresh/access token pair).
A sibling `mcp-auth.json` (0600, MCP-server OAuth tokens) sits next to it
and is included as optional auth. The plural `agents/`/`commands/`/`skills/`
subdirs did **not** exist on the inspected host — keep them in the manifest
(sources that don't exist are skipped), but they are unverified upstream.

**Excluded (confirmed to exist and deliberately skipped):**

- `~/.local/share/opencode/`: `opencode.db*` (hundreds of MB of session
  storage), `storage/`, `snapshot/`, `log/`, `repos/`, `tool-output/`,
  `bin/` — all session/project state or caches.
- `~/.config/opencode/`: `node_modules/`, `package.json`,
  `package-lock.json`, `bun.lock` (plugin install machinery — opencode
  reinstalls plugins declared in `opencode.json`'s `plugin` array on
  startup, which works through the firewall for allowlisted hosts like
  GitHub/npm), plus third-party plugin configs and stray `*.bak` /
  `*.backup` / `*_1.json` copies (e.g. `oh-my-opencode.json` and friends).
  This means the manifest must copy **named files**, not the whole config
  dir.

### pi (confirmed against this host's install)

Global dir is `~/.pi/agent/` (overridable via `PI_CODING_AGENT_DIR`;
honor it when reading the **host** source if set, but always write to the
default `.pi/agent/` dest in the volume).

| Source (under `~/`) | Dest | Kind |
|---|---|---|
| `.pi/agent/auth.json` | `.pi/agent/auth.json` | file (auth, mode 0600) |
| `.pi/agent/settings.json` | `.pi/agent/settings.json` | file |
| `.pi/agent/models.json` | `.pi/agent/models.json` | file (**contains plaintext provider `apiKey`s** → mode 0600) |
| `.pi/agent/skills/` | `.pi/agent/skills/` | dir (optional, may contain symlinks — see below) |
| `.pi/agent/extensions/` | `.pi/agent/extensions/` | dir (optional) |

Confirmed on a real install (2026-07-07): `~/.pi/agent/` exists with
`auth.json` (0600 — may be an empty `{}` when the user authenticates via
API keys instead of OAuth; copy it anyway), `settings.json`, and a
**`models.json`** the earlier draft missed — it defines custom
OpenAI-compatible providers *including their API keys*, so it is both
required config (the `defaultProvider`/`defaultModel` in `settings.json`
may reference providers defined there) and a secret (force 0600).
`skills/` and `extensions/` do exist as real directories (no path arrays
needed) and are included.

**Excluded (confirmed to exist and deliberately skipped):** `sessions/`
(conversation history — the isolation guarantee), `npm/` (package cache
for the `packages` array in `settings.json`; pi reinstalls those on
startup, which works through the firewall for npm). `trust.json`
(per-project trust decisions) was absent on the inspected host but stays
excluded if present.

> **Symlink caveat (real-world case):** the inspected host's
> `.pi/agent/skills/` contained a symlink pointing outside `$HOME`
> (`skills/omarchy -> ~/.local/share/omarchy/...`). A plain `tar` copy
> would recreate it as a dangling link in the volume. The copy step must
> dereference symlinks (`tar -h`) and tolerate broken ones (warn + skip)
> rather than fail the whole injection.

> **Localhost-provider caveat:** on the inspected host both pi's
> `models.json` and opencode's `opencode.json` define providers at
> `http://127.0.0.1:<port>` (a llama-server on the Docker host). Inside
> the container 127.0.0.1 is the container itself, so those providers
> won't resolve. Not this feature's problem to fix, but the README section
> should point at `--host-port PORT` + editing the in-volume config to use
> `host.docker.internal:<port>` as the supported workaround.

## Copy mechanism & ownership

Host-side only — no network involved, so the firewall/allowlist are
irrelevant to this operation.

1. `dev agent` resolves `RUNTIME` / `RUNTIME_ARGS` / `HOME_VOLUME` /
   `EXPECT_KEEPID` exactly as a normal start would (reuse the existing
   resolution in `dev` + `lib/dev/lifecycle.sh`).
2. For each requested agent, build the list of **existing** manifest sources.
3. `tar` those sources on the host with paths rewritten to the dest layout
   (`--transform` / a staging dir), streamed to stdout. Use `-h` to
   dereference symlinks (real installs symlink skill dirs to paths outside
   the copied tree, which would otherwise land as dangling links); warn and
   skip broken symlinks instead of failing the injection.
4. Pipe the stream into a short-lived helper container:
   - image: the project's own image tag (already built; `busybox`-level
     tools like `tar` are present in the devcontainers base),
   - `--rm -i`, mounts `-v "$HOME_VOLUME":/home/vscode`,
   - **same `--userns=keep-id` args as the real container** when
     `EXPECT_KEEPID` is true, run **as `vscode`**, so extracted files are
     owned correctly and uniformly across Docker, rootful podman, and
     rootless podman — no separate `chown` pass,
   - command: `cd /home/vscode && tar -xf -` (plus `chmod 600` on the
     manifest entries marked mode 0600 — for claude `.credentials.json`;
     for opencode `auth.json`, `mcp-auth.json`, and `opencode.json`; for
     pi `auth.json` and `models.json`).
5. If a workspace container is already running, the helper still writes to
   the same underlying volume, so the change is visible inside the running
   container immediately (the paths are under the live-mounted
   `/home/vscode`). No restart needed.

`--dry-run` stops after step 2 and prints the resolved source→dest list.

> Rationale for the helper-as-vscode approach over `docker cp`: `docker cp`
> writes with numeric uid/gid that don't line up under rootless podman's
> keep-id remap, which is exactly the ownership hazard
> `migrate_volume_for_keepid` exists to fix. Extracting *through* the keep-id
> mapping as `vscode` sidesteps it entirely.

## `list` and `rm`

- **`list`**: for each known agent, print two columns — "on host?" (any
  manifest source exists under host `$HOME`) and "injected here?" (any
  manifest dest exists in the volume). The volume check runs one helper
  container that `test`s the dest paths. Output is a small aligned table.
- **`rm <name>...`**: a helper container `rm -rf`s the manifest's dest paths
  from the volume. Confirms interactively per agent (lists what will be
  deleted first); `DEV_ASSUME_YES=1` skips the prompt. Does not touch the
  host.

## Security considerations

- **Credentials persist in the per-workspace home volume**
  (`devcontainer-home-<dir>`). This is the deliberate trade-off of "copy
  in". Teardown already exists: `dev reset` prompts per named volume, which
  removes the injected creds along with the rest of that workspace's home.
  The `agent rm` command is the targeted alternative.
- **No new network exposure.** The copy never leaves the host↔container
  boundary; the firewall posture is unchanged.
- **Secret file modes** are forced to `600` after extraction. This covers
  more than the obvious auth files: on real installs, opencode's
  `opencode.json` and pi's `models.json` embed plaintext provider API keys,
  so they get 0600 too (see the per-agent manifests for the full list).
- **Snapshot staleness**: OAuth tokens rotate; a stale in-volume token means
  re-running `dev agent add <name>`. Documented, not automated.
- **Isolation preserved**: manifests exclude every tool's project/session
  history, so injecting an agent does not reintroduce the cross-project leak
  the per-workspace home volume was built to prevent.

## Documentation updates

- **README.md**: new "Injecting agent credentials" section (what's copied,
  what's excluded, refresh via re-`add`, teardown via `rm`/`reset`, the
  snapshot-not-mount and no-image-baking guarantees).
- **CLAUDE.md**: add the `dev agent` subcommands to the Build and Run
  command list, and a Key Design Decisions bullet.
- **`dev --help`**: document the `agent` group (mirrors how `fw` is
  documented).

## Testing

New scenario `scripts/test/scenarios/NN-agent-inject.sh` (next free number):

1. Stage a fake host `~/.claude` in a temp `HOME` containing both curated
   files (`.credentials.json`, `settings.json`, `commands/x.md`) and
   excluded ones (`.claude.json`, `projects/`, `history.jsonl`).
2. Run `dev agent add claude`.
3. Assert every curated file is present in the home volume with the right
   ownership, and `.credentials.json` is mode `600`.
4. Assert **none** of the excluded paths landed in the volume.
5. Run `dev agent list` and assert claude shows injected.
6. Run `dev agent rm claude` (with `DEV_ASSUME_YES=1`) and assert the
   curated files are gone.

Pass/fail via the existing `log_pass`/`log_fail`/`log_skip` helpers. The
scenario is self-contained and uses `scripts/test/lib/` like the others.

## Open items for user review

1. ~~**opencode/pi manifest paths**~~ — **resolved 2026-07-07** by
   inspecting a host with both tools installed; the tables above are now
   confirmed (opencode's plural `agents/`/`commands/`/`skills/` subdirs
   remain unverified-but-harmless since missing sources are skipped).
2. Confirm the excluded-vs-included calls for claude's `commands/`,
   `agents/`, `skills/` (included) and `plugins/` (excluded).
3. Confirm the command verbs (`add` / `list` / `rm`) and that `all` should
   mean "every agent detected on the host" (vs. "all three known names").
