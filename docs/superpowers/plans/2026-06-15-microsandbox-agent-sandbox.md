# microsandbox agent-sandbox (`box`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single-command bash tool (`box`) that runs a coding agent inside a hardware-isolated microsandbox microVM — workspace bind-mounted live, mise tools persisted, egress allowlist enforced — replacing the old container + iptables/tinyproxy stack.

**Architecture:** Two-file wrapper. `box` owns UX/arg-parsing/allowlist-merge and contains zero microsandbox syntax; `lib/msb.sh` is the only file that knows `msb`. Pure helpers (`lib/allowlist.sh`, `lib/secrets.sh`) are unit-tested directly; command construction is tested via a `BOX_DRY_RUN=1` seam that makes every `msb` call print instead of execute. State persists in two microsandbox named volumes (`box-mise`, `box-home`); the workspace is a two-way bind mount. A `provision` phase (egress open) populates the volumes once; `run` (egress locked) reuses them.

**Tech Stack:** Bash, microsandbox `msb` CLI (v0.5.x), mise. Tests are plain bash (no new dependency), runnable via `bash tests/run.sh`.

---

## Important context for the implementer

- microsandbox is **beta (v0.5.x)**. **Task 0 is a mandatory spike** that confirms the exact `msb` syntax this plan assumes (net-rule for a domain, `msb ps` output format, secret placeholder behaviour, mount flags). The plan encodes the documented best-guess syntax in **one function each** inside `lib/msb.sh`; if the spike finds a difference, you change only that function. Do not skip Task 0.
- The **test seam** is `BOX_DRY_RUN=1`: when set, the `_msb` runner in `lib/msb.sh` prints `msb <args...>` to stdout instead of executing. All command-construction tests assert that printed output — no real VM and no fake binary needed.
- `BOX_ASSUME_PROVISIONED=1` skips the auto-provision check (so dispatch tests don't try to provision).
- Container user is `vscode` (uid 1000, home `/home/vscode`) — that is the user in `mcr.microsoft.com/devcontainers/base:ubuntu`.
- Commit after **every task** (operator request). Commits are unsigned in this sandbox per repo policy: use `git -c commit.gpgsign=false commit`. Conventional Commits style.
- Each `msb_*` function emits arguments **one token per line** so callers read them into arrays with `mapfile -t`. This avoids word-splitting bugs with paths/rules.

## File structure

| File | Responsibility |
|---|---|
| `box` | CLI entrypoint: arg parsing, subcommand dispatch, allowlist merge, provision orchestration, user messaging. No `msb` syntax. |
| `lib/msb.sh` | The microsandbox boundary. `_msb` runner + `msb_net_args`, `msb_mount_args`, `msb_secret_args`, `msb_is_running`, `msb_start_run`, `msb_attach`, `msb_provision`. Only file that names `msb`. |
| `lib/allowlist.sh` | `allowlist_merge` — generic file merge/dedup. No `msb` syntax. |
| `lib/secrets.sh` | `secrets_parse` — read `.box-secrets` into `ENV@host` tokens. No `msb` syntax. |
| `allowlist.default` | Baked default egress allowlist (ported from `allowlist.base`). |
| `mise.base.toml` | Base tools installed at provision time. |
| `tests/lib/harness.sh` | `assert_eq`, `assert_contains`, `finish`. |
| `tests/run.sh` | Runs every `tests/unit/*.sh`, aggregates pass/fail. |
| `tests/unit/*.sh` | Unit tests (one file per component). |
| `docs/superpowers/SPIKE-microsandbox.md` | Task 0 findings: confirmed syntax. |
| `README.box.md` | Prototype usage doc. |
| `TODO.box.md` | Deferred slices 4–5. |

> The legacy files (`dev`, `Dockerfile`, `entrypoint.sh`, `firewall-*.sh`, `allowlist.base`, etc.) stay untouched on this branch until the prototype is validated. Removing them is a documented post-validation step (Task 10), not part of the build.

---

### Task 0: Install spike & syntax confirmation

**Files:**
- Create: `docs/superpowers/SPIKE-microsandbox.md`

This task is exploratory (no automated test). Its output is the confirmed syntax that later tasks depend on.

- [ ] **Step 1: Install microsandbox**

Run:
```bash
curl -fsSL https://install.microsandbox.dev | sh
msb --version
```
Expected: prints a `v0.5.x` version. If the installer needs a daemon, start it per its instructions and record how in the spike doc.

- [ ] **Step 2: Confirm boot + two-way bind mount**

Run:
```bash
tmp="$(mktemp -d)"; echo host-wrote-this > "$tmp/from-host"
msb run --mount-dir "$tmp:/workspace" mcr.microsoft.com/devcontainers/base:ubuntu \
  -- bash -lc 'cat /workspace/from-host && echo guest-wrote-this > /workspace/from-guest'
cat "$tmp/from-guest"
```
Expected: guest prints `host-wrote-this`; host then prints `guest-wrote-this`. Confirms two-way mount and the exact `--mount-dir` syntax.

- [ ] **Step 3: Confirm deny-by-default egress + one allowed domain**

Run (adjust the rule syntax until it works — this is the key unknown):
```bash
msb run --net-default-egress deny --net-rule "allow@host:udp:53,allow@github.com:tcp:443" \
  mcr.microsoft.com/devcontainers/base:ubuntu \
  -- bash -lc 'curl -sS -o /dev/null -w "github:%{http_code}\n" https://github.com; \
               curl -sS -o /dev/null -w "example:%{http_code}\n" https://example.com || echo "example:BLOCKED"'
```
Expected: `github:` returns a real HTTP code; `example:` is blocked. **Record the exact working rule string for a domain** (esp. how wildcards like `*.foo.com` must be written) in the spike doc.

- [ ] **Step 4: Confirm leak-proof secret injection**

Run:
```bash
export SPIKE_TOKEN="super-secret-value"
msb run --secret "SPIKE_TOKEN@api.github.com" mcr.microsoft.com/devcontainers/base:ubuntu \
  -- bash -lc 'echo "guest sees: $SPIKE_TOKEN"; echo "placeholder var: $MSB_SPIKE_TOKEN"'
```
Expected: the guest does **not** print `super-secret-value`; it prints a placeholder (e.g. `$MSB_SPIKE_TOKEN`). Record the exact placeholder format and the `--secret` syntax.

- [ ] **Step 5: Confirm named-sandbox lifecycle + `ps` output**

Run:
```bash
msb run --name spike-box mcr.microsoft.com/devcontainers/base:ubuntu -- bash -lc 'sleep 30' &
sleep 3
msb ps
msb exec spike-box -- echo "attached ok"
msb stop spike-box && msb rm spike-box 2>/dev/null || true
```
Expected: `msb ps` lists `spike-box`. **Record the exact column/format** so `msb_is_running` can grep it. Confirm `msb exec <name>` attaches to a running named sandbox.

- [ ] **Step 6: Write the spike doc and commit**

Write `docs/superpowers/SPIKE-microsandbox.md` recording, verbatim: msb version, daemon start (if any), the working domain net-rule string + wildcard form, the secret placeholder format, and the `msb ps` output format. For each, note whether it matched this plan's assumption or differs (and how).

```bash
git add docs/superpowers/SPIKE-microsandbox.md
git -c commit.gpgsign=false commit -m "chore(spike): confirm microsandbox v0.5 syntax for box prototype"
```

---

## Spike reconciliation (AUTHORITATIVE — overrides task code below)

Task 0 ran on this host (`msb 0.5.7`) and found the following. Where this section
conflicts with a task's code/tests below, **this section wins.** Implementers and
reviewers must follow it.

1. **`msb` is not on the default non-login PATH.** It lives at `~/.local/bin/msb`
   (symlink to `~/.microsandbox/bin/msb`). `lib/msb.sh` must resolve the binary
   itself, near the top of the file:
   ```bash
   MSB_BIN="${MSB_BIN:-$(command -v msb 2>/dev/null || echo "$HOME/.local/bin/msb")}"
   ```
   `_msb` runs `"$MSB_BIN"` (not `command msb`), and `msb_is_running` calls
   `"$MSB_BIN" ps -q`.

2. **No DNS net-rule.** In `msb_net_args`, the `sanctioned` mode must NOT emit
   `allow@host:udp:53`/`tcp:53` (microsandbox resolves domain rules itself; `host`
   is not a valid target). Emit `--net-rule` only when there is at least one host:
   ```bash
   sanctioned)
     printf '%s\n' --net-default-egress deny
     if [[ $# -gt 0 ]]; then
       local rules="" h
       for h in "$@"; do
         [[ -n "$rules" ]] && rules="${rules},"
         rules="${rules}allow@${h}:tcp:443"
       done
       printf '%s\n' --net-rule "$rules"
     fi
     ;;
   ```
   Wildcards work as `allow@*.example.com:tcp:443` (matches apex + subdomains,
   needs ≥2 labels). The Task 4 test must DROP the DNS assertion (and expect
   `ran 8, failed 0`); keep the host + wildcard assertions.

3. **Detached boot + exec, not `run … -- cmd`.** A persistent named sandbox is
   `msb run -d --name <name> <mounts> <net> [secrets] <image>` — the trailing
   `-- cmd` is ignored under `-d`. You then `msb exec <name> -- <cmd>` for a shell
   or one-off. So **replace `msb_start_run` with `msb_up`** (Task 5):
   ```bash
   # msb_up NAME IMAGE WORKSPACE MODE [HOST...]
   # Boots a detached, persistent named sandbox (mounts/net/secrets live here).
   msb_up() {
     local name="$1" image="$2" workspace="$3" mode="$4"; shift 4
     local hosts=("$@")
     local args=(run -d --name "$name")
     mapfile -t mounts < <(msb_mount_args "$workspace" box-mise:/mise box-home:/home/vscode)
     mapfile -t net < <(msb_net_args "$mode" "${hosts[@]}")
     args+=("${mounts[@]}" "${net[@]}" "$image")
     _msb "${args[@]}"
   }
   ```
   `msb_attach` is unchanged (`_msb exec "$name" -- "$@"`). The Task 5 test asserts
   `msb_up` emits `msb run -d --name box-proj`, the mounts, the net flags, and the
   image as the LAST token (no trailing command); plus `msb_is_running` is false
   under dry-run and `msb_attach` emits `msb exec box-proj -- echo hi`.

4. **`box` boot logic** (Task 7) uses up-then-attach:
   ```bash
   boot_or_attach() {  # MODE -- CMD...
     local mode="$1"; shift
     [[ "${1:-}" == "--" ]] && shift
     local cmd=("$@")
     local name; name="$(sandbox_name)"
     ensure_provisioned
     mapfile -t hosts < <(merged_hosts)
     if ! msb_is_running "$name"; then
       msb_up "$name" "$IMAGE" "$PWD" "$mode" "${hosts[@]}"
     fi
     msb_attach "$name" -- "${cmd[@]}"
   }
   ```
   The Task 7 test asserts the default path emits both `msb run -d --name box-`
   and `msb exec box-`. `down` is `_msb stop "$(sandbox_name)" || true` (delete the
   stray `msb_down_stub` line). `reset` is
   `_msb stop "$(sandbox_name)" 2>/dev/null || true; _msb rm "$(sandbox_name)" 2>/dev/null || true; rm -f "$(marker_file)"`.

5. **Secrets live on `msb_up`** (Task 8), not on `exec`. Task 8 adds, inside
   `msb_up` after building `net` and before assembling `args`:
   ```bash
     local secrets=()
     if [[ -n "${BOX_SECRETS:-}" ]]; then
       mapfile -t _secret_tokens <<< "$BOX_SECRETS"
       mapfile -t secrets < <(msb_secret_args "${_secret_tokens[@]}")
     fi
   ```
   and changes the assembly to
   `args+=("${mounts[@]}" "${net[@]}" "${secrets[@]}" "$image")`. The Task 8 test
   asserts `msb_up` (with `BOX_SECRETS` set) emits `--secret GITHUB_TOKEN@api.github.com`.

6. **Secret value in guest** (Task 9 step 5): the guest prints the literal string
   `$MSB_DEMO_TOKEN`, NOT the real secret — that is the pass condition (real value
   absent). Optionally also verify on-wire substitution with a curl to the allowed
   host.

7. **Detached VM stays alive** without an explicit command (the spike confirmed
   `msb exec` worked against a `-d` sandbox). If Task 9 finds the VM exits
   immediately, debug via systematic-debugging and record the fix in `lib/msb.sh`.

---

### Task 1: Test harness

**Files:**
- Create: `tests/lib/harness.sh`, `tests/run.sh`, `tests/unit/test-harness.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test-harness.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"

assert_eq "a" "a" "equal strings pass"
assert_contains "hello world" "world" "substring found"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/unit/test-harness.sh`
Expected: FAIL — `tests/lib/harness.sh: No such file or directory`.

- [ ] **Step 3: Write the harness**

Create `tests/lib/harness.sh`:
```bash
# shellcheck shell=bash
# Minimal assertion harness. Source it; call asserts; end with `finish`.
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-assert_eq}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then
    echo "  ok: $msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $msg"
    echo "    expected: [$expected]"
    echo "    actual:   [$actual]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-assert_contains}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ok: $msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $msg (missing [$needle])"
    echo "    in: [$haystack]"
  fi
}

finish() {
  echo "ran $TESTS_RUN, failed $TESTS_FAILED"
  [[ $TESTS_FAILED -eq 0 ]]
}
```

Create `tests/run.sh`:
```bash
#!/usr/bin/env bash
# Runs every tests/unit/*.sh and aggregates results.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "$HERE"/unit/*.sh; do
  echo "== $(basename "$t")"
  if ! bash "$t"; then
    fail=1
  fi
done
if [[ $fail -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit $fail
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run.sh`
Expected: `test-harness.sh` shows two `ok:` lines, `ran 2, failed 0`, then `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add tests/
git -c commit.gpgsign=false commit -m "test(box): add minimal bash test harness"
```

---

### Task 2: Allowlist merge + default list

**Files:**
- Create: `lib/allowlist.sh`, `allowlist.default`, `tests/unit/test-allowlist.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test-allowlist.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/allowlist.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' '# a comment' 'github.com' '*.npmjs.org' '' '  pypi.org ' > "$tmp/base"
printf '%s\n' 'github.com' 'extra.example.com' > "$tmp/project"

out="$(allowlist_merge "$tmp/base" "$tmp/project")"
expected=$'*.npmjs.org\nextra.example.com\ngithub.com\npypi.org'
assert_eq "$expected" "$out" "merge strips comments/space, dedups, sorts"

# Missing files are skipped, not fatal.
out2="$(allowlist_merge "$tmp/base" "$tmp/does-not-exist")"
assert_eq $'*.npmjs.org\ngithub.com\npypi.org' "$out2" "missing file skipped"

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/unit/test-allowlist.sh`
Expected: FAIL — `lib/allowlist.sh: No such file or directory`.

- [ ] **Step 3: Implement**

Create `lib/allowlist.sh`:
```bash
# shellcheck shell=bash
# allowlist_merge FILE...  ->  deduped, sorted hostnames on stdout.
# Strips `#` comments and all whitespace; skips blank lines and missing files.
# (Same normalisation the legacy firewall-init.sh used.)
allowlist_merge() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] && cat "$f"
  done | sed 's/#.*//' | tr -d ' \t' | awk 'NF' | sort -u
}
```

Create `allowlist.default` (ported from `allowlist.base`):
```
# Default egress allowlist for box (sanctioned mode). One host per line.
# Bare host = exact match; *.host = subdomains. Edit per-project via .box-allowlist.

# Anthropic / Claude
*.anthropic.com
*.claude.ai
*.claude.com

# GitHub
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
mise.run
mise-versions.jdx.dev
*.jdx.dev
nodejs.org
*.nodejs.org

# OS packages
deb.debian.org
security.debian.org
archive.ubuntu.com
security.ubuntu.com
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/unit/test-allowlist.sh`
Expected: `ran 2, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add lib/allowlist.sh allowlist.default tests/unit/test-allowlist.sh
git -c commit.gpgsign=false commit -m "feat(box): allowlist merge and default allowlist"
```

---

### Task 3: Secrets parser

**Files:**
- Create: `lib/secrets.sh`, `tests/unit/test-secrets.sh`

`.box-secrets` format: one `ENV_NAME host` pair per line (whitespace-separated), `#` comments. `secrets_parse` emits one `ENV@host` token per line.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test-secrets.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/secrets.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' '# secrets' 'GITHUB_TOKEN api.github.com' '' 'ANTHROPIC_API_KEY  api.anthropic.com' > "$tmp/s"

out="$(secrets_parse "$tmp/s")"
expected=$'GITHUB_TOKEN@api.github.com\nANTHROPIC_API_KEY@api.anthropic.com'
assert_eq "$expected" "$out" "parse ENV host -> ENV@host"

assert_eq "" "$(secrets_parse "$tmp/missing")" "missing file -> empty"

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/unit/test-secrets.sh`
Expected: FAIL — `lib/secrets.sh: No such file or directory`.

- [ ] **Step 3: Implement**

Create `lib/secrets.sh`:
```bash
# shellcheck shell=bash
# secrets_parse FILE  ->  one `ENV@host` token per line on stdout.
# Input lines: `ENV_NAME host` (whitespace separated). `#` comments, blanks skipped.
# Missing file -> no output (not an error).
secrets_parse() {
  local file="$1" env host
  [[ -f "$file" ]] || return 0
  while read -r env host _; do
    [[ -z "$env" || "$env" == \#* ]] && continue
    [[ -z "$host" ]] && continue
    printf '%s@%s\n' "$env" "$host"
  done < <(sed 's/#.*//' "$file")
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/unit/test-secrets.sh`
Expected: `ran 2, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add lib/secrets.sh tests/unit/test-secrets.sh
git -c commit.gpgsign=false commit -m "feat(box): .box-secrets parser"
```

---

### Task 4: microsandbox boundary — arg builders

**Files:**
- Create: `lib/msb.sh`, `tests/unit/test-msb-args.sh`

This task implements the **pure arg-building** functions in the boundary file (no `msb` execution yet). Each emits one token per line.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test-msb-args.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/msb.sh"

# --- net args ---
assert_eq "--net-default-egress"$'\n'"allow" "$(msb_net_args full)" "full = open egress"
assert_eq "--net-default-egress"$'\n'"deny" "$(msb_net_args none)" "none = deny, no rules"

san="$(msb_net_args sanctioned github.com '*.npmjs.org')"
assert_contains "$san" "--net-default-egress"$'\n'"deny" "sanctioned denies by default"
assert_contains "$san" "allow@host:udp:53" "sanctioned allows DNS"
assert_contains "$san" "allow@github.com:tcp:443" "sanctioned allows listed host"
assert_contains "$san" "allow@*.npmjs.org:tcp:443" "sanctioned allows wildcard host"

# --- mount args ---
m="$(msb_mount_args /home/jakobl/proj box-mise:/mise box-home:/home/vscode)"
assert_contains "$m" "--mount-dir"$'\n'"/home/jakobl/proj:/workspace" "workspace bind mount"
assert_contains "$m" "--mount-named"$'\n'"box-mise:/mise" "mise volume"
assert_contains "$m" "--mount-named"$'\n'"box-home:/home/vscode" "home volume"

# --- secret args ---
s="$(msb_secret_args GITHUB_TOKEN@api.github.com ANTHROPIC_API_KEY@api.anthropic.com)"
assert_contains "$s" "--secret"$'\n'"GITHUB_TOKEN@api.github.com" "secret 1"
assert_contains "$s" "--secret"$'\n'"ANTHROPIC_API_KEY@api.anthropic.com" "secret 2"
assert_eq "" "$(msb_secret_args)" "no secrets -> empty"

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/unit/test-msb-args.sh`
Expected: FAIL — `lib/msb.sh: No such file or directory`.

- [ ] **Step 3: Implement the arg builders**

Create `lib/msb.sh`:
```bash
# shellcheck shell=bash
# === microsandbox boundary ===
# The ONLY file that knows `msb` syntax. If microsandbox changes, fix it here.
# Syntax confirmed in docs/superpowers/SPIKE-microsandbox.md (Task 0).
# Arg-builder functions emit one token per line; callers use `mapfile -t`.

# msb_net_args MODE [HOST...] -> egress flags.
#   full       = open egress (provision)
#   none       = deny all (airgapped)
#   sanctioned = deny by default, allow DNS + each HOST on tcp:443
msb_net_args() {
  local mode="$1"; shift || true
  case "$mode" in
    full)
      printf '%s\n' --net-default-egress allow
      ;;
    none)
      printf '%s\n' --net-default-egress deny
      ;;
    sanctioned)
      printf '%s\n' --net-default-egress deny
      local rules="allow@host:udp:53,allow@host:tcp:53"
      local h
      for h in "$@"; do
        rules="${rules},allow@${h}:tcp:443"
      done
      printf '%s\n' --net-rule "$rules"
      ;;
    *)
      echo "msb_net_args: unknown mode '$mode'" >&2
      return 1
      ;;
  esac
}

# msb_mount_args WORKSPACE [VOLUME:GUEST...] -> mount flags.
msb_mount_args() {
  local workspace="$1"; shift || true
  printf '%s\n' --mount-dir "${workspace}:/workspace"
  local v
  for v in "$@"; do
    printf '%s\n' --mount-named "$v"
  done
}

# msb_secret_args [ENV@HOST...] -> secret flags (empty if none).
msb_secret_args() {
  local s
  for s in "$@"; do
    printf '%s\n' --secret "$s"
  done
}
```

> **Spike reconciliation:** if Task 0 found the domain rule must be written differently (e.g. no `@`, or a distinct wildcard form), change the two `allow@...` lines in `msb_net_args` only. If the secret placeholder/syntax differs, change `msb_secret_args`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/unit/test-msb-args.sh`
Expected: `ran 9, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add lib/msb.sh tests/unit/test-msb-args.sh
git -c commit.gpgsign=false commit -m "feat(box): microsandbox arg builders (net/mount/secret)"
```

---

### Task 5: microsandbox boundary — runner + lifecycle

**Files:**
- Modify: `lib/msb.sh`
- Create: `tests/unit/test-msb-run.sh`

Adds the `_msb` runner (the `BOX_DRY_RUN` seam) and the execution functions.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test-msb-run.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/msb.sh"

export BOX_DRY_RUN=1

# _msb prints instead of executing under dry-run.
assert_eq "msb ps" "$(_msb ps)" "_msb prints under dry-run"

# is_running is always false under dry-run (no daemon contacted).
if msb_is_running anything; then
  assert_eq "running" "not-running" "is_running must be false in dry-run"
else
  assert_eq "ok" "ok" "is_running false in dry-run"
fi

# start_run builds a `run --name` command with mounts, net, image, and shell.
out="$(msb_start_run box-proj mcr.microsoft.com/devcontainers/base:ubuntu /tmp/p \
        sanctioned github.com -- /usr/bin/zsh)"
assert_contains "$out" "msb run --name box-proj" "named run"
assert_contains "$out" "--mount-dir /tmp/p:/workspace" "mounts workspace"
assert_contains "$out" "--mount-named box-mise:/mise" "mounts mise volume"
assert_contains "$out" "--net-default-egress deny" "locked egress"
assert_contains "$out" "mcr.microsoft.com/devcontainers/base:ubuntu -- /usr/bin/zsh" "image then command"

# attach uses exec against the named sandbox.
assert_contains "$(msb_attach box-proj -- echo hi)" "msb exec box-proj -- echo hi" "attach via exec"

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/unit/test-msb-run.sh`
Expected: FAIL — `_msb: command not found` (function not defined yet).

- [ ] **Step 3: Implement the runner and lifecycle functions**

Append to `lib/msb.sh`:
```bash
# _msb ARGS...  -> run `msb` unless BOX_DRY_RUN is set, then just print.
# This is the test seam: all execution goes through here.
_msb() {
  if [[ -n "${BOX_DRY_RUN:-}" ]]; then
    printf 'msb %s\n' "$*"
  else
    command msb "$@"
  fi
}

# msb_is_running NAME -> 0 if a named sandbox is currently running.
# Dry-run short-circuits to "not running".
# NOTE: `msb ps` column format confirmed in SPIKE doc; adjust the grep if needed.
msb_is_running() {
  [[ -n "${BOX_DRY_RUN:-}" ]] && return 1
  command msb ps 2>/dev/null | grep -qw "$1"
}

# msb_start_run NAME IMAGE WORKSPACE MODE [HOST...] -- CMD...
# Boots a fresh named sandbox with volumes, workspace, egress policy, then CMD.
msb_start_run() {
  local name="$1" image="$2" workspace="$3" mode="$4"; shift 4
  local hosts=() ; while [[ $# -gt 0 && "$1" != "--" ]]; do hosts+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  local cmd=("$@")

  local args=(run --name "$name")
  mapfile -t mounts < <(msb_mount_args "$workspace" box-mise:/mise box-home:/home/vscode)
  mapfile -t net < <(msb_net_args "$mode" "${hosts[@]}")
  args+=("${mounts[@]}" "${net[@]}" "$image" -- "${cmd[@]}")
  _msb "${args[@]}"
}

# msb_attach NAME -- CMD...  -> run CMD in an already-running named sandbox.
msb_attach() {
  local name="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  _msb exec "$name" -- "$@"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/unit/test-msb-run.sh`
Expected: `ran 6, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add lib/msb.sh tests/unit/test-msb-run.sh
git -c commit.gpgsign=false commit -m "feat(box): msb runner and sandbox lifecycle helpers"
```

---

### Task 6: microsandbox boundary — provision

**Files:**
- Modify: `lib/msb.sh`
- Create: `mise.base.toml`, `tests/unit/test-msb-provision.sh`

Provision boots an ephemeral sandbox with **open egress**, mounts the volumes + workspace, installs mise into `/mise`, and runs `mise install`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test-msb-provision.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
source "$ROOT/lib/msb.sh"

export BOX_DRY_RUN=1
out="$(msb_provision mcr.microsoft.com/devcontainers/base:ubuntu /tmp/proj)"
assert_contains "$out" "msb run" "provision runs a sandbox"
assert_contains "$out" "--mount-named box-mise:/mise" "provision mounts mise volume"
assert_contains "$out" "--mount-dir /tmp/proj:/workspace" "provision mounts workspace"
assert_contains "$out" "--net-default-egress allow" "provision has open egress"
assert_contains "$out" "mise install" "provision installs mise tools"

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/unit/test-msb-provision.sh`
Expected: FAIL — `msb_provision: command not found`.

- [ ] **Step 3: Implement provision + base tools file**

Create `mise.base.toml`:
```toml
# Base tools installed into the box-mise volume at provision time.
[tools]
node = "lts"
ripgrep = "latest"
```

Append to `lib/msb.sh`:
```bash
# msb_provision IMAGE WORKSPACE
# Ephemeral, open-egress sandbox that populates the box-mise/box-home volumes:
# installs mise into /mise, then `mise install` (base + project mise.toml).
msb_provision() {
  local image="$1" workspace="$2"
  mapfile -t mounts < <(msb_mount_args "$workspace" box-mise:/mise box-home:/home/vscode)
  mapfile -t net < <(msb_net_args full)
  # Guest-side provisioning script. mise data/config/cache all live on /mise.
  local script='set -e
export MISE_DATA_DIR=/mise MISE_CONFIG_DIR=/mise MISE_CACHE_DIR=/mise/cache
export PATH=/mise/bin:$PATH
if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | MISE_INSTALL_PATH=/mise/bin/mise sh
fi
mise trust --yes /workspace 2>/dev/null || true
[ -f /workspace/mise.base.toml ] && mise install -C /workspace --cd /workspace || true
mise install -C /workspace || mise install
'
  _msb run "${mounts[@]}" "${net[@]}" "$image" -- bash -lc "$script"
}
```

> The base-tools list ships as `mise.base.toml`; `box` copies it into the workspace-visible path or installs it explicitly during provision (wired in Task 7). Keep the guest script tolerant (`|| true`) so a missing project `mise.toml` is non-fatal — mirrors the legacy entrypoint's non-fatal `mise install`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/unit/test-msb-provision.sh`
Expected: `ran 5, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add lib/msb.sh mise.base.toml tests/unit/test-msb-provision.sh
git -c commit.gpgsign=false commit -m "feat(box): provision phase populates mise volume with open egress"
```

---

### Task 7: `box` CLI — dispatch & orchestration

**Files:**
- Create: `box`, `tests/unit/test-box-cli.sh`

`box` ties the libraries together. State marker for provisioning lives at
`${XDG_STATE_HOME:-$HOME/.local/state}/box/<name>.provisioned`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test-box-cli.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"

run_box() {  # run box in a throwaway project dir, dry-run, provisioned
  local proj; proj="$(mktemp -d)"
  ( cd "$proj" && BOX_DRY_RUN=1 BOX_ASSUME_PROVISIONED=1 "$ROOT/box" "$@" )
}

# default: boots a named run sandbox into the login shell
def="$(run_box)"
assert_contains "$def" "msb run --name box-" "default boots named sandbox"
assert_contains "$def" "--net-default-egress deny" "default run is locked down"
assert_contains "$def" "-- " "default drops into a shell command"

# one-off command
oneoff="$(run_box -- echo hello)"
assert_contains "$oneoff" "-- echo hello" "one-off passes command"

# provision: open egress
prov="$(run_box provision)"
assert_contains "$prov" "--net-default-egress allow" "provision opens egress"
assert_contains "$prov" "mise install" "provision installs tools"

# net override
none="$(run_box --net none)"
assert_contains "$none" "--net-default-egress deny" "net none denies"
assert_eq "" "$(echo "$none" | grep -o 'allow@github.com:tcp:443' || true)" "net none has no allow rules"

# help exits 0 and mentions usage
help="$(run_box --help)"
assert_contains "$help" "Usage" "help shows usage"

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/unit/test-box-cli.sh`
Expected: FAIL — `box: No such file or directory` (or non-zero exit).

- [ ] **Step 3: Implement `box`**

Create `box` (and `chmod +x box`):
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib/allowlist.sh"
source "$SCRIPT_DIR/lib/secrets.sh"
source "$SCRIPT_DIR/lib/msb.sh"

IMAGE="${BOX_IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu}"
DEFAULT_ALLOWLIST="$SCRIPT_DIR/allowlist.default"

usage() {
  cat <<'EOF'
Usage: box [--net none|sanctioned|full] [COMMAND]

  box                     Boot/attach the sandbox for this directory; open a shell.
  box -- CMD...           Run a one-off command in the sandbox.
  box shell               Attach an extra terminal to the running sandbox.
  box provision           Build step (open egress): install mise + tools into the volume.
  box down                Stop the sandbox.
  box reset               Stop and remove the sandbox + named volumes.
  box --help              Show this help.

Egress modes: none (airgapped), sanctioned (default; deny + allowlist), full (provision).
Per-project egress extras: .box-allowlist   Secrets: .box-secrets  (both outside the repo's tracked files as needed)
EOF
}

sandbox_name() { echo "box-$(basename "$PWD")"; }

state_dir() { echo "${XDG_STATE_HOME:-$HOME/.local/state}/box"; }
marker_file() { echo "$(state_dir)/$(sandbox_name).provisioned"; }

merged_hosts() {  # default allowlist + optional project file
  allowlist_merge "$DEFAULT_ALLOWLIST" "$PWD/.box-allowlist"
}

declared_secrets() { secrets_parse "$PWD/.box-secrets"; }

ensure_provisioned() {
  [[ -n "${BOX_ASSUME_PROVISIONED:-}" ]] && return 0
  [[ -f "$(marker_file)" ]] && return 0
  echo "box: first run for $(sandbox_name); provisioning (open egress)..." >&2
  do_provision
  mkdir -p "$(state_dir)"; : > "$(marker_file)"
}

do_provision() {
  msb_provision "$IMAGE" "$PWD"
}

boot_or_attach() {  # MODE -- CMD...
  local mode="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local cmd=("$@")
  local name; name="$(sandbox_name)"
  ensure_provisioned
  mapfile -t hosts < <(merged_hosts)
  if msb_is_running "$name"; then
    msb_attach "$name" -- "${cmd[@]}"
  else
    msb_start_run "$name" "$IMAGE" "$PWD" "$mode" "${hosts[@]}" -- "${cmd[@]}"
  fi
}

# --- arg parsing ---
MODE="sanctioned"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --net) MODE="$2"; shift 2 ;;
    provision) ensure_state=1; do_provision; mkdir -p "$(state_dir)"; : > "$(marker_file)"; exit 0 ;;
    down) msb_down_stub() { :; }; _msb stop "$(sandbox_name)" || true; exit 0 ;;
    reset) _msb rm "$(sandbox_name)" 2>/dev/null || true; rm -f "$(marker_file)"; echo "box: removed sandbox + marker (volumes: msb volume rm box-mise box-home)"; exit 0 ;;
    shell) boot_or_attach "$MODE" -- /usr/bin/zsh; exit 0 ;;
    --) shift; boot_or_attach "$MODE" -- "$@"; exit 0 ;;
    *) echo "box: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# no command: open a login shell
boot_or_attach "$MODE" -- /usr/bin/zsh
```

> **Implementer notes:** `down` and `reset` call `_msb`; under `BOX_DRY_RUN` they print and the tests for them (Task 9 manual) are exercised live. The default shell is `zsh` (present in the devcontainers base image); change to `/bin/bash` if the spike shows zsh is absent. `provision` writes the marker so the next `box` skips re-provisioning.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/unit/test-box-cli.sh && chmod +x box`
Expected: `ran 8, failed 0`.

- [ ] **Step 5: Commit**

```bash
chmod +x box
git add box tests/unit/test-box-cli.sh
git -c commit.gpgsign=false commit -m "feat(box): CLI dispatch, provision orchestration, egress modes"
```

---

### Task 8: Wire secrets into the run path

**Files:**
- Modify: `box`, `lib/msb.sh`, `tests/unit/test-msb-run.sh`

Secrets declared in `.box-secrets` must be passed to `msb_start_run`.

- [ ] **Step 1: Extend the run test (write the failing assertion)**

Append to `tests/unit/test-msb-run.sh` before `finish`:
```bash
# start_run forwards secrets when provided via BOX_SECRETS env (newline list).
out2="$(BOX_SECRETS=$'GITHUB_TOKEN@api.github.com' \
        msb_start_run box-proj img /tmp/p sanctioned github.com -- /usr/bin/zsh)"
assert_contains "$out2" "--secret GITHUB_TOKEN@api.github.com" "start_run forwards secrets"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/unit/test-msb-run.sh`
Expected: FAIL — the new assertion misses `--secret ...`.

- [ ] **Step 3: Implement**

In `lib/msb.sh`, inside `msb_start_run`, after building `net` and before assembling `args+=(...)`, add secret handling:
```bash
  local secrets=()
  if [[ -n "${BOX_SECRETS:-}" ]]; then
    mapfile -t _secret_tokens <<< "$BOX_SECRETS"
    mapfile -t secrets < <(msb_secret_args "${_secret_tokens[@]}")
  fi
```
Then change the assembly line to include secrets:
```bash
  args+=("${mounts[@]}" "${net[@]}" "${secrets[@]}" "$image" -- "${cmd[@]}")
```
(With `set -u`, guard empty arrays: write `"${secrets[@]+"${secrets[@]}"}"` if your bash is < 4.4; the repo targets bash 4.4+ so plain expansion is fine.)

In `box`, set `BOX_SECRETS` before `boot_or_attach` by exporting the parsed secrets. In `boot_or_attach`, before the `if msb_is_running` block:
```bash
  BOX_SECRETS="$(declared_secrets)"; export BOX_SECRETS
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run.sh`
Expected: every unit file passes; final line `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add box lib/msb.sh tests/unit/test-msb-run.sh
git -c commit.gpgsign=false commit -m "feat(box): inject .box-secrets into the locked-down run"
```

---

### Task 9: End-to-end validation on real microsandbox

**Files:**
- Create: `docs/superpowers/E2E-microsandbox.md`

Live validation (requires Task 0 install). No `BOX_DRY_RUN`.

- [ ] **Step 1: Provision a sample project**

Run:
```bash
mkdir -p /tmp/box-demo && cd /tmp/box-demo
printf '[tools]\njq = "latest"\n' > mise.toml
/home/jakobl/code/devcontainer/box provision
```
Expected: image pulls, mise installs into the volume, exits 0. Note duration.

- [ ] **Step 2: Verify the core loop (mount + mise + shell)**

Run:
```bash
cd /tmp/box-demo
/home/jakobl/code/devcontainer/box -- bash -lc 'echo from-guest > /workspace/touched.txt; mise --version; jq --version'
cat /tmp/box-demo/touched.txt
```
Expected: prints mise + jq versions (proves persisted tools); host sees `from-guest` in `touched.txt` (proves two-way mount).

- [ ] **Step 3: Verify egress allowlist**

Run:
```bash
cd /tmp/box-demo
/home/jakobl/code/devcontainer/box -- bash -lc \
  'curl -sS -o /dev/null -w "github:%{http_code}\n" https://github.com; \
   curl -sS -m 8 -o /dev/null -w "evil:%{http_code}\n" https://example.com || echo evil:BLOCKED'
```
Expected: `github:` succeeds (allowlisted); `evil:BLOCKED` (denied by default).

- [ ] **Step 4: Verify a per-project allowlist addition**

Run:
```bash
cd /tmp/box-demo && echo 'example.com' > .box-allowlist
/home/jakobl/code/devcontainer/box -- bash -lc \
  'curl -sS -m 8 -o /dev/null -w "evil-now:%{http_code}\n" https://example.com || echo evil-now:BLOCKED'
rm .box-allowlist
```
Expected: `evil-now:` now returns an HTTP code (project allowlist took effect with no rebuild).

- [ ] **Step 5: Verify leak-proof secrets**

Run:
```bash
cd /tmp/box-demo
echo 'DEMO_TOKEN api.github.com' > .box-secrets
export DEMO_TOKEN="real-secret-xyz"
/home/jakobl/code/devcontainer/box -- bash -lc 'echo "guest-sees: $DEMO_TOKEN"'
rm .box-secrets
```
Expected: guest does **not** print `real-secret-xyz` (prints a placeholder/empty). Confirms the secret never enters the guest.

- [ ] **Step 6: Record results and commit**

Write `docs/superpowers/E2E-microsandbox.md` with each step's actual output (pass/fail), provision duration, and any deviation from the plan (especially anything that forced a change to `lib/msb.sh`). If a step failed, **debug via superpowers:systematic-debugging**, fix, and re-run before recording PASS.

```bash
git add docs/superpowers/E2E-microsandbox.md lib/ box
git -c commit.gpgsign=false commit -m "test(box): end-to-end validation on microsandbox"
```

---

### Task 10: Docs + deferred-scope markers

**Files:**
- Create: `README.box.md`, `TODO.box.md`

- [ ] **Step 1: Write `README.box.md`**

Document: what `box` is, requirements (Linux+KVM or macOS Apple Silicon, `msb` installed), the commands table from Task 7's `usage`, the `.box-allowlist` / `.box-secrets` formats, and the provision-once/run-many model. State that microsandbox specifics live solely in `lib/msb.sh`.

- [ ] **Step 2: Write `TODO.box.md`**

List deferred slices verbatim from the spec: allowlist modes polish, `box install` under the agent's own name, snapshot-based provisioning optimization, macOS validation, dind-in-microVM, and removal of the legacy `dev`/`Dockerfile`/`firewall-*` stack once the prototype is accepted.

- [ ] **Step 3: Run the full test suite once more**

Run: `bash tests/run.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add README.box.md TODO.box.md
git -c commit.gpgsign=false commit -m "docs(box): prototype README and deferred-scope TODO"
```

---

## Self-review notes

- **Spec coverage:** core loop (Tasks 5,7,9), two-phase lifecycle/provision (Tasks 6,7,9), named-volume persistence (Tasks 5,6), egress allowlist + modes + per-project file (Tasks 2,4,7,9), leak-proof secrets (Tasks 3,8,9), wrapper boundary in one file (Tasks 4–6), operator-on-host two-way mount (Task 9 step 2), delete-old-stack (deferred + recorded in Task 10). All spec sections map to a task.
- **Beta risk:** isolated to Task 0 + the named functions in `lib/msb.sh`; reconciliation steps called out.
- **Type/name consistency:** `msb_net_args`, `msb_mount_args`, `msb_secret_args`, `msb_start_run`, `msb_attach`, `msb_provision`, `msb_is_running`, `_msb`, `allowlist_merge`, `secrets_parse`, `boot_or_attach`, `ensure_provisioned` used consistently across tasks. Volumes `box-mise:/mise`, `box-home:/home/vscode` and sandbox name `box-<dir>` consistent throughout.
