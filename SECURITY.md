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
no ambient host credentials, an unprivileged user with no sudo.

This is **containment of agent reach, not exfiltration prevention.** That
holds regardless of egress mode. `dev up` defaults to **open** egress — the
container can reach any host on the internet, the same as a process running
directly on your laptop — because what actually delivers the threat model
above is **isolation** (§2), not a hostname filter: no host mounts beyond
the workspace, no SSH keys or ambient credentials, no privilege escalation
path inside the container. Opening egress does not weaken any of that. A
project that also wants to confine *which* hosts the container can reach can
opt into **closed** mode (`dev up --closed` / `DEV_EGRESS=closed`, §3) —
useful extra hardening, but even then every allowlisted host is fully
reachable and the channel is bidirectional: GitHub, npm, Anthropic's API,
and the rest are ordinary HTTPS endpoints an agent can both push to and pull
from by design (that's how `git push`, `npm publish`, or a Claude API call
works at all). If an agent decides to exfiltrate workspace contents to a
host that is already on the allowlist — e.g. by committing a secret into a
GitHub gist, or pasting it into a prompt sent to Anthropic — closed mode's
firewall does not stop that and was never meant to. What closed mode adds is
narrowing egress to a reviewed set of hosts; what isolation stops in every
mode is the agent reaching host-side material (keys, credentials, history
from other projects) that was never placed in the container to begin with.

See "Deliberate non-goals" (§5) for the boundary of this model, and
"Known sharp edges" (§6) for where the implementation doesn't fully live
up to it yet.

## 2. Isolation: the always-on boundary

This is the boundary that actually protects host secrets, and it does not
change with `--open`/`--closed`/`DEV_EGRESS`. It comes from several
independent properties, all unconditional:

- **No host mounts beyond the workspace bind mount and a read-only allowlist
  snapshot.** The project directory is mounted read-write at `/workspace`
  (agent-writable, and therefore treated as untrusted input — see the
  approval gate in §4). The only other host bind mount is a read-only
  snapshot of the *approved* project allowlist at
  `/etc/devcontainer/project` (`lib/dev/volumes.sh:57`, from a host-side
  state directory outside the workspace — see §4); it carries no secrets,
  just the reviewed extra-hostname list. The host's real `$HOME`, host SSH
  keys, and any host credential store are never mounted.
- **A per-workspace home volume**, isolated so one project's agent can't
  read another project's SSH keys/git config/shell history out of a shared
  home (`DEV_SHARED_HOME=1` opts back into a single shared volume across
  workspaces — an explicit, visible opt-out, not a default).
- **No host credentials copied in** except through the explicit, reviewable
  `dev agent add` / `dev dotfile add` paths (§4), which copy a curated
  allowlist of auth/settings — never a live mount, never a tool's
  cross-project history.
- **`vscode` has no sudo** in normal mode, and no path exists to escalate
  from inside a normal-mode container (the `--maint` escape hatch is
  the one deliberate, opt-in, loudly-bannered exception — §5).
- **An always-on network block on the cloud-metadata / link-local range**,
  in both egress modes: `firewall-init.sh`'s `install_baseline_blocks`
  DROPs `169.254.0.0/16` (IPv4) before either mode's OUTPUT policy is set,
  and the IPv6 mirror re-asserts a `fe80::/10` DROP immediately after
  flushing the `ip6tables` OUTPUT chain, so it survives that flush
  regardless of which policy (ACCEPT or DROP) gets set afterward
  (`firewall-init.sh:59-68`, `226-230`; `firewall-disable.sh:32-37` does the
  same inline for the live open-toggle path). This closes the one network
  path that *would* reach host-adjacent secrets even with every other
  isolation property intact: AWS/GCP/Azure/Oracle all serve instance
  credentials from `169.254.169.254`. (Alibaba's `100.100.100.200` is
  CGNAT space, out of scope, noted in a code comment rather than blocked.)
  The rule set exempts the container's own resolver address if it happens
  to be link-local, so DNS keeps working.

Egress confinement (§3) sits on top of this, not underneath it: closed mode
adds a hostname filter for outbound HTTP(S); it is not what makes any of the
five properties above true.

## 3. Egress modes: open (default) and closed (opt-in hardening)

**Resolution.** `dev up` / `dev exec` pick a mode as explicit flag >
`DEV_EGRESS` host env > built-in default of open (`lib/dev/up.sh:65-69`):
`--open`/`--closed` on the command line wins if given; else `DEV_EGRESS=open`
or unset resolves to open, `DEV_EGRESS=closed` resolves to closed, and any
other value is a hard error. The resolved value is passed into the container
as `DEVCONTAINER_EGRESS=open|closed` (`lib/dev/lifecycle.sh:172-178`).
Maintenance mode never runs the firewall at all regardless of this setting —
passing `--open`/`--closed` alongside `--maint` only prints a warning
(`lib/dev/up.sh:172-177`).

**Both modes**, `firewall-init.sh` runs as root at container start via
`entrypoint.sh`, which fails closed: any non-zero exit aborts container
startup rather than falling through to an unfirewalled shell
(`entrypoint.sh:38-42`). The link-local block (§2) always terminates every
other 169.254.0.0/16 destination (e.g. the cloud metadata endpoint) before
either mode's OUTPUT policy is programmed — see below for the one
deliberate exception open mode carves out of that ordering for its own
DNS logging.

**Open (default).** `firewall-init.sh` installs rate-limited NFLOG rules
that log the first packet (SYN) of every new outbound TCP connection
(`FW-CONN`) and every outbound DNS query (`FW-DNS`, UDP+TCP port 53), all
into the same group 2, *before* the baseline link-local block runs
(`firewall-init.sh:install_egress_logging`, called from both the IPv4 and
IPv6 open branches, ahead of `install_baseline_blocks`). That ordering is
deliberate: `install_baseline_blocks`'s link-local-resolver exemption
unconditionally ACCEPTs port-53 traffic to the container's own resolver
when it happens to be a 169.254.x address — the common case under rootless
podman's pasta/slirp4netns — and ACCEPT is terminating, so a DNS-log rule
installed afterward would never see that traffic. NFLOG is non-terminating
(it logs, then falls through to the next rule), so installing it first only
adds visibility; the baseline block's link-local DROP still terminates
every *other* 169.254.0.0/16 destination exactly as before. After both are
installed, `firewall-init.sh` sets the OUTPUT policy to ACCEPT for both
IPv4 and IPv6. No tinyproxy, no allowlist, no `HTTPS_PROXY`/
`HTTP_PROXY` exports, no `no-aaaa` resolver edit, no Maven/Gradle proxy
seeding — `entrypoint.sh` gates all of that behind closed mode
(`entrypoint.sh:29`, `44-57`, `182`). The container can reach any host on any
port/protocol, proxy-free, the same as a process on the host.

Proxy-free does not mean unobservable: `dev fw log` in open mode runs a
single `tcpdump -i nflog:2` reader over that group-2 feed, so an operator
sees both DNS query names and every new connection's IP:port from one
capture (`lib/dev/fw.sh:fw_log`). NFLOG only needs `CAP_NET_ADMIN`, which the
container already has for iptables; the previous implementation additionally
ran `tcpdump -i any` to catch DNS names, which needs `CAP_NET_RAW` — a
capability the sandbox deliberately withholds, so that half silently failed
with "Operation not permitted" under rootless podman. The ceiling without
terminating TLS is hostname + IP:port, not URLs or request bodies — closed
mode's tinyproxy log remains the richer per-request audit trail. `dev fw
drops` (`tcpdump -i nflog:1`) is closed-mode-only: only the closed branch
installs a group-1 `FW-DROP`/`FW-DROP6` rule; the open branch installs no
group-1 rule at all, so `dev fw
drops` shows nothing in open mode — use `dev fw log` (the group-2
connection + DNS feed, above) for open-mode egress visibility instead. Note
also that the link-local block itself (`install_baseline_blocks`, §2) is a
terminating DROP installed *before* any group-1 rule in either mode, so
link-local packets are discarded silently and never appear in `dev fw drops`
either.

**Closed (opt-in — `--closed` / `DEV_EGRESS=closed`).** Unchanged from the
allowlist-firewall behavior this repo has always shipped: default-DROP
OUTPUT (v4+v6), only the `proxy` system uid may reach 80/443 directly, and a
tinyproxy hostname filter built from `allowlist.base` + the *approved*
project snapshot (never the live `/workspace` copy — see §4's approval gate)
+, only when `--dind`/`--pind` is also active, `allowlist.dind`
(`firewall-init.sh:101-214`). Refuses to start on an empty filter or an
unfilterable global IPv6 address. `dev fw close` re-runs `firewall-init.sh`
in place to rebuild the filter and restore default-DROP
(`lib/dev/fw.sh:106-110`); `dev fw open` on an already-running closed
container execs `firewall-disable.sh`, which flushes OUTPUT to ACCEPT,
re-asserts the link-local block, and — since tinyproxy is already running in
that container — flips its filter to allow-all and reloads it rather than
stopping the process, so clients still pointed at the proxy keep working
too (`firewall-disable.sh:26-46`). That is a slightly different code path
from a fresh open cold-start (which never starts tinyproxy at all), but the
net result is the same egress-everywhere-except-link-local posture.

**`allowlist.base` / `allowlist.dind`** define the closed-mode egress
universe. Read both end to end — they're short. `allowlist.base`'s own
comment states the property to check: no wildcard broader than a vendor's
own registry/CDN subdomain set (`allowlist.base:5-6`), and every entry there
holds to it. `allowlist.dind` (merged only under `--dind`/`--pind`) does
**not** fully hold that line: `*.cloudfront.net` and
`*.r2.cloudflarestorage.com` (`allowlist.dind:21`, `25`) are multi-tenant
CDN domains — arbitrary AWS CloudFront or Cloudflare R2 customers can have a
matching subdomain, not just Docker Hub. They're there because Docker Hub
fronts image blob downloads through vendor-assigned CDN subdomains this
project doesn't control, and there was no narrower way to allow the pulls
`--dind`/`--pind` need. Call this what it is — a wildcard broader than "a
single registry's own subdomain set" — rather than claiming the stricter
property applies uniformly; tightening it (e.g. pinning the specific
distribution hostnames Docker Hub actually uses) is open work, not something
already done.

**Accepted residuals of open mode (the default) — stated honestly:**

1. **An agent can reach arbitrary internet hosts**, not just a reviewed
   allowlist. Per §1, this is accepted, not an oversight: egress
   confinement never protected host secrets (isolation, §2, does), and even
   under closed mode every allowlisted host was already bidirectionally
   reachable. A project that wants the narrower reach back opts into
   `--closed` / `DEV_EGRESS=closed`.
2. **DNS-to-any is a known residual, not fixed here, in both modes.**
   `firewall-init.sh` ACCEPTs `udp`/`tcp` port 53 to *any* destination —
   in open mode as part of the general ACCEPT policy, and, just as much,
   in closed mode's own explicit rules
   (`firewall-init.sh:179-180` IPv4, `237-238` IPv6): DNS was never routed
   through tinyproxy's hostname filter, so a process can query (or tunnel
   data through queries to) any resolver on the internet regardless of
   which egress mode is active or what the allowlist says. Closed mode's
   allowlist confines HTTP(S) CONNECT traffic; it never confined DNS
   lookups themselves. This is a real side channel, documented here as a
   known gap rather than something either mode closes.

## 4. Reading order for a first review

1. **`Dockerfile`** — establishes the trust boundary at build time: no
   sudo for `vscode`, the `dc-tinyproxy` rename, the `proxy` user, and
   which scripts get baked in read-only (`firewall-init.sh`,
   `firewall-disable.sh`, `allowlist.base`).
2. **`entrypoint.sh`** — establishes it at container-start time: fail-closed
   firewall bring-up (both egress modes), seed-never-overwrite semantics
   for anything that touches the home volume, and where the
   `DEVCONTAINER_EGRESS`-gated proxy/resolver/JVM plumbing lives.
3. **`firewall-init.sh`** — the actual enforcement, bimodal: the always-on
   link-local block, then either the open-mode ACCEPT policy + connection
   logging, or the closed-mode default-DROP + owner-uid + allowlist path,
   plus the IPv6 mirror either way.
4. **`allowlist.base` / `allowlist.dind`** — the egress universe closed
   mode's rules are built from (open mode does not consult either file).
5. **`lib/dev/container.sh` + `lib/dev/volumes.sh` + `lib/dev/inject.sh` +
   `lib/dev/lifecycle.sh`** (the CLI mount/exec/runtime-flag surface) —
   what `dev` puts inside the container and which kernel capabilities it
   hands it, since a perfect firewall doesn't help if the mount surface or
   the container's runtime flags leak host secrets or capability:
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
   - **Runtime flags** (`start_container` in `lifecycle.sh`): always adds
     `--cap-add=NET_ADMIN` (needed by `firewall-init.sh` to program
     iptables in either egress mode) and, on rootless podman,
     `--userns=keep-id`. Under `--dind`/`--pind` it additionally adds
     `/dev/fuse` and `/dev/net/tun`, `--cap-add=SYS_ADMIN`, and disables
     AppArmor/seccomp/systempaths confinement for the nested-engine
     process — a real widening of the container's default capability set,
     scoped to the nested-engine modes and documented inline with the
     specific kernel error each relaxation avoids
     (`lifecycle.sh:67-97`). `--host-port` adds a single per-port iptables
     ACCEPT against the host gateway only, installed before the link-local
     DROP because pasta's gateway is itself link-local; loopback
     resolutions are skipped and the cloud metadata IP is refused, so the
     hole can never widen the metadata block (`lifecycle.sh:120-129`,
     `install_host_port_holes` in `firewall-init.sh`). See §6 for `DEV_EXTRA_RUN_ARGS`, the one
     knob in this file that can inject flags well beyond any of the above.
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

## 5. Deliberate non-goals

- **Exfiltration via an allowlisted (closed mode) or arbitrary (open mode)
  host.** If a host is reachable, it is reachable for both directions of a
  normal HTTPS conversation. Neither egress mode distinguishes "clone a
  repo" from "push workspace contents to a repo" — closed mode's
  hostname filter structurally cannot make that distinction at the layer
  it operates at, and open mode does not filter destinations at all.
  Keeping a closed-mode allowlist short and reviewing
  `.devcontainer-allowlist` additions (§ approval gate) is the mitigation
  available to projects that opt into closed mode; it was never a
  technical block, and open mode (the default) does not attempt it.
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
  disables the firewall (regardless of egress mode) and re-grants `vscode`
  sudo, for tasks that genuinely need unrestricted egress or system package
  installs (see `entrypoint.sh`'s `DEVCONTAINER_MAINTENANCE` block). This
  is documented, opt-in (a distinctly-named `-maint` container, never the
  default), and banners loudly on every shell (`zz-maint-banner.sh`). It is
  a known, visible hole, not a bug.

## 6. Known sharp edges

- **`DEV_EXTRA_RUN_ARGS` bypasses the isolation boundary, not just
  egress.** It's a host env var, documented in `CLAUDE.md`, meant for
  legitimate escape-hatch uses (e.g. injecting `--dns=...` on a host with a
  broken resolver). `lifecycle.sh` word-splits it and appends the result
  directly to the `docker run`/`podman run` invocation with no filtering
  (`lifecycle.sh:142-149`). Nothing stops a value that carries
  `--privileged`, `-v /:/host`, `--cap-add=ALL`, `--network=host`, or any
  other flag that defeats §2's isolation properties outright — this is
  orthogonal to egress mode, and neither `--closed` nor any firewall
  setting mitigates it. Treat it like a root-equivalent host knob: set it
  only to a trusted, reviewed value, and never let agent-controlled input
  populate it.
- **Host AppArmor interactions.** On some hosts a system AppArmor profile
  attached to the `tinyproxy` binary path would confine the *container's*
  tinyproxy under rootless runtimes too (profiles attach by path and that
  attachment crosses the container boundary), breaking closed mode's
  fail-closed startup. The `dc-tinyproxy` rename in the Dockerfile
  sidesteps this by using a path no host profile matches — but that means
  the mitigation is "no profile happens to match this path" rather than an
  explicit exemption; a host-side profile written broadly enough (e.g. by
  binary hash, or covering `/usr/local/sbin/*`) could still catch it. If
  `--dind`/`--pind` won't start, check
  `kernel.apparmor_restrict_unprivileged_userns` first (the preflight
  documented in `README.md` / `CLAUDE.md`).
- **IPv6 posture.** IPv6 egress is mirrored to the same policy as IPv4 in
  both modes (added after an earlier fix-pack — some runtimes, notably
  podman 5's pasta backend, hand the container a global IPv6 default
  route by default, which would otherwise bypass an IPv4-only firewall
  entirely). `firewall-init.sh` refuses to start if it cannot program
  `ip6tables` *and* a global IPv6 address is present. Worth re-verifying
  after any runtime/kernel upgrade that changes how IPv6 addressing is
  handed to containers — this is exactly the class of regression the
  mirror was added to close.
- **`DEV_ASSUME_YES=1` waives the project-allowlist review (closed mode
  only).** Normally `dev` diffs `.devcontainer-allowlist` (agent-writable,
  inside `/workspace`) against a host-side approved snapshot and prompts
  before merging any change into the closed-mode firewall
  (`lib/dev/approval.sh`). Setting `DEV_ASSUME_YES=1` — intended for
  CI/non-interactive rebuild prompts — auto-approves allowlist changes
  without pausing for confirmation: the diff is still printed to stderr
  unconditionally (`lib/dev/approval.sh` runs `diff -u` before it even
  checks `DEV_ASSUME_YES`), but nothing waits for a human to actually read
  it in a non-interactive context. An agent that can persuade a
  `DEV_ASSUME_YES=1` environment to restart the container effectively gets
  to add its own allowlist entries with no one reviewing the printed diff.
  Don't set it globally in an environment where an agent controls the
  workspace contents; set it only for the specific non-interactive prompts
  it's meant for. (Irrelevant when the workspace runs in open mode, where
  the allowlist isn't consulted at all.)
