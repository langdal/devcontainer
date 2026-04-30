# Agent Sandbox Firewall — Design

**Date:** 2026-04-30
**Status:** Draft
**Scope:** This repository (the generic devcontainer)

## Goal

Constrain outbound network access from inside the dev container to a curated allowlist of domains, so an AI agent running as the `vscode` user cannot reach arbitrary external hosts. Provide a "maintenance" mode that disables the firewall and grants sudo for legitimate tasks (installing system packages, debugging, fetching tools from non-allowlisted sources).

## Threat model

**In scope.** A semi-trusted AI agent runs as `vscode` inside the container. The agent may be buggy, prompt-injected, or otherwise behave in ways the operator did not intend. The firewall prevents:

- Exfiltration of workspace contents to attacker-controlled hosts.
- Calls to external services that mutate state outside the workspace (e.g. unrelated APIs, webhooks).
- Fetching arbitrary executables from the internet at runtime.

**Out of scope.**

- Kernel or container-runtime exploits granting privilege escalation. Standard Docker assumption.
- Local containment within the container's mounted volumes (`/workspace`, `/home/vscode`, `/mise`). The agent has full read/write there by design.
- An attacker on the host with Docker access. `docker exec --user root` defeats this trivially. The boundary is "agent inside the container."
- DNS-based exfiltration. Allowed for simplicity; see "Alternatives considered."

## Architecture

```
agent process → (HTTPS/CONNECT) → tinyproxy → internet
                                      ↑
                              hostname filter
                                      ↑
                           merged allowlist:
                           base list (image) + project list (workspace)

iptables (default DROP on OUTPUT):
  • allow loopback
  • allow DNS (53/udp, 53/tcp) to anywhere
  • allow only the proxy's UID to reach :443 / :80 outbound
  • everything else → DROP

env vars exported to every shell:
  HTTPS_PROXY=http://127.0.0.1:8888
  HTTP_PROXY=http://127.0.0.1:8888
  NO_PROXY=localhost,127.0.0.1
```

**Load-bearing trick: `iptables -m owner --uid-owner proxy`.** Capabilities apply per-container, not per-user, so `NET_ADMIN` is needed by *something* in the container to set up iptables. We grant it, run the firewall init as root at startup, then drop privileges. The OUTPUT chain only allows ports 80/443 packets that originate from the `proxy` system user's process. An agent running as `vscode` cannot match that owner, so even raw-socket attempts to reach allowlisted hosts on those ports are dropped at the kernel. The proxy is the *only* path out for HTTP(S).

**Tooling:** `tinyproxy` for the forward proxy. Small, supports CONNECT, has an `Allow`/`Filter` directive for hostname filtering. Could be swapped for `squid` later if richer ACLs are needed.

## Allowlist sources

Two layers, merged at container startup.

**Base list — `allowlist.base` in this repo, baked into the image at `/etc/devcontainer/allowlist.base`.**

Plain text, one entry per line, `#` for comments. Matching semantics:

- A bare domain (e.g. `github.com`) matches that hostname exactly. It does NOT match subdomains.
- A `*.` prefix (e.g. `*.github.com`) matches any subdomain (one or more labels) but NOT the bare domain. List both if you need both.
- Entries are compiled into a tinyproxy filter file at startup (one anchored regex per entry, with `.` escaped and `*.` translated to `(.+\.)`).

Starting contents:

```
# Anthropic
api.anthropic.com

# GitHub (HTTPS clone, API, raw, releases)
github.com
api.github.com
codeload.github.com
*.githubusercontent.com
ghcr.io

# Package registries
*.npmjs.org
pypi.org
files.pythonhosted.org
crates.io
static.crates.io

# mise / language runtimes
mise.jdx.dev
nodejs.org
*.nodejs.org

# OS packages
deb.debian.org
security.debian.org
archive.ubuntu.com
security.ubuntu.com
```

**Project list — `.devcontainer-allowlist` at the workspace root (optional).**

Same format. Read by the entrypoint at startup, concatenated with the base list, deduplicated, compiled into the tinyproxy filter file.

Editing `.devcontainer-allowlist` and re-running `dev` (after a container restart) picks up changes. Base-list changes require an image rebuild — that is intentional, since base entries apply to every project on the host.

## Bootstrap sequence

### Dockerfile changes

- Install `iptables`, `ipset`, `tinyproxy`, `dnsutils`, `gosu`.
- Create system user `proxy` (independent UID/GID from `vscode`). This user owns the tinyproxy process and is what `iptables -m owner` matches on.
- Copy `allowlist.base` to `/etc/devcontainer/allowlist.base`.
- Copy helper script `firewall-init.sh` to `/usr/local/sbin/firewall-init.sh`.
- **Remove `/etc/sudoers.d/vscode`** (granted by the base image). Without this, the `vscode` user has no path to root and the firewall cannot be defeated from inside the container.
- Keep `ENTRYPOINT ["/entrypoint.sh"]`. Drop the trailing `USER vscode` from the Dockerfile so the entrypoint runs as root and can configure iptables. The entrypoint drops privileges via `gosu` before exec'ing the shell.

### Entrypoint flow

```
1. (as root) if [ -z "$DEVCONTAINER_MAINTENANCE" ]; then
        run /usr/local/sbin/firewall-init.sh
   fi

   firewall-init.sh:
     a. read /etc/devcontainer/allowlist.base
     b. read /workspace/.devcontainer-allowlist if present
     c. merge + dedupe → /etc/tinyproxy/filter (regex form, anchored)
     d. write /etc/tinyproxy/tinyproxy.conf with:
          User proxy
          Port 8888
          Listen 127.0.0.1
          Filter /etc/tinyproxy/filter
          FilterDefaultDeny Yes
          FilterExtended Yes
     e. start tinyproxy (background)
     f. apply iptables rules:
          iptables -P OUTPUT DROP
          iptables -A OUTPUT -o lo -j ACCEPT
          iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
          iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
          iptables -A OUTPUT -m owner --uid-owner proxy \
                            -p tcp -m multiport --dports 80,443 -j ACCEPT
     g. on ANY failure → exit non-zero (fail closed)

2. (as root) export proxy env into /etc/profile.d/proxy.sh:
       export HTTPS_PROXY=http://127.0.0.1:8888
       export HTTP_PROXY=http://127.0.0.1:8888
       export NO_PROXY=localhost,127.0.0.1
   (skipped in maintenance mode)

3. (as root) if [ -n "$DEVCONTAINER_MAINTENANCE" ]; then
        write /etc/sudoers.d/vscode-maint granting vscode passwordless sudo
        print banner: "MAINTENANCE MODE — firewall disabled, sudo enabled."
   fi

4. existing logic, run as the vscode user (via gosu) so file ownership
   under /home/vscode and /mise stays correct and 'git config --global'
   writes to /home/vscode/.gitconfig:
       gosu vscode bash -c '
         if [[ -f /home/vscode/.zshrc ]] && ! grep -q "mise activate zsh" /home/vscode/.zshrc; then
             echo "eval \"\$(mise activate zsh)\"" >> /home/vscode/.zshrc
         fi
         if [[ -f /workspace/mise.toml || -f /workspace/.mise.toml ]]; then
             mise install || echo "WARNING: mise install failed" >&2
         fi
         git config --global --add safe.directory /workspace
       '

5. exec gosu vscode "$@"
```

**Fail-closed:** any non-zero exit from `firewall-init.sh` aborts container startup. The container will not run with a partially-configured or absent firewall.

## Sudo posture & maintenance mode

**Normal mode (default).** No sudo for `vscode`. The `sudo` binary remains installed but `vscode` is not in any sudoers fragment, so calls fall through with "user is not in the sudoers file." Combined with the `iptables -m owner` rule, the agent has no path to root and no path to bypass the proxy. This is the actual security boundary.

**Maintenance mode (`dev --maintenance`).**

- `dev` adds `-e DEVCONTAINER_MAINTENANCE=1` to `docker run`.
- Entrypoint sees the env var and skips `firewall-init.sh`, skips proxy env export, writes `/etc/sudoers.d/vscode-maint` granting `vscode` passwordless sudo for this container's lifetime, and prints a banner at shell start.
- Container name is suffixed: `dev-<dirname>-maint`. This prevents the two modes from sharing a process tree and avoids the `dev` script's "attach to existing container" logic matching the wrong one.
- `dev` refuses to start `--maintenance` if the normal container for the same workspace is currently running, and vice versa. Reason: both would have `/workspace` mounted; concurrent file writes from a sandboxed and a privileged process create surprising state. User must `docker stop dev-<dirname>` first.

What this gets you:

- `dev --maintenance -- apt-get install foo` works.
- `dev --maintenance -- mise install` for a tool that fetches from a non-allowlisted host works without editing the allowlist.
- Day-to-day `dev` runs the agent sandboxed with no escape.

## `dev` script changes

New flag:

```
--maintenance   Start container with firewall disabled and sudo enabled.
                Container name is suffixed with -maint to avoid clashing
                with the normal container.
```

Behavioral changes:

1. `CONTAINER_NAME` gets `-maint` suffix when `--maintenance` is passed.
2. Every `docker run` adds `--cap-add=NET_ADMIN`. Both modes get it; harmless when unused, keeps the two modes structurally identical.
3. Conflict guard: `--maintenance` exits non-zero if `dev-<dirname>` is running; the normal path exits non-zero if `dev-<dirname>-maint` is running.
4. `--maintenance` adds `-e DEVCONTAINER_MAINTENANCE=1` to `docker run`.
5. Help text updated.

The "another dev-* container is running, skipping default port forwards" auto-collision block is left as-is. `dev-foo` and `dev-foo-maint` collide on ports the same as any two dev-* containers do.

Volume mounts, `GITHUB_TOKEN` passthrough, the `install` subcommand, and `--port`/`--no-ports`/`--build`/`--dry-run` flags are unchanged.

## Verification

A helper script `scripts/verify-firewall.sh` runs inside the container and produces a pass/fail report.

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | proxy reachable | `curl -fsS http://127.0.0.1:8888` | tinyproxy 400 response |
| 2 | allowed host via proxy | `curl -fsS https://api.github.com/zen` | text response |
| 3 | blocked host via proxy | `curl -sS https://example.com` | 403 from tinyproxy |
| 4 | raw socket bypass blocked | `curl -sS --noproxy '*' https://api.github.com` | timeout / refused |
| 5 | DNS works | `getent hosts example.com` | IP returned |
| 6 | sudo blocked | `sudo -n true` | "not in sudoers" / password required |
| 7 | iptables flush blocked | `sudo -n iptables -F` | denied |

In maintenance mode, checks 3, 4, 6, 7 are reported as "skipped (maintenance mode)".

Manual checks (recorded here, not automated):

- `docker build` and `docker build --build-arg USER_UID=501` both succeed.
- `dev` from a project with `.devcontainer-allowlist` reaches the listed domains.
- `dev --build` rebuilds the image and the firewall layer is present.
- `dev --maintenance` while `dev-<dir>` is running prints the conflict error and exits non-zero. Mirror check works in the other direction.
- Existing flow unbroken: `dev -- npm run dev` works for an allowlisted-package project; `mise install` succeeds when the project's tool sources are allowlisted.

## Alternatives considered

- **DNS-level filtering (e.g. dnsmasq with allowlist).** Rejected for v1: adds moving parts and care is needed not to break the proxy's own resolution. DNS exfiltration is slow and noisy; the operator can revisit if it becomes a real threat.
- **iptables + ipset on resolved IPs only (no proxy).** Rejected: CDN IP rotation breaks GitHub, npm, and similar services; needs a re-resolution daemon. The proxy avoids this entirely by filtering on hostname.
- **Restricted sudo via command allowlist.** Rejected: sudo command filtering has many bypasses (e.g. `sudo vim` → `:sh`, `sudo find -exec`). Removing sudo entirely from `vscode` is the only robust posture.
- **`squid` instead of `tinyproxy`.** Heavier than needed today. Revisit if hostname-based filtering is insufficient.

## Files added or changed

- `Dockerfile` — install firewall packages, create `proxy` user, remove vscode sudoers, drop trailing `USER vscode`, copy `allowlist.base` and `firewall-init.sh`.
- `entrypoint.sh` — run as root, branch on `DEVCONTAINER_MAINTENANCE`, drop privileges via `gosu` at end.
- `firewall-init.sh` (new) — merge allowlists, configure tinyproxy, apply iptables.
- `allowlist.base` (new) — base domain allowlist.
- `dev` — `--maintenance` flag, conflict guards, `--cap-add=NET_ADMIN`, env passthrough, container name suffix.
- `scripts/verify-firewall.sh` (new) — verification helper.
- `README.md` — document the firewall and `--maintenance` flag.
