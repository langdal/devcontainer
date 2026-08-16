#!/usr/bin/env bash
# Unit: dev doctor's report and exit contract. Runs against a scratch cwd so
# the workspace name never collides with this checkout.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
doctor() { (cd "$WORK" && "$ROOT/dev" doctor "$@" </dev/null 2>&1); }
fail() { echo "FAIL: $1"; exit 1; }

# Runs at all, and names itself.
out=$(doctor); rc=$?
echo "$out" | grep -qi 'Host' || fail "no Host summary line: $out"

# Exit code is 0 or 1 — never a stack trace or 2 — on a normal host.
[ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || fail "unexpected exit $rc: $out"

# Anchor on a check that applies EVERYWHERE. Do not anchor on buildx: it is
# scoped to docker, and a host whose DOCKER_HOST points at a podman socket
# resolves RUNTIME=podman, so buildx is correctly absent there. Asserting it
# would make this test pass or fail on the tester's runtime.
echo "$out" | grep -q 'supported platform' \
    || fail "phase-0 checks missing from report: $out"

# A summary line accounts for every check.
echo "$out" | grep -qE '[0-9]+ (blocking|passed)' || fail "no summary tally: $out"

# Unknown argument is a usage error, exit 2 — matches the verb grammar.
out=$(doctor --bogus); rc=$?
[ "$rc" -eq 2 ] || fail "bad flag should exit 2, got $rc: $out"

# --dind is accepted (it promotes nested checks to blocking).
doctor --dind >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || fail "--dind should be accepted, got $rc"

# Non-tty output is plain ASCII: this gets pasted into chat.
out=$(doctor)
echo "$out" | LC_ALL=C grep -q '[^ -~]' && fail "non-ASCII leaked into non-tty output"

# Nothing here required a running container or a built image.
echo "$out" | grep -qi 'no such container' && fail "doctor touched a container"

# block-in-doctor (buildx) must still be blocking FOR DOCTOR even though
# cmd_start never blocks on it (lib/dev/image.sh guards the real build site
# instead) — a host that cannot build is never "ready". Fully mocked so this
# does not depend on the test host's actual runtime/buildx situation: real
# detect_runtime/_chk_runtime_present are shadowed so nothing here shells out.
(
  set -u
  # shellcheck source=lib/dev/runtime.sh
  . "$ROOT/lib/dev/runtime.sh"
  # shellcheck source=lib/dev/checks.sh
  . "$ROOT/lib/dev/checks.sh"
  # shellcheck source=lib/dev/checks-catalog.sh
  . "$ROOT/lib/dev/checks-catalog.sh"
  # shellcheck source=lib/dev/doctor.sh
  . "$ROOT/lib/dev/doctor.sh"
  detect_runtime()        { RUNTIME=docker; RUNTIME_ARGS=""; }
  # shellcheck disable=SC2329  # invoked indirectly via run_check's dynamic dispatch
  _chk_runtime_present()  { return 0; }
  _doc_header()           { :; }   # avoid shelling out to a real runtime
  export DEV_FAKE_OS=Linux DEV_FAKE_CMDS=docker
  # shellcheck disable=SC2119  # deliberately no flags: the bare `dev doctor` path
  bout=$(cmd_doctor 2>&1); brc=$?
  echo "$bout" | grep -q 'docker buildx present' \
    || { echo "FAIL: buildx row missing from mocked report: $bout"; exit 1; }
  [ "$brc" -eq 1 ] \
    || { echo "FAIL: missing buildx must exit 1 (block-in-doctor), got $brc: $bout"; exit 1; }
) || fail "doctor block-in-doctor coverage failed"


# --- doctor must survive hosts where detect_runtime would refuse -----------
#
# detect_runtime calls `exit 1` on three host shapes. When it does so from
# inside cmd_doctor, the user gets that one error and NOTHING else: no header,
# no phase-0 rows, no tally — and doctor's whole promise is that it works on a
# machine where nothing is set up yet. These are exactly the machines that need
# it most, including `not-docker-desktop`'s own target host.
#
# A sandbox PATH with no podman, so detect_runtime's Darwin branch would refuse.
SANDBOX="$WORK/bin"; mkdir -p "$SANDBOX"
# Resolve each tool via PATH rather than assuming /usr/bin. macOS puts bash,
# sh, cat, rm, df and date in /bin and sysctl in /usr/sbin, so the hardcoded
# form built a sandbox with no shell in it: `dev` (#!/usr/bin/env bash) could
# not start, the sandboxed doctor produced no output at all, and the three
# assertions below failed for a reason that had nothing to do with doctor.
for b in bash sh sed awk grep cat cut tr uname id basename dirname mktemp rm \
         printf df sysctl head tail sort wc stat date curl docker; do
    p=$(command -v "$b" 2>/dev/null) || continue
    [ "${p#/}" != "$p" ] || continue   # a shell builtin, not a file on disk
    ln -sf "$p" "$SANDBOX/$b"
done

doctor_sandboxed() { (cd "$WORK" && PATH="$SANDBOX" "$ROOT/dev" doctor </dev/null 2>&1); }

# 1. macOS with docker but no podman — detect_runtime's Darwin branch refuses.
out=$(DEV_FAKE_OS=Darwin doctor_sandboxed); rc=$?
echo "$out" | grep -qE '[0-9]+ (blocking|passed)' \
    || fail "macOS-without-podman: doctor produced no tally, so it bailed mid-report: $out"
echo "$out" | grep -q 'supported platform' \
    || fail "macOS-without-podman: phase-0 rows missing from report: $out"
[ "$rc" -eq 1 ] || fail "macOS-without-podman should exit 1 (blocking), got $rc: $out"

# 2. DEV_RUNTIME naming something absent — detect_runtime refuses.
out=$(cd "$WORK" && DEV_RUNTIME=nosuchruntime "$ROOT/dev" doctor </dev/null 2>&1); rc=$?
echo "$out" | grep -qE '[0-9]+ (blocking|passed)' \
    || fail "bad DEV_RUNTIME: doctor produced no tally, so it bailed mid-report: $out"
[ "$rc" -eq 1 ] || fail "bad DEV_RUNTIME should exit 1 (blocking), got $rc: $out"

# 3. The report must name the actual problem, not just fail silently.
echo "$out" | grep -qi 'DEV_RUNTIME' \
    || fail "bad DEV_RUNTIME: report never mentions DEV_RUNTIME: $out"

echo "PASS: doctor report and exit contract"
