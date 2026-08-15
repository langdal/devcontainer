# Security review guide

This document is for a colleague doing a first security review of this
repo before adopting it — what the sandbox is actually for, what enforces
it, and where to look to verify the claims yourself.

## 1. Threat model

The sandbox protects against an agent **finding and using the host's keys
and secrets by accident, or — in misguided loyalty — searching for
solutions outside the sandbox.** That is: an AI coding agent running
inside the container, given a task it's struggling with, reaching for
whatever credentials or reach it can find to get the job done — reading an
SSH key it stumbled across, calling out to an arbitrary host to fetch a
"helpful" script, or otherwise using capability it was never meant to
have. The container makes that reach small: no host `$HOME`, no SSH keys,
no ambient host credentials, a curated list of hosts it can talk to at
all.

This is **containment of agent reach, not exfiltration prevention.**
Every host on the allowlist is fully reachable, and the channel is
bidirectional — GitHub, npm, Anthropic's API, and the rest are ordinary
HTTPS endpoints an agent can both push to and pull from by design (that's
how `git push`, `npm publish`, or a Claude API call works at all). If an
agent decides to exfiltrate workspace contents to a host that is already
on the allowlist — e.g. by committing a secret into a GitHub gist, or
pasting it into a prompt sent to Anthropic — the firewall does not stop
that and was never meant to. What it stops is the agent reaching a host
*not* on the list, or reaching host-side material (keys, credentials,
history from other projects) that was never placed in the container to
begin with.

See "Deliberate non-goals" (§4) for the boundary of this model, and
"Known sharp edges" (§5) for where the implementation doesn't fully live
up to it yet.

## 2. What enforces the boundary

| File | Mechanism | What to verify when reviewing |
|---|---|---|
| `Dockerfile` | Strips `vscode`'s passwordless sudo (`rm -f /etc/sudoers.d/vscode ...`); copies the tinyproxy binary to `/usr/local/sbin/dc-tinyproxy` so no host AppArmor profile attaches to it; creates a dedicated `proxy` system user that iptables' owner-match rule keys off. | `vscode` has no entry under `/etc/sudoers.d/` in the built image (no `--maintenance`). The `dc-tinyproxy` copy exists and the original `tinyproxy` binary is not what's invoked by `firewall-init.sh`. A `proxy` system user exists with no login shell. |
| `entrypoint.sh` | Runs `firewall-init.sh` before anything else, as root; **fails closed** — any non-zero exit aborts container startup (`echo FATAL ...; exit 1`) rather than falling through to an unfirewalled shell. Seeds git identity and JVM proxy config only if absent (never overwrites), so a customized value inside the volume is never clobbered by host state. | The `set -euo pipefail`-style fail path from `firewall-init.sh`/`firewall-disable.sh`/`dind-init.sh`/`pind-init.sh` failure actually aborts entrypoint (no `\|\| true` swallowing it). Seed blocks are gated on `[ ! -f ... ]` / empty-value checks, not unconditional writes. |
| `firewall-init.sh` | Builds the tinyproxy hostname filter from the baked base allowlist plus the *approved* project snapshot (never the live workspace file — see §3/approval gate); defaults iptables `OUTPUT` to DROP for both IPv4 and IPv6; only the `proxy` UID may reach 80/443 directly; refuses to start on an empty filter or on an unfilterable global IPv6 address. | The script never opens `$PROJECT` from `/workspace` — only from `/etc/devcontainer/project/allowlist.approved` (read-only bind mount). `iptables -P OUTPUT DROP` and the IPv6 mirror are both present and unconditional in the non-maintenance path. The empty-filter and "IPv6 present but unprogrammable" checks both `exit 1`. |
| `firewall-disable.sh` | The explicit, single opt-out surface: opens `OUTPUT` to ACCEPT (v4+v6) and flips tinyproxy to an allow-all filter. Only reachable via `dev fw off`, `dev up --open`, or `DEVCONTAINER_FW_DISABLED=1` — never invoked implicitly by any other code path. | Every caller of this script is a deliberate, visible user action (CLI verb or explicit env var), never a fallback triggered by an error elsewhere. It leaves a `zz-fw-disabled-banner.sh` so new shells in the same container show the firewall is off. |
| `allowlist.base` / `allowlist.dind` | Define the entire egress universe: what the tinyproxy filter allows through, full stop. Anything not listed (and not covered by the project's own reviewed `.devcontainer-allowlist`) is unreachable. | Read both files end to end — they're short. Every entry is a real destination this project's tooling needs (Anthropic, GitHub, package registries, OS mirrors, Sigstore for `mise`'s attestation checks; `allowlist.dind` adds container registries only merged when DinD/PinD is active). No wildcard broader than a single registry's own subdomain set. |

## 3. Reading order for a first review

1. **`Dockerfile`** — establishes the trust boundary at build time: no
   sudo for `vscode`, the `dc-tinyproxy` rename, the `proxy` user, and
   which scripts get baked in read-only (`firewall-init.sh`,
   `firewall-disable.sh`, `allowlist.base`).
2. **`entrypoint.sh`** — establishes it at container-start time: fail-closed
   firewall bring-up, seed-never-overwrite semantics for anything that
   touches the home volume.
3. **`firewall-init.sh`** — the actual enforcement: default-DROP policy,
   the owner-uid rule, the approved-allowlist-only read, the IPv6 mirror.
4. **`allowlist.base` / `allowlist.dind`** — the egress universe those
   rules are built from.
5. **`lib/dev/container.sh` + `lib/dev/volumes.sh` + `lib/dev/inject.sh`**
   (the CLI mount/exec surface) — what `dev` puts inside the container in
   the first place, since a perfect firewall doesn't help if the mount
   surface itself leaks host secrets:
   - **Mounts** (`append_volume_mounts` in `volumes.sh`): the workspace
     directory at `/workspace` (read-write, the project being worked on —
     this is agent-writable and therefore untrusted input, per the
     approval gate below); `devcontainer-mise:/mise` (shared tool cache,
     no secrets); a **per-workspace** home volume at `/home/vscode`
     (`devcontainer-home-<dir>`, isolated so one project's agent can't read
     another project's SSH keys/git config/shell history out of a shared
     home — `DEV_SHARED_HOME=1` opts back into a single shared volume);
     and, when a project allowlist was approved, a read-only mount of the
     host-side *approved snapshot* directory at
     `/etc/devcontainer/project` (never the live workspace file).
   - **Injection** (`lib/dev/inject.sh`, used by `dev agent add` /
     `dev dotfile add`): a curated, allowlisted set of host files (agent
     OAuth tokens, CLI settings, dotfiles) is copied — one-way, snapshot,
     never a live mount — into the workspace's home volume via a
     short-lived helper container that extracts a tar stream as `vscode`.
     Secret files are forced to mode `0600`. This is the one deliberate
     hole in "no host credentials in the container": it exists because
     agent harnesses need their own auth to function, so review the
     manifest in `lib/dev/agent.sh` (`AGENT_KNOWN`, the per-agent file
     lists) to confirm it copies only auth/settings, never a tool's
     cross-project conversation/session history.
   - **What the CLI never mounts**: the host's real `$HOME`, host SSH keys
     (`~/.ssh` is not in any agent/dotfile manifest by default and is
     never bind-mounted), or any host credential store beyond the explicit,
     reviewable `dev agent add` / `dev dotfile add` copy paths above.

## 4. Deliberate non-goals

- **Exfiltration via an allowlisted host.** If a host is reachable, it is
  reachable for both directions of a normal HTTPS conversation. The
  firewall does not (and structurally cannot, at the hostname-filter
  layer it operates at) distinguish "clone a repo" from "push workspace
  contents to a repo." Keeping the allowlist short and reviewing
  `.devcontainer-allowlist` additions (§ approval gate) is the mitigation,
  not a technical block.
- **A malicious or compromised base image.** The Dockerfile pins
  `mcr.microsoft.com/devcontainers/base:ubuntu` by digest and verifies
  sha256 checksums on binaries it downloads (rootless Docker/Compose/
  Buildx bundles), but does not attempt to detect a base image that is
  already compromised upstream.
- **Kernel exploits from inside the container.** The firewall is an
  iptables/tinyproxy userspace-and-kernel-netfilter control; it assumes
  the container's kernel isolation (namespaces, seccomp, etc. — whatever
  the container runtime provides) holds. A container-escape kernel exploit
  is out of scope for this document.
- **The maintenance-mode escape hatch.** `./dev up --maint` deliberately
  disables the firewall and re-grants `vscode` sudo, for tasks that
  genuinely need unrestricted egress or system package installs (see
  `entrypoint.sh`'s `DEVCONTAINER_MAINTENANCE` block). This is documented,
  opt-in (a distinctly-named `-maint` container, never the default), and
  banners loudly on every shell (`zz-maint-banner.sh`). It is a known,
  visible hole, not a bug.

## 5. Known sharp edges

- **Host AppArmor interactions.** On some hosts a system AppArmor profile
  attached to the `tinyproxy` binary path would confine the *container's*
  tinyproxy under rootless runtimes too (profiles attach by path and that
  attachment crosses the container boundary), breaking the firewall
  fail-closed at startup. The `dc-tinyproxy` rename in the Dockerfile
  sidesteps this by using a path no host profile matches — but that means
  the mitigation is "no profile happens to match this path" rather than an
  explicit exemption; a host-side profile written broadly enough (e.g. by
  binary hash, or covering `/usr/local/sbin/*`) could still catch it. If
  `--dind`/`--pind` won't start, check
  `kernel.apparmor_restrict_unprivileged_userns` first (the preflight
  documented in `README.md` / `CLAUDE.md`).
- **IPv6 posture.** IPv6 egress is mirrored to the same default-DROP
  policy as IPv4 (added after an earlier fix-pack — some runtimes, notably
  podman 5's pasta backend, hand the container a global IPv6 default
  route by default, which would otherwise bypass an IPv4-only firewall
  entirely). `firewall-init.sh` refuses to start if it cannot program
  `ip6tables` *and* a global IPv6 address is present. Worth re-verifying
  after any runtime/kernel upgrade that changes how IPv6 addressing is
  handed to containers — this is exactly the class of regression the
  mirror was added to close.
- **`DEV_ASSUME_YES=1` waives the project-allowlist review.** Normally
  `dev` diffs `.devcontainer-allowlist` (agent-writable, inside
  `/workspace`) against a host-side approved snapshot and prompts before
  merging any change into the firewall (`lib/dev/approval.sh`). Setting
  `DEV_ASSUME_YES=1` — intended for CI/non-interactive rebuild prompts —
  auto-approves allowlist changes without pausing for confirmation: the
  diff is still printed to stderr unconditionally (`lib/dev/approval.sh`
  runs `diff -u` before it even checks `DEV_ASSUME_YES`), but nothing
  waits for a human to actually read it in a non-interactive context. An
  agent that can persuade a `DEV_ASSUME_YES=1` environment to restart the
  container effectively gets to add its own allowlist entries with no one
  reviewing the printed diff. Don't set it globally in an environment
  where an agent controls the workspace contents; set it only for the
  specific non-interactive prompts it's meant for.
