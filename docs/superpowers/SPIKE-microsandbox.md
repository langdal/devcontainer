# SPIKE: microsandbox v0.5 syntax confirmation (Task 0 for `box`)

Exploratory spike. Ran real `msb` commands on this host and recorded exactly
what works, so later `box` tasks build on confirmed syntax rather than guesses.

## Environment

- Host: Linux 6.8 x86_64, nested-KVM guest.
- `/dev/kvm` present, user in `kvm` group.
- Date run: 2026-06-15.
- microsandbox was NOT pre-installed; installed during this spike.

## Summary verdict

**Status: DONE.** Every plan step succeeded on this nested-KVM host. VMs boot,
bind mounts are two-way, deny-by-default egress + domain allowlist works, secret
injection is leak-proof (placeholder in guest, real value substituted on-wire),
and the named-sandbox lifecycle (`run -d` / `ps` / `exec` / `stop` / `rm`) works.

Several CLI details differ from the plan's assumptions — see per-step notes.
The most important divergence is the **secret placeholder format** (Step 4).

---

## Step 1: Install + version

Command used (verbatim):

```sh
curl -fsSL https://install.microsandbox.dev | sh
```

Result: installed `msb 0.5.7`. Matches the plan's "v0.5.x" assumption.

Install details worth recording:
- Installs to `~/.microsandbox/bin/msb`, symlinks into `~/.local/bin/`
  (`msb` and `microsandbox`). **`~/.local/bin` must be on `PATH`** — it was not
  exported in this non-login shell, so every command below ran with
  `export PATH="$HOME/.local/bin:$PATH"` first. `box` should not assume `msb`
  is on the default PATH.
- Ships a bundled `libkrunfw` (v5.2.1) into `~/.microsandbox/lib/`.
- Linux release bundles are built on Ubuntu 24.04 (glibc 2.39 min). This host
  is glibc 2.39 — exactly at the floor. Older hosts will fail.

### Daemon: NONE required

**There is no daemon to start.** `msb run` boots the microVM directly via
libkrun; `ps aux | grep -E 'msb|microsandbox|krun'` showed no persistent
process between commands. This differs from the plan's "if the installer needs
a daemon, start it" contingency — no daemon, no `msbserver`, nothing to manage.
(`msb self` only has `update`/`uninstall`; there is no `start`/`daemon`
subcommand.)

---

## Step 2: Boot + two-way bind mount

Command (verbatim, plan syntax — worked unmodified):

```sh
tmp="$(mktemp -d)"; echo host-wrote-this > "$tmp/from-host"
msb run --mount-dir "$tmp:/workspace" mcr.microsoft.com/devcontainers/base:ubuntu \
  -- bash -lc 'cat /workspace/from-host && echo guest-wrote-this > /workspace/from-guest'
cat "$tmp/from-guest"
```

Output:
```
host-wrote-this        # guest read the host's file
guest-wrote-this       # host read the guest's file back
```

**Matches the plan exactly.** `--mount-dir SOURCE:DEST` is correct and bind
mounts are read-write two-way. (Help also documents `:OPTIONS` suffix and
sibling flags `--volume/-v`, `--mount-file`, `--mount-named`, `--mount-disk`.)

VMs boot fine despite nested KVM — no rough edges observed.

---

## Step 3: Deny-by-default egress + domain allowlist  (KEY UNKNOWN — RESOLVED)

The plan's command worked, but with caveats. Confirmed working form:

```sh
msb run --net-default-egress deny --net-rule "allow@github.com:tcp:443" \
  mcr.microsoft.com/devcontainers/base:ubuntu \
  -- bash -lc 'curl ... https://github.com ; curl ... https://example.com'
```

Output: `github:200`, `example:000` + `Could not resolve host: example.com`.
**github reachable, example blocked.** Matches plan intent.

### net-rule grammar (verbatim from `msb run --help`)

```
<action>[:<direction>]@<target>[:<proto>[:<ports>]]
```

- `<action>`: `allow` | `deny`
- `<direction>` (optional): `ingress` | `egress`
- `<target>`: IP/CIDR, domain (`example.com`), domain suffix
  (`*.example.com` or `suffix=example.com`), or group (`public`, `private`,
  `multicast`, ...). **Suffixes must be ≥2 labels** (`*.example.com` ok,
  `*.com` rejected).
- `<proto>`: `tcp` | `udp`
- `<ports>`: e.g. `443`
- Repeatable; one `--net-rule` value may be a comma-separated list of tokens.

### CONFIRMED WORKING DOMAIN RULE STRING

```
allow@github.com:tcp:443
```

### CONFIRMED WILDCARD FORM

```
allow@*.github.com:tcp:443
```

**Wildcard behavior (tested, important):** `*.github.com` matched BOTH
`api.github.com` AND the apex `github.com` (both returned 200), while an
unrelated `example.com` was blocked. So `*.foo.com` = "foo.com and all its
subdomains" (suffix match includes the apex), NOT "subdomains only". If `box`
needs only subdomains it cannot rely on the wildcard to exclude the apex.

### DIVERGENCE from plan: the `allow@host:udp:53` DNS token is NOT needed

The plan included `allow@host:udp:53` to permit DNS. **Dropping it changed
nothing** — `allow@github.com:tcp:443` alone still resolved and reached github.
microsandbox resolves domain-based rules itself (out of band); the guest does
not need an explicit DNS egress rule. Also note `host` is not a documented
target kind (the documented groups are `public`/`private`/`multicast`/...), so
`allow@host:...` is best avoided. **Recommendation for `box`: omit the DNS
rule; just list the allowed domains.**

Note: a blocked domain fails at DNS resolution inside the guest
(`Could not resolve host`), which is a clean, greppable deny signal.

### Other relevant egress flags

- `--net-default <ACTION>` sets egress+ingress symmetrically.
- `--net-default-egress <ACTION>` / `--net-default-ingress <ACTION>`
  independently. Default egress is `deny` *but with an implicit `allow@public`
  when no rules are present* — so you MUST pass `--net-default-egress deny`
  together with explicit `--net-rule allow@...` entries to get a real
  allowlist. (Confirmed: the combination yields a true allowlist.)
- `--no-net` is sugar for `--net-default deny` (no reachability at all).

---

## Step 4: Leak-proof secret injection  (placeholder format — RESOLVED, DIFFERS FROM PLAN)

Command (plan `--secret` syntax — worked):

```sh
export SPIKE_TOKEN="super-secret-value"
msb run --secret "SPIKE_TOKEN@api.github.com" mcr.microsoft.com/devcontainers/base:ubuntu \
  -- bash -lc 'echo "$SPIKE_TOKEN"; env | grep -i spike'
```

Guest output:
```
guest sees SPIKE_TOKEN: [$MSB_SPIKE_TOKEN]
MSB_SPIKE_TOKEN: []
SPIKE_TOKEN=$MSB_SPIKE_TOKEN
```

The real value `super-secret-value` is NOT visible in the guest. **Leak-proof
confirmed.**

### CONFIRMED PLACEHOLDER FORMAT (differs from plan's assumption)

- The env var **keeps its original name** `SPIKE_TOKEN` (the plan assumed it
  would be renamed to `MSB_SPIKE_TOKEN` — it is NOT renamed).
- Its **value is the literal string** `$MSB_SPIKE_TOKEN` (a literal 6+10 char
  string with a leading `$`, NOT an expanded shell variable — there is no real
  variable named `MSB_SPIKE_TOKEN`, so `echo "$MSB_SPIKE_TOKEN"` prints empty).
- Pattern: for `--secret NAME@HOST`, guest sees `NAME=$MSB_<NAME>` literally.

So the placeholder a `box`-launched agent observes for secret `FOO` is the
literal text `$MSB_FOO`, exposed in env var `FOO`.

### CONFIRMED --secret syntax

```
--secret ENV@HOST            # value pulled from host env var of same name
--secret ENV=VALUE@HOST      # value supplied inline (also supported per --help)
```

### On-wire substitution VERIFIED

With `--secret SPIKE_TOKEN@api.github.com` + an allow rule, running
`curl -H "Authorization: Bearer $SPIKE_TOKEN" https://api.github.com/user`
reached GitHub and got **HTTP 401** — i.e. the placeholder was substituted with
the (fake) real value on the wire to the allowed host and GitHub rejected the
fake token. Proves the substitution happens transparently for outbound requests
to the whitelisted host only.

Related flag: `--on-secret-violation <block|block-and-log|block-and-terminate|passthrough>`
controls what happens if the secret would be sent to a non-allowed host.

---

## Step 5: Named-sandbox lifecycle + ps output  (RESOLVED, minor divergences)

The plan used `msb run --name spike-box ... -- 'sleep 30' &` (shell
backgrounding). The clean way is `-d/--detach`:

```sh
msb run -d --name spike-box mcr.microsoft.com/devcontainers/base:ubuntu
# ... (note: command after -- is IGNORED in --detach mode; see below)
msb ps
msb exec spike-box -- echo "attached ok"
msb stop spike-box
msb rm spike-box
```

### DIVERGENCE: `-- <command>` is ignored in `--detach` mode

`msb run -d --name X IMAGE -- bash -lc 'sleep 60'` printed:
```
warn: command after -- is not run in --detach mode; sandbox 'spike-box'
is running in the background (use `msb exec spike-box -- ...`)
```
A detached sandbox boots the image default (`/bin/bash`) and **stays alive on
its own** (no need for a `sleep` keepalive). Use `msb exec` to run work in it.
For `box`, the pattern is: `msb run -d --name <box>` to launch, then
`msb exec <box> -- <agent command>`.

### `exec` confirmed

```
msb exec <NAME> -- <command>
```
`msb exec spike-box -- echo "attached ok"` printed `attached ok`, exit 0.
(`-t/--tty` available for interactive attach; bare `msb exec <NAME>` with no
command attaches the default shell.)

### CONFIRMED `ps` OUTPUT FORMAT

`ps` is an **alias for `status`** (and `ls` is an alias for `list`).

Default table (`msb ps`):
```
NAME         IMAGE                                   COMMAND        STATUS     PORTS
spike-box    mcr.microsoft.com/devcontainers/b...    "/bin/bash"    running    -
```
- Header row always present.
- IMAGE is **truncated with `...`** in the table — do not match on full image.
- STATUS is lowercase `running` in the table.
- When nothing runs, prints exactly: `No running sandboxes.`

**For scripting, prefer the structured outputs over grepping the table:**

`msb ps -q` (or `--quiet`) — one sandbox name per line, nothing else:
```
spike-box
```

`msb ps --format json` — machine-readable (note STATUS is capitalized
`Running` in JSON, lowercase in the table):
```json
[
  {
    "command": "\"/bin/bash\"",
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "name": "spike-box",
    "ports": [],
    "status": "Running"
  }
]
```

`msb ps -a` / `--all` includes stopped sandboxes too (default shows only
running). **Recommendation for `box`:** detect a running sandbox with
`msb ps -q | grep -Fxq "<name>"` or parse `--format json` (status `Running`),
not by grepping the human table.

Teardown: `msb stop <name>` then `msb rm <name>` both exit 0 and clean state;
`msb ps` afterward shows `No running sandboxes.`

---

## Quick reference for later `box` tasks (confirmed strings)

| Concern | Confirmed value |
| --- | --- |
| Version | `msb 0.5.7` |
| Daemon | none (direct libkrun; nothing to start) |
| PATH | needs `~/.local/bin` on PATH |
| Bind mount | `--mount-dir HOST:GUEST` (two-way RW) |
| Deny egress + allow domain | `--net-default-egress deny --net-rule "allow@example.com:tcp:443"` |
| Wildcard | `allow@*.example.com:tcp:443` (matches apex + subdomains; ≥2 labels) |
| DNS rule | NOT needed (omit `allow@...udp:53`) |
| Secret inject | `--secret NAME@HOST` (or `NAME=VALUE@HOST`) |
| Secret placeholder in guest | env `NAME` holds literal string `$MSB_NAME` |
| Launch named bg sandbox | `msb run -d --name <box> <image>` (then `msb exec`) |
| Run in running sandbox | `msb exec <name> -- <cmd>` |
| Detect running | `msb ps -q \| grep -Fxq <name>` or `msb ps --format json` |
| Stop / remove | `msb stop <name>` ; `msb rm <name>` |
