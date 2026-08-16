# Egress open-by-default — design

Date: 2026-08-16
Status: approved in discussion; pending spec review
Scope: flip the firewall's default posture. Follows the CLI overhaul
(`2026-08-14-cli-overhaul-design.md`) — assumes the verb CLI, the
`lib/dev/` module split, `fw off|on`, and SECURITY.md are already in place.

## Problem

The container's default is a hostname-allowlist egress firewall (closed).
For the primary use case — a dev laptop or a Proxmox VM where an agent runs
the full edit-build-test-run loop — the allowlist produces constant 403
friction during org adoption: any host not pre-listed fails, often as a
hang or a cryptic proxy 403 an agent won't diagnose.

The firewall's egress confinement is **not** what protects the host and its
secrets. That protection is isolation — no host mounts, per-workspace home
volume, no SSH keys or host creds copied in, unprivileged `vscode` with no
sudo — and it is unchanged by egress posture. Opening egress does not weaken
it. The one network path to host secrets, the cloud-metadata / link-local
endpoint, is closed explicitly in every mode (below).

## Decision

Flip the default: `dev up` is **open** egress. The hostname-allowlist
confinement becomes opt-in **closed** mode. A single link-local block is
always on, in both modes.

Threat-model framing (authoritative, carried into SECURITY.md): the sandbox
protects against an agent finding/using the host's keys and secrets by
accident, or — in misguided loyalty — reaching host resources outside the
sandbox. Isolation delivers that. Egress confinement (closed mode) is an
optional extra hardening layer for users/projects that want it; it is not
exfiltration prevention (an allowlisted host is bidirectionally reachable).

Settled in discussion:
- Default flips to open; closed is opt-in.
- `169.254.0.0/16` (v4) and `fe80::/10` (v6) blocked in **all** modes.
- Opt-in path: explicit `--closed`/`--open` flags plus a host env
  `DEV_EGRESS`. **No repo-side signal** — `.devcontainer-allowlist` keeps its
  single existing meaning (extra hosts, closed mode only).
- Live toggle retained: `dev fw open` / `dev fw close` (+ `log`/`drops`).
- Vocabulary: open / closed, on both the start flag and the fw toggle
  (renames the just-shipped `fw off|on` → `fw open|close`; pre-release, so
  the churn is free).

## 1. Approach

**Open mode is proxy-free, IP-layer only.** iptables OUTPUT policy ACCEPT
(v4+v6) plus the always-on link-local DROP; no tinyproxy, no `HTTPS_PROXY`,
no allowlist filter, no `no-aaaa` resolver edit, no Maven/Gradle proxy
seeding. This extends what `firewall-disable.sh` already does (flush OUTPUT
to ACCEPT) and is what makes open mode behave like the host: any port, any
protocol — raw TCP to an external DB, SSH, gRPC — not just proxy-aware HTTP.

Proxy-free does **not** mean unobservable. Open mode keeps egress visibility
at the kernel layer instead of the proxy layer (§3, "Egress logging"): DNS
queries reveal the hostnames the container tries to reach, and a
new-connection NFLOG records outbound connections at IP:port for every
protocol. `dev fw log` surfaces both. The ceiling without terminating TLS is
hostname + IP:port (no URLs/methods) — closed mode's proxy log is still the
richer per-request audit trail when that matters.

**Closed mode is today's behavior unchanged** (default-DROP OUTPUT, only the
`proxy` uid reaches :80/:443, tinyproxy hostname filter from
base+approved-project allowlists), plus the same always-on link-local DROP
as defense-in-depth.

Rejected: keeping tinyproxy running in open mode with an allow-all filter
(for uniform `fw log`). Enforcing nothing through a running proxy while
relaxing the owner-rule buys log lines at the cost of the "just works" goal.

## 2. Mode resolution & precedence

At `dev up`/`dev exec`, resolve egress mode as **explicit flag > `DEV_EGRESS`
> built-in default**:

1. `--closed` or `--open` on the command line wins.
2. else `DEV_EGRESS=closed` (host env) ⇒ closed; `DEV_EGRESS=open` or unset
   ⇒ open. Any other value is an error (`dev` refuses with a one-line
   message naming the two valid values).
3. else open.

`DEV_EGRESS` joins the documented host-env family (`DEV_RUNTIME`,
`DEV_ASSUME_YES`, `DEV_SHARED_HOME`, `DEV_SKIP_*`, `DEV_EXTRA_RUN_ARGS`).

No repo-side pin. `.devcontainer-allowlist` is merged into the filter in
closed mode exactly as today (subject to the existing host approval gate)
and is simply unused in open mode — documented, not an error.

The resolved mode is passed to the container as `DEVCONTAINER_EGRESS=open|closed`
(host-side `DEV_EGRESS` and container-side `DEVCONTAINER_EGRESS` are distinct
by the existing `DEV_*` vs `DEVCONTAINER_*` convention).

## 3. Firewall mechanics

`firewall-init.sh` gains `install_baseline_blocks()`, run first in **both**
modes: DROP `169.254.0.0/16` on OUTPUT (v4) and `fe80::/10` (v6). Because
rules precede the chain policy, this holds whether the policy is ACCEPT
(open) or DROP (closed). Covers AWS/GCP/Azure/Oracle metadata (all at
169.254.169.254). (Alibaba's 100.100.100.200 is CGNAT-space, out of scope —
noted in a code comment, not blocked by default.)

Guard: if the container's resolver (`/etc/resolv.conf` nameserver) is itself
link-local, exempt that address from the block so DNS still works. Unlikely
on the target hosts, but the block must not break name resolution.

- **Open path** (`DEVCONTAINER_EGRESS=open`): `install_baseline_blocks`, then
  a new-connection log rule (below), then OUTPUT policy ACCEPT (v4+v6). No
  proxy, no filter. entrypoint skips the proxy exports / `proxy.sh` /
  `no-aaaa` / m2+gradle seeding.

**Egress logging (open mode).** Two proxy-free sources, both cheap and
unbypassable:
- New-connection NFLOG: `-A OUTPUT -p tcp --syn -m limit --limit 60/min
  --limit-burst 20 -j NFLOG --nflog-group 2 --nflog-prefix "FW-CONN"` (v4+v6),
  installed before the ACCEPT policy takes over. Group 2 keeps it distinct
  from the link-local drop log (group 1). Records IP:port for every protocol,
  including connections to literal IPs a DNS log would miss.
- DNS-query visibility: not a persistent rule — `dev fw log` reads it live
  (below) via `tcpdump` on port 53, which prints query names (`A? host`).
  tcpdump is already in the image.
Closed mode's richer per-hostname proxy log is unchanged; the connection
NFLOG is open-mode-only (in closed mode the owner-rule already gates egress
and the proxy log is authoritative).
- **Closed path**: today's `firewall-init.sh` body, plus
  `install_baseline_blocks`. entrypoint does today's proxy plumbing.
- **`firewall-disable.sh`** (used by `fw open` and the open cold-start):
  after flushing OUTPUT to ACCEPT, re-install `install_baseline_blocks` so
  the link-local DROP survives the open transition. (Today it flushes clean.)
- **Live toggle**: `fw close` re-runs `firewall-init.sh` in closed mode
  (idempotent — already how enable works); `fw open` runs
  `firewall-disable.sh`. `fw log`/`fw drops` unchanged (in open mode the
  proxy log is absent; `drops` still shows the rare link-local NFLOG hits).

## 4. CLI & entrypoint surface

- `dev up` / `dev exec`: default open. Add `--closed`; keep `--open` as the
  explicit form (also the override when `DEV_EGRESS=closed`). The old
  `--open` semantic ("start with the firewall torn down") is exactly the new
  default, so the flag's meaning is preserved, just no longer special.
- `dev fw open` / `dev fw close` / `dev fw log` / `dev fw drops` — rename of
  `off|on` → `open|close` in `lib/dev/fw.sh` and its usage text. `fw close`
  with a non-existent container errors as `fw on` does today; `fw open` on a
  fresh workspace cold-starts open (as `fw off` does today).
- `dev fw log` is mode-aware: in **closed** mode it tails the tinyproxy
  CONNECT log (today's behavior); in **open** mode it shows the kernel-level
  egress view — `tcpdump` on port 53 (DNS query names) merged with `tcpdump
  -i nflog:2` (the FW-CONN connection log). Same command, right source per
  mode, so an agent/operator runs one thing regardless. `fw drops` stays
  group 1 (link-local + any closed-mode DROPs).
- `dev status` reports egress mode (`open`/`closed`) per container, inferred
  from the running container's state (the existing banner-file check
  distinguishes; extend it to name the mode).
- `entrypoint.sh`: gate the `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` exports,
  `/etc/profile.d/proxy.sh`, the `no-aaaa` resolver edit, and the
  `~/.m2/settings.xml` + `~/.gradle/gradle.properties` seeding behind
  `DEVCONTAINER_EGRESS=closed`. Open mode's entrypoint is markedly simpler.
- Mutually-exclusive-mode guard (normal/maint/dind/pind) is unchanged;
  egress mode is orthogonal (maintenance mode remains firewall-off +
  sudo — unaffected; it never ran the firewall).

## 5. Docs / SECURITY.md reframe

- SECURITY.md: lead with **isolation** as the always-on boundary (no host
  mounts, per-workspace home, no host creds, unprivileged/no-sudo,
  link-local blocked). Present **egress confinement as opt-in hardening**
  (`--closed` / `DEV_EGRESS=closed`). Document the always-on link-local
  block and its rationale. State open mode's accepted residuals honestly:
  an agent can reach arbitrary internet hosts (per the threat model, not a
  concern), and the DNS-to-any channel (known, documented, not fixed).
- README: new top TLDR (the closed-loop-dev framing + one-line install in
  one section) and org-messaging points — "the agent closes the code loop;
  the human owns the environment loop" and "commit inside / push outside is
  a review gate." Call out **egress observability as a key feature** in the
  TLDR/motivation: even wide-open, `dev fw log` shows every host the agent
  reached (DNS names + connections). It's the transparency companion to those
  two points — the human owns the boundary *and* can see what the agent did
  inside it, without having to confine it to get visibility. Update every
  mode/flag/`fw` reference to open/closed and the new default. Update
  `docs/architecture.html` (still shows removed `--maintenance` spellings).
- CLAUDE.md: update the firewall/mode description and the `DEV_EGRESS` env.

## 6. Testing

- `scripts/test/scenarios/50-cli-verbs.sh`: rename fw assertions to
  open/close; add `--closed` parse + `DEV_EGRESS` resolution surface checks.
- New scenario `52-egress-modes.sh` (`platform: linux`): (a) default
  `dev up` reaches a non-allowlisted host (e.g. `example.com`); (b)
  `dev up --closed` blocks it; (c) `DEV_EGRESS=closed dev up` starts closed;
  (d) `dev up --open` overrides `DEV_EGRESS=closed`; (e) the link-local /
  metadata DROP holds in **both** modes (the one genuinely new firewall
  assertion — probe a direct connect to 169.254.169.254 and require it to
  fail open and closed). Follow the correct assertion shape (assert on the
  inner probe's result, not `|| echo` on the outer `dev exec` — see the
  final-review C4 finding). Plus (f): in open mode, after the container makes
  a request to a known host, `dev fw log` surfaces that host (DNS name and/or
  its connection) — asserts the kernel-level observability actually works.
- `scripts/verify-firewall.sh`: add a metadata/link-local DROP probe that
  runs in both modes.
- Full `run-all` matrix green (CI's rootless-linux + vm-matrix cells).

## Out of scope

- The DNS-to-any channel (C2): documented as a residual, not closed here.
- Resource limits (`--memory`/`--pids-limit`): a separate concern for the
  "can't break my machine" story; not part of egress.
- The other final-review / README-audit defects (C1 regex-escape, C4 test
  shape, pind volume migration, doc reconciliations): a separate fix batch,
  already agreed, sequenced around this change.
