# Feature worktrees: `dev ft` / `dev fta`

Run several features of one repo in parallel, each with its own branch, its
own worktree, its own host herdr tab, and — when you want one — a coding
agent working inside the repo's sandbox container.

The model in one paragraph: herdr runs **on the host only**. Each feature is
a git worktree at `<repo>/.worktrees/<name>` on a branch `feat/<name>`, so
the same files are visible to the host (your editor, your dev servers) and
to the repo's **one** `dev-<repo>` container (as
`/workspace/.worktrees/<name>`). `dev ft` gives you the worktree and a tab;
`dev fta` additionally starts the container headless if needed, builds the
worktree to completion, and attaches the tab into the container running the
agent. Removing a feature cleans up tab, worktree and (when merged) branch.

## Commands

| Command | Does |
| --- | --- |
| `dev ft NAME` | Branch `feat/NAME` off `origin/main` + worktree at `.worktrees/NAME` (reused if it exists), and a host herdr tab cd'd into it. Build-free and container-free. |
| `dev fta [-cl\|-op\|-pi] [--open\|--closed] NAME` | Same, then: auto-start the container (headless; `dev down` stops it), build the worktree (`mise install` + the `setup` task), attach the tab into the container, start the agent found there — `claude`, `opencode` or `pi`; a plain shell when none. |
| `dev ft -l` | `git worktree list` for the repo. |
| `dev ft -r NAME` | Close the feature's tabs, remove the worktree, delete the branch only when merged. Refuses uncommitted/unpushed work and running mise daemons. |
| `dev ft -rf NAME` | Force: stop daemons, discard everything. |
| `dev ft --completions` | Print the shell completion (see setup). |

Defaults and overrides: base ref `origin/main` via `FT_BASE` or
`git config ft.base` (e.g. `main` for a repo with no remote); agent kind via
the flags, `FT_AGENT`, or `git config ft.agent`, else probed in the
container (claude → opencode → pi). All commands work from anywhere inside
the repo — a worktree, a subdirectory — and always target the repo's main
checkout and its one container.

## User guide

Start a feature with an agent:

```bash
dev fta payments          # worktree + build + tab attached, agent running
```

Inside the tab you are in the container at the worktree. The agent exiting
(double `Ctrl+C` in claude) drops you to a container shell there; `exit`
once more returns to the host. Re-running `dev fta payments` reopens the
feature and re-runs the (idempotent) build — also how you add an agent to a
feature created with plain `dev ft`.

Run the dev servers **on the host**: `dev ft`'s tab is build-free by design,
so the first time in a worktree run `mise run setup`, then either

```bash
mise run dev                      # foreground, visible console, Ctrl+C stops
# or, background:
mise daemons start && mise daemons urls
mise daemons logs vite --follow   # add `pty = true` to [daemons.vite] for full dev-server output
```

Ports are per-worktree automatically (see setup): each feature's frontend
talks to *its* backend, in parallel with every other feature's. Don't run
the foreground pair while the same worktree's daemons hold the ports —
`strictPort` will tell you.

Finish a feature: merge it, then `dev ft -r payments`. All refusal checks
(uncommitted changes, unpushed commits, running mise daemons on the host
AND in the container) run before any tab is closed, and only the tabs ft
itself opened are closed — a removal run from inside the feature's own tab
closes that tab last. An unmerged branch is kept; `-rf` stops daemons on
both sides and discards everything.

Two platforms, one worktree: the directory serves macOS (host) and Linux
(container), so each side installs its own native dependencies — `fta`'s
build covers the container, your first `mise run setup` in the tab covers
the host. Node's per-platform optional deps (esbuild, rollup) coexist;
Python venvs don't — key them per OS (see setup). Go needs nothing: its
caches live outside the worktree.

## Setup

Closed egress: the firewall mode is fixed when the container is CREATED.
`dev fta --closed NAME` applies it when fta's autostart creates the
container (ignored for an already-running one); `DEV_EGRESS=closed` in the
environment does the same and makes a good per-repo default via the host
mise config. fta mirrors the proxy and nested-engine variables into its
build, probe and agent execs, and waits for the entrypoint (firewall
included) before running anything.

### Per machine (host)

Prerequisites: herdr, `jq`, git ≥ 2.48, and mise (keep it close to the
container's pinned version). Tab completion for feature names, in
`~/.zshrc` — `bashcompinit` must run first (after `compinit`, and after any
framework like oh-my-zsh that runs `compinit` itself), and the eval must
come *below* the `compdef _gnu_generic dev` line `dev install` writes (or
delete that line):

```zsh
autoload -Uz compinit bashcompinit && compinit && bashcompinit
eval "$(dev ft --completions)"
```

### Per repository

Git, once (ft also sets the first one automatically and warns when the
created pointer still came out absolute — i.e. git < 2.48):

```bash
git config worktree.useRelativePaths true   # worktree pointers resolve on host AND in container
git config ft.base origin/main              # optional; 'main' for remoteless repos
git config ft.agent claude                  # optional default agent
```

mise, committed in `mise.toml` — this is what makes ports per-worktree and
the build a single named step:

```toml
[settings]
experimental = true                  # daemons + automatic per-worktree ports

[tools]
node = "22"
python = "3.12"

[tasks.setup]
run = "npm install"                  # "build the whole project"; fta runs this

[tasks.dev]
depends = ["dev:vite", "dev:sidecar"]
[tasks."dev:vite"]
run = "npm run dev"
[tasks."dev:sidecar"]
run = "python -m sidecar"

# Daemon names matter: a custom daemon exports <NAME>_PORT, so these export
# exactly VITE_PORT and SIDECAR_PORT. The primary checkout gets the base
# port; each worktree gets a deterministic slot from a 512-wide span — no
# fallback: conflicts fail loudly (pair with Vite's strictPort).
[daemons.vite]
run = "npm run dev"
port = { auto = true, base = 5200 }
pty = true                           # real dev-server output in `daemons logs`

[daemons.sidecar]
run = "python -m sidecar"
port = { auto = true, base = 6000 }  # separate span per daemon

[env]
VITE_SIDECAR_URL = "http://127.0.0.1:{{ env.SIDECAR_PORT }}"
# Python only — one venv cannot serve both OSes:
# _.python.venv = { path = ".venv-{{ os() }}", create = true }
```

Your app reads the ports from the environment (e.g.
`server.port: Number(process.env.VITE_PORT)` with `strictPort: true` in
`vite.config.ts`); keep `VITE_`-prefixed vars out of production builds, as
Vite inlines them. Commit config changes on a branch like any other change:
a worktree's config chain includes the parent checkout's `mise.toml`, and a
task defined only in the parent runs *in the parent's directory*.

Agents: install the binary in the container (e.g. the claude installer into
`~/.local/bin`, which persists in the home volume), then `dev agent add
claude` for credentials — or run the agent's own login once inside the
container, which is immune to host credential rotation. `fta` names the
agent for herdr's panel via the documented `HERDR_AGENT` wrapper hint.
