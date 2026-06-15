# E2E: `box` on real microsandbox microVMs (Task 9)

LIVE end-to-end validation of the `box` prototype against real microsandbox
(`msb 0.5.7`) microVMs — **no `BOX_DRY_RUN`**. The point of this task was not
to run the happy path but to find and FIX the integration issues that only show
up against real VMs, then re-run until the core loop genuinely works.

## Environment

- Host: Linux 6.8 x86_64 (nested-KVM guest), `/dev/kvm` present.
- `msb` at `~/.local/bin/msb` (v0.5.7); `export PATH="$HOME/.local/bin:$PATH"`
  required (matches SPIKE finding — `~/.local/bin` not on default PATH).
- `box` at repo root; scratch project `/tmp/box-demo` with
  `mise.toml` declaring `jq = "latest"`.
- Date run: 2026-06-15.

## Summary verdict

**Status: DONE.** All five validation steps pass on real microVMs. Three
integration bugs were found and fixed in `lib/msb.sh` (no `msb` syntax leaked
into `box`). One cosmetic issue (mise version-check warnings) is documented as
a non-blocking limitation.

---

## Bugs found and fixed (all in `lib/msb.sh`)

### Fix 1 — `box down` + re-run silently kept STALE boot flags  →  `--replace`

**Symptom.** `box down` runs `msb stop` only, which leaves a *stopped* sandbox
of the same name. The next `box` run calls `msb run -d --name box-<dir> ...`,
and `msb` prints:

```
warn: sandbox 'box-box-demo' already exists; creation flags ignored
(use --replace to recreate)
```

It restarts the stopped sandbox with its **original** flags and ignores the new
mounts / net rules / secrets. This breaks the whole "edit `.box-allowlist`,
`box down`, re-run picks up the new rule" workflow (Steps 4 & 5 would have
falsely failed/passed against stale rules).

**Fix.** `msb_up` now boots with `run -d --replace --name ...`. `box` only calls
`msb_up` when the sandbox is *not running* (a stopped-or-absent sandbox), so
`--replace` always forces a fresh boot that applies the current
allowlist/secrets. Verified safe: `--replace` on a stopped sandbox re-creates
cleanly (exit 0).

### Fix 2 — mise + project tools not on PATH at run time  →  inject `--env`

**Symptom.** `box -- bash -lc 'mise --version; jq --version'` printed
`bash: mise: command not found`, and the `jq` it *did* find was `/usr/bin/jq`
(the pre-installed system jq) — **not** the mise-managed `jq` from the volume.
Provision installs mise to `/mise/bin` and tools into the `box-mise` volume, but
the exec'd shell had only the stock PATH (`/usr/local/sbin:...:/bin`) and no
`/mise/...` entries, so the project toolchain was effectively invisible.

**Root-cause detail (the interesting part).** `msb exec` runs as **root**, whose
`HOME` is `/root` in the *ephemeral* guest rootfs — NOT the persistent
`box-home` volume mounted at `/home/vscode`. So the plan's original idea (seed
`mise activate` into `/home/vscode/.bashrc`) does not help a root shell. I first
tried running exec as `--user vscode` so the seeded rc would be sourced — but
that exposed Fix-3's tension (see below): the `/workspace` bind mount is owned
by **guest-root** (the host user maps to guest-root inside the VM), so a uid-1000
`vscode` process cannot WRITE the workspace (`Permission denied`).

**Fix (clean resolution of the tension).** Keep exec running as **root** (so the
workspace is writable and writes map back to the host user) and inject the mise
environment directly via `msb exec --env`:

```
PATH=/mise/shims:/mise/bin:/usr/local/sbin:...:/bin
MISE_DATA_DIR=/mise  MISE_CONFIG_DIR=/mise  MISE_CACHE_DIR=/mise/cache
```

Because the `box-mise` volume (`/mise`) persists the real mise binary and shims,
PATH alone makes `mise` and every mise-managed tool resolve in a non-interactive
`bash -lc` — no `mise activate`, no rc files, nothing in the ephemeral rootfs.
This is `msb_mise_env_args` / `msb_attach` in `lib/msb.sh`. (Confirmed a login
shell preserves the injected PATH; msb only prepends its own `/.msb/scripts`.)
The earlier rc-seeding code added during debugging was removed as redundant.

### Fix 3 — workspace write permission (resolved by Fix 2's "stay root")

The `/workspace` bind mount appears owned by uid 0 (guest-root) inside the VM
even though it is uid 1000 on the host; microsandbox maps the host user to
guest-root. A root guest process writes fine and the file lands on the host
owned by the host user (verified: `from-guest` round-trips, host owns it).
Running as a non-root guest user would break workspace writes — hence Fix 2
deliberately keeps exec as root rather than switching to `vscode`.

### Tests updated

`tests/unit/test-msb-run.sh` and `tests/unit/test-box-cli.sh` assertions were
updated to match the new (correct) command strings: `run -d --replace --name`
and the injected `--env PATH=/mise/shims:/mise/bin:...` on exec. Full suite
green: `bash tests/run.sh` → **ALL TESTS PASSED** (33 assertions).

---

## Validation steps (actual output)

### Step 1 — Provision   ✅ PASS

`box provision` — image present, mise installs into the `box-mise` volume,
`mise install` pulls `jq` per the project `mise.toml`, exits 0.

```
mise: installed successfully to /mise/bin/mise
mise jq@1.8.1      ✓ installed
provision exit=0
```

**Duration: ~13.6 s** (warm image cache; three runs: 14.4 s, 13.6 s, 13.6 s).

### Step 2 — Core loop (mount + mise + shell)   ✅ PASS

```
$ box -- bash -lc 'echo from-guest > /workspace/touched.txt; mise --version; jq --version'
mise: 2026.6.10 linux-x64 (2026-06-14)
jq path: /mise/shims/jq          # mise-managed jq, NOT /usr/bin/jq
jq: jq-1.8.1
$ cat /tmp/box-demo/touched.txt
from-guest                        # host sees the guest's write (two-way mount)
```

Persisted mise tools resolve; bind mount is two-way. (Cosmetic `mise WARN`
lines about `mise.en.dev/VERSION` appear on stderr — see Limitations.)

### Step 3 — Egress allowlist   ✅ PASS

```
$ box -- bash -lc 'curl ... https://github.com ; curl ... https://example.com'
github:200
evil:000
evil:BLOCKED
curl: (6) Could not resolve host: example.com
```

Allowlisted `github.com` reachable; `example.com` blocked at DNS (clean deny).

### Step 4 — Per-project allowlist addition   ✅ PASS

```
$ echo 'example.com' > .box-allowlist
$ box down                       # ✓ Stopped box-box-demo
$ box -- bash -lc 'curl ... https://example.com'
example:200                      # now reachable after fresh boot
$ rm .box-allowlist
```

Confirms Fix 1: without `--replace` the re-boot would have reused the old
(no-example.com) rules and this would still be BLOCKED.

**Documented behaviour:** the allowlist is applied at sandbox **BOOT**
(`msb_up`). A sandbox that is **already running** does NOT pick up
`.box-allowlist` / `.box-secrets` changes until it is restarted. You must
`box down` (stop) and re-run so the next boot applies the new rules.

### Step 5 — Leak-proof secret   ✅ PASS

```
$ echo 'DEMO_TOKEN api.github.com' > .box-secrets
$ export DEMO_TOKEN="real-secret-xyz"
$ box down                       # fresh boot to apply the secret
$ box -- bash -lc 'echo "guest-sees: $DEMO_TOKEN"'
guest-sees: $MSB_DEMO_TOKEN      # literal placeholder, NOT real-secret-xyz
$ rm .box-secrets
```

The guest never sees the real value `real-secret-xyz`; it sees the literal
placeholder `$MSB_DEMO_TOKEN` (matches the SPIKE finding: env keeps its name,
value is the literal `$MSB_<NAME>`). Absence of the real value = PASS.

Cleanup: `box down` + `msb rm box-box-demo`.

---

## Limitations / non-blocking issues

- **mise version-check warnings.** On every `mise` invocation the guest emits
  3 retrying `mise WARN HTTP GET https://mise.en.dev/VERSION ... failed`
  lines on **stderr**. This is mise's self-update version check hitting a host
  that is (correctly) not on the allowlist. It is purely cosmetic — tool
  resolution and exit codes are unaffected (`mise --version` and `jq --version`
  print correctly). `MISE_VERSION_CHECK`, `MISE_NO_VERSION_CHECK`, and
  `MISE_CHECK_FOR_UPDATES` were all tried and did NOT suppress it on mise
  2026.6.10. Left as-is rather than allowlisting an undocumented host or
  hard-coding a mise-internal disable; revisit if the noise becomes a problem.

- **Provision staleness marker.** Pre-existing `box` TODO: the
  `.provisioned` marker can go stale if the named volumes are removed outside
  `box reset`. Not in scope for this task.
