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
  _chk_runtime_present()  { return 0; }
  _doc_header()           { :; }   # avoid shelling out to a real runtime
  export DEV_FAKE_OS=Linux DEV_FAKE_CMDS=docker
  # shellcheck disable=SC2119  # deliberately no flags: the bare `dev doctor` path
  bout=$(cmd_doctor 2>&1); brc=$?
  echo "$bout" | grep -q 'docker buildx present' \
    || { echo "FAIL: buildx row missing from mocked report: $bout"; exit 1; }
  [ "$brc" -eq 1 ] \
    || { echo "FAIL: missing buildx must exit 1 (block-in-doctor), got $brc: $bout"; exit 1; }
) || fail "doctor block-if-building coverage failed"

echo "PASS: doctor report and exit contract"
