# box — microsandbox agent sandbox

> **First-draft prototype** on microsandbox beta v0.5.x. Validated on Linux
> (nested-KVM, `msb` 0.5.7). macOS Apple Silicon is architecturally supported
> but untested.

## What and why

`box` runs a coding agent inside a hardware-isolated microVM (via
[microsandbox](https://microsandbox.dev), libkrun-based). The operator stays
unrestricted on the host; only the agent runs in the VM. It replaces the legacy
container + hand-rolled iptables/tinyproxy `dev` stack with a simpler,
stronger boundary: host-enforced egress policy and leak-proof secret injection
are native microsandbox features, not 300 lines of firewall bash. The
workspace is a live two-way bind mount — the operator edits on the host, the
agent writes into the VM, both see the same files.

## Requirements

- **Linux with KVM** (`/dev/kvm` accessible, user in `kvm` group) — validated.
- **macOS Apple Silicon** — architecturally supported, not yet validated.
- `msb` installed:
  ```sh
  curl -fsSL https://install.microsandbox.dev | sh
  ```
  The installer lands `msb` in `~/.local/bin/` (symlinked from
  `~/.microsandbox/bin/`). Make sure `~/.local/bin` is on your `PATH`:
  ```sh
  export PATH="$HOME/.local/bin:$PATH"
  ```

## Quick start

```sh
cd your-project
/path/to/box provision   # once: installs mise + project tools into the volume
box                      # every run: boots the sandbox and drops into a shell
```

After the first provision, `box` auto-provisions on first use so the explicit
`box provision` call is only needed when you want to run the build step
explicitly (e.g. after `box reset`).

## Command reference

| Command | Behaviour |
|---|---|
| `box` | Boot/attach the sandbox for this directory; open a shell. |
| `box -- CMD...` | Run a one-off command in the sandbox. |
| `box shell` | Attach an extra terminal to the already-running sandbox. |
| `box provision` | Build step (open egress): install mise + project tools into the volume. |
| `box provision --shell` | Interactive open-egress root shell to add things manually (see below). |
| `box provision -- CMD...` | One-off open-egress command (e.g. fetch from a non-allowlisted host). |
| `box down` | Stop the sandbox. |
| `box reset` | Stop and remove the sandbox + marker. Named volumes must be removed manually: `msb volume rm box-mise box-home`. |
| `box --net MODE` | Override egress mode: `none`, `sanctioned` (default), or `full`. |
| `box --help` | Show usage. |

## Two-phase model

### Provision phase (`box provision`)

Runs with **full (open) egress**. Starts an ephemeral foreground VM, installs
`mise` into `/mise/bin`, and runs `mise install` for the project's `mise.toml`.
Populates two named volumes that persist independently of any sandbox:

| Volume | Guest path | Contents |
|---|---|---|
| `box-mise` | `/mise` | mise binary, shims, tool installations, caches |
| `box-home` | `/home/vscode` | shell history, git config, SSH keys |

The current directory is bind-mounted two-way at `/workspace` during provision.

### Manual provisioning (`box provision --shell`)

`box provision --shell` opens an **interactive root shell with open egress**,
landing in `/workspace`, for adding things beyond `mise.toml` — extra language
tools, fetching repos/data from non-allowlisted hosts, etc. `box provision -- CMD`
runs a single such command non-interactively.

**Only `/mise`, `/home/vscode`, and `/workspace` persist** into locked-down runs
(they are volumes / the host bind mount). The system root is ephemeral — each run
boots a fresh VM from the base image. So install tools you want to keep into
`/mise` (e.g. `mise use -g <tool>`, or drop a binary in `/mise/bin`) or `/home`;
a system-wide `apt-get install` will NOT survive the next `box` run. (Persisting
arbitrary system packages would need filesystem snapshots — see `TODO.box.md`.)

### Run phase (default `box`)

Runs with **sanctioned (deny-by-default + allowlist) egress**. Boots a named
sandbox (`box-<dirname>`) mounting the two volumes plus `/workspace`. If the
provisioned marker is absent, auto-triggers `box provision` first. `box down`
stops the sandbox; the volumes persist.

The sandbox name is `box-<dirname>` (basename of `$PWD`).

## Custom base image (`box build`)

The run filesystem is a fresh boot from the base OCI image every time, so
**system-level** changes (apt packages, `/usr`, `/etc`) only persist if they are
baked into the image. To do that, use a custom base image.

The image `box` runs is chosen by precedence:

1. `BOX_IMAGE` environment variable (highest)
2. `.box-image` file at the workspace root (first non-comment line)
3. the default `mcr.microsoft.com/devcontainers/base:ubuntu`

Workflow:

```bash
cp /path/to/box-repo/Dockerfile.box .   # sample template; edit the RUN block
box build                               # builds, loads into msb, pins .box-image
box                                     # now boots from your custom image
```

`box build [TAG]`:
- builds `Dockerfile.box` (default tag `box-<dirname>:local`) with `docker` or
  `podman` (override with `BOX_BUILDER`),
- streams it into microsandbox (`<builder> save TAG | msb image load`, since msb
  can't read the host Docker store directly),
- writes the tag to `.box-image` so plain `box` uses it (skipped if `BOX_IMAGE`
  is set).

mise tools still belong in `mise.toml`, secrets in `.box-secrets`, and fetched
data in the workspace — keep `Dockerfile.box` for genuine system dependencies.

## Docker inside the sandbox (`box --docker`)

The microVM has its own kernel, so a Docker daemon runs inside it as plain root —
**no `--privileged`, `/dev/fuse`, rootless, slirp4netns, or nested-KVM** (unlike
the old shared-kernel DinD). Setup:

```bash
cp /path/to/box-repo/Dockerfile.box.docker Dockerfile.box   # installs docker.io
box build                                                   # build + load + pin
box --docker                                                # boot with dockerd inside
```

Enable it per-invocation with `--docker`, or per-project by creating an empty
`.box-docker` marker at the workspace root. In docker mode `box`:

- mounts a **disk-backed** `/var/lib/docker` named volume (`box-docker`, default
  20G — overlay2 needs a real fs, and the image cache persists across runs),
- bumps memory (`--memory`, default `2G`),
- starts `dockerd` at boot and waits for it to be ready,
- merges `allowlist.dind` (Docker Hub, GHCR, MCR, Quay, GCR) into the egress
  allowlist.

Tunables: `BOX_DOCKER_SIZE` (volume size), `BOX_DOCKER_MEMORY` (RAM).

**Egress still applies to nested containers.** The allowlist is enforced at the
VM boundary, so `docker pull` and everything your nested containers do is subject
to it — registries must be allowlisted (that is what `allowlist.dind` covers; add
project-specific hosts to `.box-allowlist`). This is a feature: a containerized
workload can't bypass the sandbox's egress policy.

## Egress modes

| Mode | Behaviour |
|---|---|
| `none` | Airgapped — all outbound traffic denied. |
| `sanctioned` | **Default for runs.** Deny-by-default + per-host allowlist (see below). |
| `full` | Open egress — used internally by `box provision`. |

## Per-project allowlist (`.box-allowlist`)

Create `.box-allowlist` at the workspace root to allow additional hosts in
sanctioned mode. It is merged with `allowlist.default` (baked into the tool)
at every sandbox **boot**.

```
# One entry per line; # comments ignored.
api.example.com          # exact hostname
*.example.com            # any subdomain (and the apex — *.foo.com matches foo.com too)
```

The default allowlist (`allowlist.default`) covers Anthropic/Claude, GitHub,
npm/PyPI/crates.io, mise/Node, and Debian/Ubuntu package mirrors.

**Important:** the allowlist is applied when the sandbox boots. A sandbox that
is already running will NOT pick up changes to `.box-allowlist` until it is
restarted. Run `box down` then `box` to apply new rules.

## Secrets (`.box-secrets`)

Create `.box-secrets` at the workspace root (keep it out of version control)
to inject secrets into the sandbox. One entry per line:

```
# ENV_NAME  allowed-host
GITHUB_TOKEN  api.github.com
ANTHROPIC_API_KEY  api.anthropic.com
```

`box` passes `--secret ENV@host` to microsandbox for each entry. The guest
sees only the literal placeholder `$MSB_<ENV>` — for example, `GITHUB_TOKEN`
in the guest environment holds the string `$MSB_GITHUB_TOKEN`, not the real
token. Microsandbox substitutes the real value host-side, on the TLS handshake
to the allowed host only. The secret never travels inside the VM.

Like `.box-allowlist`, secrets are applied at sandbox boot. Run `box down`
then `box` to pick up changes.

## Design: microsandbox boundary

All microsandbox-specific CLI syntax is confined to **`lib/msb.sh`**. `box`
itself contains none. This is deliberate: microsandbox is pre-1.0 and warns of
breaking changes. Confining all `msb` invocations to one file means a syntax
change in a future `msb` release is a one-file fix.
