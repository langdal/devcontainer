# Design: microsandbox agent-sandbox (`box`)

**Date:** 2026-06-15
**Branch:** `microsandbox-prototype`
**Status:** Approved design — first-draft prototype

## Purpose

Replace the container-based dev/agent sandbox (a `dev` bash wrapper + Dockerfile
on Docker/Podman, with a hand-rolled iptables default-deny + tinyproxy hostname
allowlist) with a tool that runs coding agents inside hardware-isolated microVMs
via [microsandbox](https://microsandbox.dev) (libkrun-based, Apache-2.0, runs
standard OCI images, ships an `msb` CLI). The operator stays unrestricted on the
host; only the agent runs inside the VM.

**Why we're changing:** the shared-kernel container + hand-rolled firewall is
brittle across environments and is a lot of moving parts for a relatively weak
isolation guarantee. microVMs give a stronger, simpler-to-reason-about boundary,
and microsandbox provides host-enforced egress policy and leak-proof secret
injection natively — replacing ~300 lines of firewall bash, a proxy user, and
NFLOG plumbing with declarative flags.

## Properties preserved from the existing solution

- Operator works on the host; the workspace is bind-mounted live and two-way.
- mise-driven per-project tools.
- A static egress allowlist editable from **outside** the sandbox.
- Single-command DX (`cd project && box`).
- Works on macOS (Apple Silicon) + Linux (with KVM). *Prototype validated on
  Linux; macOS kept portable but unvalidated.*

## Verified microsandbox facts (docs checked 2026-06-15, v0.5.7)

- **Secret injection** (the highest-value feature to de-risk): CLI
  `--secret "ENV@host"` reads the real value from a host env var, injects only a
  placeholder (`$MSB_<ENV>`) into the guest, and substitutes the real value
  host-side only on a TLS handshake to the allowlisted host.
- **Egress policy** is host-enforced: `--net-default-egress deny|allow` plus
  `--net-rule` entries (first match wins), targeting groups (`public`/`private`/
  `host`), IPs, CIDRs, domains, protocols, ports. Replaces the iptables +
  tinyproxy stack entirely.
- **Bind mounts** are native and two-way: `--mount-dir HOST:GUEST[:opts]`
  (opts: `ro,rw,noexec,nosuid,nodev,stat-virt,host-perms`).
- **Named volumes**: `--mount-named NAME:GUEST` (directory- or disk-backed),
  persist independently of any sandbox.
- **Snapshots** are filesystem-only and boot a *fresh* VM (not a memory fork) —
  so a persistent named volume, not a snapshot, is the simplest way to carry the
  mise-ready state across runs. Snapshots are an optional later optimization.
- **CLI**: `msb run/create/exec/start/stop/rm/ls/install`; `--name` makes a
  sandbox persistent; `msb install <name>` aliases a sandbox to a top-level
  command. Per-project config is CLI-flag-driven (global `~/.microsandbox/
  config.json` holds only defaults; no project "Sandboxfile" in the docs index).

**Open item to confirm in the install spike:** exact `--net-rule` syntax for an
allowlisted *domain* (docs show `allow@public:tcp:443` and name domains as valid
targets but give no domain example). Everything microsandbox-specific lives
behind `lib/msb.sh`, so confirming/adjusting this touches one file.

## Architecture

### Wrapper boundary (the central rule)

Two files:

- **`box`** — the CLI/UX layer: argument parsing, project detection, lifecycle
  decisions, allowlist merge, user-facing messaging. Contains **no** `msb`
  syntax.
- **`lib/msb.sh`** — the **only** file that knows microsandbox. Every `msb`
  invocation lives here behind named functions (`msb_boot`, `msb_exec`,
  `msb_provision`, `msb_net_rules`, `msb_mount_args`, `msb_secret_args`,
  `msb_down`, …). microsandbox is pre-1.0 and warns of breaking changes;
  confining all of it to one file means future breakage is a one-file fix.

### Commands (prototype surface)

| Command | Behaviour |
|---|---|
| `box` | Boot/attach the run VM for CWD, drop into an interactive shell. |
| `box -- <cmd>` | Run a one-off command in the run VM. |
| `box shell` | Attach an extra terminal to the running VM (`msb exec`). |
| `box provision` | Egress-open build step: pull image, install mise + tools into the persistent volume. Replaces the old `--maintenance`. |
| `box down` | Stop the VM. |
| `box reset` | Tear down the VM and prompt per named volume. |
| `box install` *(slice 5)* | Alias the run flow under the agent's own name. |

### Lifecycle & persistence (named-volume model)

Two microsandbox named volumes mirror the existing two-volume design:

- `box-mise` → `/mise` (tools/caches)
- `box-home` → `/home/<user>` (shell history, git config, SSH keys)

The current directory is a two-way bind mount at `/workspace`
(`--mount-dir "$PWD:/workspace"`).

- **Provision phase** (`box provision`, egress = `full`): `msb pull` the base
  OCI image, install mise into `/mise`, run `mise install` for base + project
  tools. Populates the persistent volumes once.
- **Run phase** (default `box`, egress = `sanctioned`): boot a named VM mounting
  the two volumes + the workspace. No provisioning egress is ever needed. If the
  mise volume is empty on first `box`, auto-trigger provision.
- **Base OCI image:** `mcr.microsoft.com/devcontainers/base:ubuntu` (familiar,
  ships zsh/git). Swappable later.
- **Snapshots:** deferred. Named volumes already carry the mise-ready state.

### Egress allowlist

`box` generates declarative microsandbox net-rules from a merged allowlist, with
three modes:

- `none` — airgapped (`--net-default-egress deny`, no allow rules).
- `sanctioned` — **default for runs**: deny-by-default + allowed domains.
- `full` — provision only: open egress.

Allowlist sources, merged + deduplicated at every boot (mirrors today's merge):

1. **Default list** baked with the tool, ported from `allowlist.base`
   (Anthropic, GitHub, common registries, mise, OS mirrors).
2. **`.box-allowlist`** at the workspace root — optional, read every boot,
   editable from outside the VM, no rebuild. One entry per line, `#` comments;
   bare host = exact, `*.host` = subdomains (same format as today).

`lib/msb.sh` translates entries into `--net-default-egress deny` +
`--net-rule "allow@<domain>:tcp:443"` (exact form confirmed in the spike).

### Secrets (slice 3)

A `.box-secrets` declaration **outside the repo** maps `ENV_NAME → host`. `box`
passes `--secret "ENV@host"` per entry. The guest sees only `$MSB_<ENV>`; the
real value is substituted host-side on TLS to the allowed host. Validated by
asserting the guest's environment holds the placeholder, never the secret.

### Operator on host

Unchanged: the operator edits/gits/mises on the host against the live bind mount;
only the agent runs inside the VM.

## What we delete

`firewall-init.sh`, `firewall-disable.sh`, tinyproxy config, all iptables/ipset
rules, the `proxy` user owner-rule, NFLOG logging, the `--maintenance` /
`--dind` / `--monitor` / `--monitor-fw` / `--disable-firewall` / `--enable-firewall`
flags, the UID/GID rebuild prompt machinery, and the custom Dockerfile firewall
layers. Replaced by microsandbox host-enforced net policy + named volumes.

## Prototype scope (this branch)

- **Slice 1 — Core loop:** `box` boots a named VM, two-way-mounts CWD, mise
  available, default `sanctioned` allowlist enforced, drops into a shell; plus
  `box -- <cmd>` and `box shell` re-attach. Proves the core loop and that native
  net policy replaces iptables.
- **Slice 2 — Two-phase lifecycle:** `box provision` (egress open → mise install
  into the persistent volume), then locked-down runs; auto-provision on empty
  volume.
- **Slice 3 — Leak-proof secrets:** `.box-secrets` → `--secret ENV@host`; verify
  the guest sees only the placeholder.
- **Slices 4–5 (documented TODOs):** allowlist modes polish + per-project file
  ergonomics; `box install` under the agent's name; optional snapshot
  optimization; macOS validation; dind-in-microVM.

**First plan step is an install spike:** `curl -fsSL https://install.microsandbox.dev | sh`,
boot a trivial VM, and confirm mount + net-rule + secret syntax behave as
documented before building on them (it is beta).

**Commit cadence:** a separate commit after each implementation step
(per operator request), Conventional Commits style, unsigned in this sandbox
per repo policy.

## Assumptions & risks

- This host is a nested-KVM guest with `/dev/kvm` exposed; nested virt may have
  rough edges — surfaces in the spike.
- microsandbox is pre-1.0 (v0.5.x) and may break — mitigated by the `lib/msb.sh`
  boundary.
- Snapshots, dind-in-microVM, and macOS validation are explicitly deferred.
- Exact domain `--net-rule` syntax is unconfirmed until the spike.
