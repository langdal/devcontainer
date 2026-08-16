# Egress Open-By-Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip the container's egress default to open (`dev up`), make the hostname-allowlist a `--closed` opt-in, keep link-local blocked in all modes, keep egress observable in open mode via kernel logging — and fold in the agreed defect/doc fixes from the final review.

**Architecture:** Four sequential PRs on `production-prep`. PR-A: firewall + entrypoint + CLI mechanics of the flip (folds in C1 regex-escape, since it rewrites the filter builder). PR-B: tests (rename+extend scenario 50, new scenario 52, verify-firewall metadata probe, fix the C4/I12 "any failure = pass" test shapes). PR-C: independent code fixes (pind volume migration, `dev update` prerelease-tag filter). PR-D: docs written once against final behavior (SECURITY.md reframe, README TLDR + observability feature, CLAUDE.md, architecture.html, the C3 baseline reconciliation).

**Tech Stack:** bash (macOS 3.2-compatible on host-side files: no associative arrays, no `${var,,}`, guard empty arrays with `${arr[@]+"${arr[@]}"}`); container-side scripts (`entrypoint.sh`, `firewall-init.sh`, `firewall-disable.sh`) run bash 5 and are 3.2-exempt. shellcheck + hadolint + actionlint via mise. e2e scenarios under `scripts/test/`.

**Spec:** `docs/superpowers/specs/2026-08-16-egress-open-default-design.md`

## Global Constraints

- Conventional commits; GPG signing fails in-sandbox → `git -c commit.gpgsign=false commit`. **NEVER `git push`.**
- Commit identity: `git -c user.name="Jakob Langdal" -c user.email=jakob@langdal.dk`.
- Every commit body ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01462uCpiASfutUJxpbc8WCH`
- Before every commit: `mise x shellcheck -- shellcheck -x dev lib/dev/*.sh <changed scenario/script>` clean; container-side script changes also `mise x shellcheck -- shellcheck -x entrypoint.sh firewall-init.sh firewall-disable.sh`; Dockerfile changes `mise x hadolint -- hadolint Dockerfile`.
- Runtime is rootless podman; the host `docker` CLI is broken — never call it. Scenarios use `$RUNTIME`.
- Vocabulary is **open / closed** on both the start flag (`--open`/`--closed`) and the fw toggle (`fw open`/`fw close`). Default is **open**.
- Mode resolution precedence: explicit flag > `DEV_EGRESS` (host env, values `open`|`closed`, anything else is an error) > default `open`.
- Container-side env contract: `DEVCONTAINER_EGRESS=open|closed` (distinct from host-side `DEV_EGRESS`).
- Always-on in **both** modes: DROP `169.254.0.0/16` (v4) and `fe80::/10` (v6) on OUTPUT, with the container's resolver exempted if it is itself link-local.
- Isolation is unchanged by this work. Do not touch mount/cap/userns/volume decisions except the one pind-volume fix in PR-C.

## File Structure

- `firewall-init.sh` — gains `install_baseline_blocks()` and `install_egress_logging()`; branches on `DEVCONTAINER_EGRESS`; the filter builder is hardened (C1). Single responsibility unchanged: bring egress policy up per mode, fail closed.
- `firewall-disable.sh` — re-installs the baseline block after flushing to ACCEPT.
- `entrypoint.sh` — resolves the container-side mode from `DEVCONTAINER_EGRESS`; gates the proxy exports / `proxy.sh` / `no-aaaa` / m2+gradle seeding behind closed mode. Drops the old `DEVCONTAINER_FW_DISABLED` two-step.
- `dev` (router) + `lib/dev/up.sh` — resolve `DEV_EGRESS`+flags → `EGRESS_MODE`, pass `DEVCONTAINER_EGRESS` to the container. `--open`/`--closed` replace the `--open`-means-FW_DISABLED plumbing.
- `lib/dev/fw.sh` — `off|on` → `open|close`; `fw log` becomes mode-aware.
- `lib/dev/status.sh` — report egress mode per container.
- `lib/dev/volumes.sh` — add the missing `devcontainer-pind` keep-id migration branch (PR-C).
- `lib/dev/update.sh` — add install.sh's prerelease-tag filter (PR-C).
- `scripts/test/scenarios/50-cli-verbs.sh` — open/close surface; fix the I14 tautology.
- `scripts/test/scenarios/52-egress-modes.sh` — NEW: the flip's behavioral contract.
- `scripts/test/scenarios/33-,34-attack-nested-egress*.sh` — fix the C4 assertion shape.
- `scripts/verify-firewall.sh` — add the link-local/metadata DROP probe.
- `SECURITY.md`, `README.md`, `CLAUDE.md`, `docs/architecture.html`, `docs/ci-testing.md` — PR-D.

## Deferred (explicitly out of scope for this plan)

Recorded so they are not silently dropped; a separate hardening pass:
final-review I2 (DEV_EXTRA_RUN_ARGS doc — but see Task 13, it rides along in the SECURITY reframe), I3 (state-dir mount scoping), I5 (status NEEDS_ENGINE macOS), I8 (exit-code convention sweep — except the two lines Task 3 already touches), I12 remainder (11/12/15/16/31 test shapes — only 33/34 are in scope as C4), I13 (scenario 21 dead guard), I15 (scenario 51 buildx tautology), I16 (dotfile/install test coverage), I17/I18 (lint-gate + macOS scenario platform), M-series. C2 (DNS-to-any) is **documented, not fixed**, per the spec.

---

## PR-A — flip mechanics (firewall + entrypoint + CLI)

### Task 1: harden the allowlist filter builder (C1) and add baseline blocks

**Files:**
- Modify: `firewall-init.sh` (filter builder ~lines 39-50; iptables section ~110-184)

**Interfaces:**
- Produces: `install_baseline_blocks()` (called by both firewall-init and firewall-disable); a hardened filter builder that refuses malformed allowlist entries.

- [ ] **Step 1: Write the failing test** — new unit test `scripts/test/unit/test-allowlist-filter.sh` that sources the builder logic. Since the builder is inline in `firewall-init.sh`, extract it first (Step 3); the test drives the extracted function:

```bash
#!/bin/bash
# scripts/test/unit/test-allowlist-filter.sh
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# allowlist_to_filter reads entries on stdin, writes ERE lines on stdout,
# and exits non-zero if any entry is malformed.
. "$ROOT/scripts/test/lib/allowlist-filter-harness.sh"  # sources the fn out of firewall-init.sh

fail() { echo "FAIL: $1"; exit 1; }

# Valid entries produce anchored, dot-escaped EREs.
out=$(printf 'github.com\n*.example.com\n' | allowlist_to_filter) || fail "valid entries rejected"
echo "$out" | grep -qx '\^github\\\.com\$' || fail "bare host not anchored/escaped: $out"
echo "$out" | grep -q 'example\\\.com\$'   || fail "wildcard not handled: $out"

# The C1 injection: a regex metacharacter must be REFUSED, not passed through.
if printf 'x|\n' | allowlist_to_filter >/dev/null 2>&1; then
    fail "entry 'x|' was accepted — regex injection still open"
fi
# A crafted allow-all must not slip through.
out=$(printf 'x|\ngithub.com\n' | allowlist_to_filter 2>/dev/null || true)
echo "evil.example.com" | grep -Eq "${out:-^\$NOMATCH\$}" && fail "allow-all leaked"

echo "ok"
```

- [ ] **Step 2: Run it — fails** (`allowlist-filter-harness.sh` and the extracted fn don't exist).

Run: `bash scripts/test/unit/test-allowlist-filter.sh`
Expected: FAIL (harness missing).

- [ ] **Step 3: Extract + harden the builder in `firewall-init.sh`.** Replace the inline `while IFS= read -r entry; do … done > "$FILTER"` (current ~39-50) with a named function, and validate each entry against a strict grammar before escaping — refuse anything else (fail-closed, consistent with the empty-filter refusal):

```bash
# Convert allowlist entries (stdin) to anchored tinyproxy ERE lines (stdout).
# Fail closed on any entry that is not a bare hostname or a *.suffix wildcard:
# a stray ERE metacharacter (|, *, +, (, ), [, ], {, }, ^, $, \, ?) would
# otherwise be injected into a FilterExtended regex and could match every
# host (e.g. "x|" -> "^x|$" -> matches all). See SECURITY.md C1.
allowlist_to_filter() {
    local entry tail escaped
    while IFS= read -r entry; do
        if [[ "$entry" == \*.* ]]; then
            tail="${entry#*.}"
            if [[ ! "$tail" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; then
                echo "firewall-init: refusing malformed allowlist wildcard: $entry" >&2
                return 1
            fi
            escaped="${tail//./\\.}"
            printf '^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.%s$\n' "$escaped"
        else
            if [[ ! "$entry" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; then
                echo "firewall-init: refusing malformed allowlist entry: $entry" >&2
                return 1
            fi
            escaped="${entry//./\\.}"
            printf '^%s$\n' "$escaped"
        fi
    done
}
```

Then the merge pipeline becomes `… | sort -u | allowlist_to_filter > "$FILTER" || exit 1` (propagate the refusal — the existing `set -euo pipefail` plus the explicit `|| exit 1` keeps it fail-closed).

Create `scripts/test/lib/allowlist-filter-harness.sh` that greps the `allowlist_to_filter` function body out of `firewall-init.sh` and sources it (so the test drives the real code, not a copy):

```bash
# shellcheck shell=bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
eval "$(awk '/^allowlist_to_filter\(\) \{/,/^\}/' "$ROOT/firewall-init.sh")"
```

- [ ] **Step 4: Add `install_baseline_blocks()`** to `firewall-init.sh`, called first in the iptables section (before the v4 ACCEPT/DROP rules), and DROP link-local in both families, exempting a link-local resolver:

```bash
# Always-on in every mode: link-local (169.254/16, fe80::/10) carries the
# cloud metadata endpoint (169.254.169.254 on AWS/GCP/Azure/Oracle), a network
# path to host credentials. Rules precede the chain policy, so this holds
# whether OUTPUT policy is ACCEPT (open) or DROP (closed). If the container's
# own resolver is link-local, exempt it so DNS still resolves.
install_baseline_blocks() {
    local ns
    while read -r _ ns _; do
        case "$ns" in
          169.254.*) iptables  -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
                     iptables  -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT ;;
        esac
    done < <(grep '^nameserver ' /etc/resolv.conf 2>/dev/null)
    iptables  -A OUTPUT -d 169.254.0.0/16 -j DROP
    ip6tables -w -A OUTPUT -d fe80::/10    -j DROP 2>/dev/null || true
}
```

- [ ] **Step 5: Run the unit test — passes.**

Run: `bash scripts/test/unit/test-allowlist-filter.sh` → `ok`.
Run: `mise x shellcheck -- shellcheck -x firewall-init.sh scripts/test/unit/test-allowlist-filter.sh scripts/test/lib/allowlist-filter-harness.sh` → clean.

- [ ] **Step 6: Commit.**

```bash
git add firewall-init.sh scripts/test/unit/test-allowlist-filter.sh scripts/test/lib/allowlist-filter-harness.sh
git commit -m "fix(firewall): validate allowlist entries before building the filter (C1)"
```

### Task 2: open/closed branch in firewall-init.sh + open-mode egress logging

**Files:**
- Modify: `firewall-init.sh` (iptables section), `firewall-disable.sh`

**Interfaces:**
- Consumes: `install_baseline_blocks` (Task 1), env `DEVCONTAINER_EGRESS`.
- Produces: mode-branched firewall bring-up; `install_egress_logging()`.

- [ ] **Step 1: Branch the iptables section on mode.** After `PROXY_UID` is resolved, structure it as:

```bash
iptables -F OUTPUT
iptables -P FORWARD DROP
iptables -P INPUT ACCEPT
install_baseline_blocks

if [ "${DEVCONTAINER_EGRESS:-closed}" = "open" ]; then
    # Open mode: everything except link-local (already dropped above) is
    # allowed at the IP layer. No proxy, no allowlist. Egress stays
    # observable via install_egress_logging (DNS + new-connection NFLOG).
    iptables -A OUTPUT -m limit --limit 60/min --limit-burst 20 \
        -p tcp --syn -j NFLOG --nflog-group 2 --nflog-prefix "FW-CONN"
    iptables -P OUTPUT ACCEPT
    echo "firewall-init: egress OPEN (link-local blocked; connections logged to NFLOG group 2)" >&2
else
    iptables -P OUTPUT DROP
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -m multiport --dports 80,443 -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # … existing host-port block, existing FW-DROP NFLOG …
fi
```

Move the tinyproxy config/filter build and the `dc-tinyproxy` start (current ~57-108) so they run **only in closed mode** (open mode has no proxy). The ip6tables mirror block similarly: open → policy ACCEPT + baseline; closed → today's DROP mirror.

- [ ] **Step 2: Guard the empty-filter check** so it only applies in closed mode (open mode builds no filter). Wrap the `if [ ! -s "$FILTER" ]` refusal in the closed branch.

- [ ] **Step 3: `firewall-disable.sh` re-installs the baseline** after flushing to ACCEPT (today it flushes clean — that would drop the link-local block). After `iptables -P OUTPUT ACCEPT` (and the v6 equivalent), source-and-call `install_baseline_blocks` (it is defined in firewall-init.sh; firewall-disable.sh must define its own copy or source the function — define a local copy, since firewall-disable.sh runs standalone). Add the same DROP lines directly:

```bash
# Re-assert the always-on link-local block; opening egress must not open
# the path to the cloud metadata endpoint.
iptables  -A OUTPUT -d 169.254.0.0/16 -j DROP
ip6tables -w -A OUTPUT -d fe80::/10   -j DROP 2>/dev/null || true
```

- [ ] **Step 4: Verify by hand on a real container.** From a scratch dir:

```bash
cd "$(mktemp -d)"
DEV_RUNTIME=podman DEV_ASSUME_YES=1 /home/jakob/code/devcontainer/dev exec -- \
  sh -c 'curl -sS -m5 -o /dev/null -w "%{http_code}\n" https://example.com; \
         curl -sS -m5 -o /dev/null -w "meta:%{http_code}\n" http://169.254.169.254/ || echo meta:blocked'
```
Expected: `200` (open reaches example.com) and `meta:blocked` (link-local dropped). Then `/home/jakob/code/devcontainer/dev down`.

- [ ] **Step 5: shellcheck + commit.**

```bash
git add firewall-init.sh firewall-disable.sh
git commit -m "feat(firewall): open/closed egress modes; open keeps link-local blocked and connections logged"
```

### Task 3: CLI mode resolution + fw rename + entrypoint gating

**Files:**
- Modify: `dev` (router), `lib/dev/up.sh` (cmd_up/cmd_exec flag xlat + cmd_start parse), `lib/dev/fw.sh`, `lib/dev/status.sh`, `entrypoint.sh`, `lib/dev/usage.sh`

**Interfaces:**
- Consumes: env `DEV_EGRESS`.
- Produces: global `EGRESS_MODE` (open|closed) set by cmd_start; `DEVCONTAINER_EGRESS` passed to the container by `start_container`; `dev fw open|close|log|drops`.

- [ ] **Step 1: Resolve the mode in `cmd_start` (lib/dev/up.sh).** Replace the `--open` → `FW_DISABLED_START` plumbing. Add `--open`/`--closed` to the cmd_up/cmd_exec translation loops (they currently translate `--open`→FW_DISABLED_START; make both pass through literally to cmd_start). In `cmd_start`'s parse loop add:

```bash
      --open)   EGRESS_MODE=open;   shift ;;
      --closed) EGRESS_MODE=closed; shift ;;
```

Before the parse loop, seed the default from the env:

```bash
  # Precedence: explicit --open/--closed (below) > DEV_EGRESS > default open.
  case "${DEV_EGRESS:-open}" in
    open|closed) EGRESS_MODE="${DEV_EGRESS:-open}" ;;
    *) echo "Error: DEV_EGRESS must be 'open' or 'closed', got '$DEV_EGRESS'" >&2; exit 2 ;;
  esac
```

Delete the `FW_DISABLED_START`/`--open`-means-disabled logic and the `--open` + `--maint` special-case (lines ~161-165) — replace with: maintenance mode ignores egress mode (it never runs the firewall), so if `--closed` is combined with `--maint`, warn it's ignored (exit 0 path, not an error). `EGRESS_MODE` is a global (no `local`); add `EGRESS_MODE=open` to the defaults block in `dev` with a `# shellcheck disable=SC2034` note (consumed by start_container).

- [ ] **Step 2: Pass the mode to the container.** In `start_container` (lib/dev/lifecycle.sh), where env vars are added to `DOCKER_CMD`, add (closed only when not maintenance):

```bash
if [[ "$MAINTENANCE" != true ]]; then
  DOCKER_CMD+=(-e "DEVCONTAINER_EGRESS=${EGRESS_MODE:-open}")
fi
```

Grep for the old `DEVCONTAINER_FW_DISABLED` and remove its passing + the entrypoint branch that consumes it.

- [ ] **Step 3: Rename fw off/on → open/close (lib/dev/fw.sh).** In `cmd_fw`: the action set becomes `open|close|log|drops`; `close` maps to the firewall-init re-run (was `on`→`enable`), `open` maps to firewall-disable (was `off`). Update the strict-args branches, the rename-rejection arms (now `off`/`on` are the *old* names → print "renamed: use 'dev fw open'/'dev fw close'"), the action-error string to `(open|close|log|drops)`, and the dispatch case. Rename `fw_enable`→`fw_close`, `fw_off_running_only`→`fw_open_running_only`, and their `require_workspace_firewall_container "fw on"` / error-text labels to the new spellings.

- [ ] **Step 4: Make `fw log` mode-aware (lib/dev/fw.sh).** `fw_log` inspects the running container's mode (read the `DEVCONTAINER_EGRESS` env of the running container via `$RUNTIME exec … printenv`, or check for the tinyproxy log's existence) and:
  - closed → `exec … tail -F /var/log/tinyproxy.log` (today's behavior).
  - open → `exec … --user root sh -c 'tcpdump -i any -nn -l port 53 & tcpdump -i nflog:2 -nn -l'` (DNS names + FW-CONN connection log). Comment that URLs/headers aren't available without a proxy.

- [ ] **Step 5: `dev status` reports egress mode (lib/dev/status.sh).** In `status_workspace`'s per-container line, read `DEVCONTAINER_EGRESS` from the running container (default open) and print `egress=open|closed` alongside the existing fields. Maintenance containers print `egress=n/a`.

- [ ] **Step 6: Gate entrypoint plumbing on mode (entrypoint.sh).** Wrap the `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` exports + `/etc/profile.d/proxy.sh`, the `options no-aaaa` resolver edit, and the `~/.m2/settings.xml`+`~/.gradle/gradle.properties` seeding in `if [ "${DEVCONTAINER_EGRESS:-closed}" = closed ]; then … fi`. firewall-init.sh still runs unconditionally (it now self-branches). Remove the `DEVCONTAINER_FW_DISABLED` block.

- [ ] **Step 7: usage.sh** — document `--open` (default) / `--closed` on up/exec, `DEV_EGRESS` in the env section, and `fw open|close|log|drops`.

- [ ] **Step 8: Verify + shellcheck.** `bash scripts/test/scenarios/50-cli-verbs.sh` will fail until PR-B; instead hand-verify: `dev up --dry-run` (open), `DEV_EGRESS=closed dev up --dry-run`, `dev up --closed --open` (last wins → open), `DEV_EGRESS=bogus dev up` → exit 2, `dev fw disable` → renamed error. `mise x shellcheck -- shellcheck -x dev lib/dev/*.sh entrypoint.sh` clean.

- [ ] **Step 9: Commit.**

```bash
git add dev lib/dev/up.sh lib/dev/lifecycle.sh lib/dev/fw.sh lib/dev/status.sh lib/dev/usage.sh entrypoint.sh
git commit -m "feat(cli): open egress by default; --closed opt-in, DEV_EGRESS default, fw open/close"
```

---

## PR-B — tests

### Task 4: update scenario 50 + fix its tautology (I14)

**Files:**
- Modify: `scripts/test/scenarios/50-cli-verbs.sh`

- [ ] **Step 1:** Rename the fw assertions from off/on to open/close; assert the *rename* text so they bite (I14): `chk "fw off removed" 1 "renamed: use 'dev fw open'" ./dev fw off` and the `on` counterpart. Add: `chk "up --closed accepted" 0 '' ./dev up --closed --dry-run`; `chk "DEV_EGRESS closed resolves" 0 '' env DEV_EGRESS=closed ./dev up --dry-run`; `chk "DEV_EGRESS bogus rejected" 2 "open' or 'closed" env DEV_EGRESS=bogus ./dev up --dry-run`. Add `</dev/null` to `chk`'s command (M18 cheap fix, prevents an approval-prompt hang).
- [ ] **Step 2:** Run it → PASS. `bash scripts/test/scenarios/50-cli-verbs.sh`.
- [ ] **Step 3:** Commit `test(cli): scenario 50 covers open/closed surface and DEV_EGRESS`.

### Task 5: new scenario 52 — egress-mode behavioral contract

**Files:**
- Create: `scripts/test/scenarios/52-egress-modes.sh` (`# platform: linux`, `# privilege: user`)

- [ ] **Step 1:** Write the scenario. Real container, follows the correct assertion shape (probe result asserted, never `|| echo` on the outer `dev exec`). Assertions: (a) default `dev up`/`dev exec` reaches a non-allowlisted host — `out=$(./dev exec -- sh -c 'curl -sS -m8 -o /dev/null -w OK https://example.com || echo NOPE'); expect_grep "$out" OK`; (b) `./dev down` then `./dev exec --closed -- sh -c 'curl -sS -m8 ... || echo BLOCKED'` yields BLOCKED (example.com not allowlisted); (c) `DEV_EGRESS=closed ./dev exec -- …` also BLOCKED; (d) `DEV_EGRESS=closed ./dev exec --open -- …` reaches OK (flag overrides env); (e) metadata DROP holds in both modes: in each of open and closed, `curl -m5 http://169.254.169.254/ || echo METABLOCKED` yields METABLOCKED; (f) open-mode observability: after an `example.com` request, `timeout 3 ./dev fw log` output contains `example.com` (DNS) or its connection. `remember_container`+`restore_host` trap; `./dev down` between mode switches.
- [ ] **Step 2:** Run it → PASS (needs the base image; ~2 min). Investigate any failure against Task 2/3 code.
- [ ] **Step 3:** Commit `test: add scenario 52 asserting open/closed egress + link-local block`.

### Task 6: fix the C4 nested-egress test shape

**Files:**
- Modify: `scripts/test/scenarios/33-attack-nested-egress.sh`, `scripts/test/scenarios/34-attack-nested-egress-pind.sh`

- [ ] **Step 1:** Move the `|| echo BLOCKED` fallback *inside* the nested container command so an outer `dev exec` failure no longer masquerades as a pass (match the correct shape in `30-attack-sudo-iptables.sh:21`). For 33: `out=$(./dev exec --dind -- docker run --rm alpine:3.20 sh -c 'wget -T3 -q -O- https://example.com 2>&1 || echo NESTED_BLOCKED')` and assert `NESTED_BLOCKED`; guard that the outer exec itself succeeded (`|| { log_fail "outer exec failed: $out"; exit 1; }`). Same for 34 with podman. **Note in the commit body:** these run only in cells where `--dind`/`--pind` preflights pass; on this host they skip, so verification is via reading + the CI rootless/vm cells.
- [ ] **Step 2:** shellcheck both; run 33 (`bash scripts/test/scenarios/33-attack-nested-egress.sh` — will SKIP or FAIL-at-preflight on this host; confirm it no longer false-greens by reading the diff).
- [ ] **Step 3:** Commit `fix(test): nested-egress probes assert the inner result, not outer-exec failure (C4)`.

### Task 7: verify-firewall.sh metadata/link-local probe

**Files:**
- Modify: `scripts/verify-firewall.sh`

- [ ] **Step 1:** Add check 14 `link_local_blocked`: a direct connect to `http://169.254.169.254/` (curl `--noproxy '*' -m3`) must fail; runs in both modes (not gated on the proxy). Register it in the numbered list; bump the "N checks" self-count. Follow the existing check-registration shape in the file.
- [ ] **Step 2:** Run inside a container (open and closed) to confirm it passes both; `mise x shellcheck -- shellcheck -x scripts/verify-firewall.sh`.
- [ ] **Step 3:** Commit `test(firewall): probe the always-on link-local block in verify-firewall`.

---

## PR-C — independent code fixes

### Task 8: pind volume keep-id migration (I1)

**Files:**
- Modify: `lib/dev/volumes.sh` (migration block ~64-70)

- [ ] **Step 1:** Add the missing `PIND` branch mirroring the `DIND` one: when `PIND == true`, `migrate_volume_for_keepid devcontainer-pind`. Verify against the surrounding code that the volume name and guard match the dind pattern exactly.
- [ ] **Step 2:** Verify: `grep -n 'migrate_volume_for_keepid' lib/dev/volumes.sh` now shows a pind call; shellcheck. (Full behavioral test needs a rootless pind run, which this host can't do — note in the commit body; the CI rootless cell exercises pind.)
- [ ] **Step 3:** Commit `fix(volumes): keep-id migrate devcontainer-pind like devcontainer-dind (I1)`.

### Task 9: dev update prerelease-tag filter

**Files:**
- Modify: `lib/dev/update.sh` (latest-tag selection ~59-63)

- [ ] **Step 1:** Add install.sh's filter so a `-rc`/`-beta` tag never becomes the update target: insert `| grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$'` into the `ls-remote … | awk … | grep … | tail -1` pipeline (matching install.sh:48-51). Update the comment to note parity with install.sh.
- [ ] **Step 2:** Unit-test it: create `scripts/test/unit/test-dev-update-tagfilter.sh` that pipes a fixture tag list (`v1.0.0\nv1.1.0-rc.1\nv1.0.1`) through the same `grep -E … | tail -1` and asserts `v1.0.1` (not the rc). Run → `ok`.
- [ ] **Step 3:** shellcheck; commit `fix(update): ignore prerelease tags in dev update, matching install.sh`.

---

## PR-D — docs, written once against final behavior

### Task 10: SECURITY.md reframe

**Files:**
- Modify: `SECURITY.md`

- [ ] **Step 1:** Rewrite §1/§2 to lead with **isolation** as the always-on boundary; present egress confinement as **opt-in** (`--closed`/`DEV_EGRESS=closed`), not the default. Correct the absolute claims the review flagged: "unreachable, full stop" (§ formerly :45) becomes accurate to open-default. Document: the always-on link-local block; open mode's accepted residuals (arbitrary-internet reach — per threat model, fine; **the DNS-to-any channel C2 — explicitly documented as a known residual, not fixed**); `DEV_EXTRA_RUN_ARGS` as a boundary-bypassing knob (I2); the `allowlist.dind` multi-tenant-CDN exception (I4). Add `lib/dev/lifecycle.sh` to §3's reviewer reading order (I11).
- [ ] **Step 2:** shellcheck N/A (markdown); grep the file for `off|on` fw spellings and `--maintenance` → none remain. Commit `docs(security): reframe around isolation-first, egress confinement opt-in`.

### Task 11: README TLDR + observability feature + surface reconciliation

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** New top section: the closed-loop-dev framing + one-line install together (draft already reviewed with the user — the "can't break out of, and complete so it doesn't need to" framing). Include the two org-messaging points (agent closes the code loop / human owns the environment loop; commit-inside/push-outside is a review gate) and **headline egress observability** ("run agents wide-open, `dev fw log` shows every host they touched"). Update the firewall section to open-default + `--closed`; fix the stale JVM caveat (entrypoint already seeds m2/gradle — but now only in closed mode, so reword accordingly); replace "three files, nothing hidden" and "that's the whole security boundary" with accurate framing (M3/M9); fix `--maintenance`→`--maint` prose (I9); update every `fw off/on`→`open/close` and the pind-volume claim (I1 is fixed, so the claim is now true — verify wording).
- [ ] **Step 2:** grep README for `fw off|fw on|--maintenance|--open.*firewall.*torn` → none. Commit `docs(readme): open-default TLDR, observability feature, surface reconciliation`.

### Task 12: CLAUDE.md + architecture.html + ci-testing baseline

**Files:**
- Modify: `CLAUDE.md`, `docs/architecture.html`, `docs/ci-testing.md`

- [ ] **Step 1: CLAUDE.md** — egress open-default + `DEV_EGRESS`; fix the approval-gate description (I6: the live workspace file is never read directly; only the approved snapshot); add the three undocumented modules to the architecture list (I11: `lifecycle.sh`, `image.sh`, `checks-catalog-nested.sh`); `fw open/close`; `--maint` spelling.
- [ ] **Step 2: docs/architecture.html** — replace the four stale mode cards (`./dev`, `./dev --maintenance|--dind|--pind` at ~542-554, and `./dev → docker run` at ~443) with verb spellings and the egress-mode note (I10).
- [ ] **Step 3: docs/ci-testing.md** — reconcile the rootless baseline with reality (C3): CI is now the source of truth; replace the stale 13/14/4 table with a pointer to the live CI cells + CLAUDE.md's measured numbers, and drop the contradicting root-cause narrative. Grep both docs for `fw off|fw on` → none.
- [ ] **Step 4:** Commit `docs: reconcile CLAUDE.md, architecture.html, ci-testing baselines with open-default reality`.

### Task 13: approval-gate restart hint (I7) + final matrix

**Files:**
- Modify: `lib/dev/approval.sh` (~79)

- [ ] **Step 1:** When an allowlist change is (re)approved and the container is already running, print: `Approved. Restart for the new entries to take effect: 'dev down && dev up', or 'dev fw close' to re-init the filter in place.` (verb-correct; I7). shellcheck.
- [ ] **Step 2: Full matrix.** `sudo bash scripts/test/run-all.sh` (long). Expect pass/skip only; the dind/pind cells skip on this host (documented). New scenario 52 present, 50 green, verify-firewall shows the new check. Investigate any unexpected fail; fix small or report BLOCKED.
- [ ] **Step 3:** Commit `feat(cli): hint restart after allowlist approval on a running container (I7)`; if matrix fixes were needed, a separate `fix(test): …`.

## Self-review notes (applied)

- Spec coverage: mode resolution (T3), open/closed firewall + logging (T2), link-local block (T1/T2/T7), fw rename + mode-aware log (T3), entrypoint gating (T3), status (T3), scenario 50/52 + verify probe (T4/5/7), SECURITY/README/CLAUDE/architecture reframe + observability feature (T10-12). Fix batch: C1 (T1), C4 (T6), pind volume (T8), update tag filter (T9), doc reconciliation incl. C3 (T10-12), I7 (T13). C2 documented-not-fixed (T10) per spec.
- Naming consistency: `EGRESS_MODE` (host global), `DEVCONTAINER_EGRESS` (container env), `DEV_EGRESS` (host env), `install_baseline_blocks`, `allowlist_to_filter`, `fw open|close` used identically across tasks.
- Implementer judgment call flagged in-task: exact env-read mechanism for `fw log`/`status` mode detection (printenv vs marker file) — pick per what the running container exposes; both are named.
