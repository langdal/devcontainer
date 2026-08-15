#!/bin/bash
# scripts/test/run-all.sh
#
# VM-side orchestrator for the DinD test matrix.
#
# Usage:
#   bash scripts/test/run-all.sh
#
# Preconditions on the VM:
#   - sudo without password prompt (or run as root).
#   - One of {docker, podman} installed (others may be installed by scenarios).
#   - Internet access through the host firewall (registries reachable on 443).
#   - >=10 GB free disk for images and named volumes.
#
# Each scenario script under scripts/test/scenarios/ is run in its own
# subshell. PASS/FAIL/SKIP is determined by the lines emitted by
# log_pass/log_fail/log_skip.
set -u

# Remove any root-owned log files left over from a previous run that
# was invoked directly as root; otherwise the post-drop user can't
# overwrite them. Cheap and safe regardless.
if [ "$(id -u)" -eq 0 ]; then
    rm -f "$(dirname "$0")/last-run.log" "$(dirname "$0")/last-summary.log"
fi

# Drop privileges first if invoked via sudo. The orchestrator does no
# work that requires root (it explicitly invokes sudo for apt installs);
# running ./dev as root would now hit dev's UID 0 refusal, and any
# artifacts left behind would be root-owned. Must run before anything
# that touches the workspace path.
# shellcheck source=scripts/test/lib/privilege.sh
. "$(dirname "$0")/lib/privilege.sh"
drop_privs_if_root "$@"

# shellcheck source=scripts/test/lib/runtime.sh
. "$(dirname "$0")/lib/runtime.sh"
RT="$(host_runtime)"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$WORKSPACE" || exit 1

LOG_DIR="$WORKSPACE/scripts/test"
LAST_LOG="$LOG_DIR/last-run.log"
SUMMARY_LOG="$LOG_DIR/last-summary.log"

# Ensure clean log on each run.
: > "$LAST_LOG"
: > "$SUMMARY_LOG"

color() { :; }
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; RESET=""
fi

echo "DinD test orchestrator"
echo "Workspace: $WORKSPACE"
echo "Log:       $LAST_LOG"
echo

# ---- Preconditions ----
if ! sudo -n true 2>/dev/null; then
    echo "FATAL: this orchestrator needs passwordless sudo (or run as root)." | tee -a "$LAST_LOG"
    exit 1
fi

# ---- Auto-install runtimes if missing ----
# The orchestrator needs at least docker (or podman) on PATH so the dev
# script can build images. Install via apt on Debian/Ubuntu hosts.
if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        echo "Installing docker.io + docker-buildx + podman..." | tee -a "$LAST_LOG"
        sudo apt-get update -qq >/dev/null 2>&1
        sudo apt-get install -y --no-install-recommends docker.io docker-buildx podman 2>&1 | tail -3 | tee -a "$LAST_LOG"
        sudo systemctl reset-failed docker.service docker.socket 2>/dev/null || true
        sudo systemctl start docker 2>/dev/null || true
    else
        echo "FATAL: no docker/podman on PATH and apt-get not available." | tee -a "$LAST_LOG"
        exit 1
    fi
fi
if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    echo "FATAL: install attempt finished but no runtime is on PATH." | tee -a "$LAST_LOG"
    exit 1
fi

# A runtime on PATH is not the same as a runtime that can BUILD. docker needs
# the buildx plugin for the Dockerfile's BuildKit features, and the gate above
# only fires when NO runtime exists at all — so a host with docker and no
# buildx sailed past it, failed every image build, and still produced a
# summary that read as clean (2026-08-15). Install it on its own terms.
if command -v docker >/dev/null 2>&1 && ! docker buildx version >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        echo "docker is present but 'docker buildx' is not; installing docker-buildx..." | tee -a "$LAST_LOG"
        sudo apt-get update -qq >/dev/null 2>&1
        sudo apt-get install -y --no-install-recommends docker-buildx 2>&1 | tail -3 | tee -a "$LAST_LOG"
    fi
fi

# ---- Readiness gate: let `dev doctor` decide whether this host can run ----
# The orchestrator used to keep its own idea of a working host, and it drifted
# from dev's — which is how the buildx gap above went unnoticed through a whole
# review. There is now one source of truth, so ask it. A host the doctor will
# not certify produces meaningless suite results, so refuse rather than report
# a tally nobody can trust.
if [ -x "$WORKSPACE/dev" ]; then
    if ! doctor_out=$("$WORKSPACE/dev" doctor 2>&1); then
        {
            echo "FATAL: 'dev doctor' refuses this host, so suite results would be meaningless."
            echo "$doctor_out"
        } | tee -a "$LAST_LOG"
        exit 1
    fi
    echo "dev doctor: host certified." | tee -a "$LAST_LOG"
fi

# ---- Inject a deterministic DNS for the test run ----
# Test scenarios are sensitive to two failure modes from the host's
# default resolver: (1) AAAA-hang on hosts whose resolver drops IPv6
# queries silently — every glibc getaddrinfo() inside a default-bridge
# container stalls ~6s, which breaks tinyproxy and every nested-container
# DNS chain; (2) intermittent flakiness on auth.docker.io that surfaces
# as random "Unable to connect" failures partway through the suite.
# Both are eliminated by pinning the test containers' DNS to 8.8.8.8 +
# 1.1.1.1 via DEV_EXTRA_RUN_ARGS, which the dev script appends to its
# `docker run` invocation. This only affects the orchestrator run; normal
# ./dev usage is unchanged. Override by exporting DEV_EXTRA_RUN_ARGS
# before invoking, or set SKIP_TEST_DNS_OVERRIDE=1 to keep the host's
# resolver.
if [ -z "${DEV_EXTRA_RUN_ARGS:-}" ] && [ -z "${SKIP_TEST_DNS_OVERRIDE:-}" ]; then
    echo "Setting DEV_EXTRA_RUN_ARGS=--dns=8.8.8.8 --dns=1.1.1.1 for deterministic test DNS." | tee -a "$LAST_LOG"
    echo "  (set SKIP_TEST_DNS_OVERRIDE=1 to keep the host's resolver.)" | tee -a "$LAST_LOG"
    export DEV_EXTRA_RUN_ARGS="--dns=8.8.8.8 --dns=1.1.1.1"
fi

# ---- Build the base, :dind, and :pind images up front so scenarios don't race the build ----
echo "Building images..."
if ! ./dev up --build --dry-run >/dev/null 2>&1; then
    : # dry-run sanity probe is best-effort
fi
if ! ./dev exec --build -- true 2>&1 | tee -a "$LAST_LOG"; then
    echo "FATAL: failed to build base image" | tee -a "$LAST_LOG"
    exit 1
fi
"$RT" rm -f "dev-$(basename "$WORKSPACE")" 2>/dev/null || true
if ! ./dev exec --build --dind -- true 2>&1 | tee -a "$LAST_LOG"; then
    echo "FATAL: failed to build :dind image" | tee -a "$LAST_LOG"
    exit 1
fi
"$RT" rm -f "dev-$(basename "$WORKSPACE")"-dind 2>/dev/null || true
if ! ./dev exec --build --pind -- true 2>&1 | tee -a "$LAST_LOG"; then
    echo "FATAL: failed to build :pind image" | tee -a "$LAST_LOG"
    exit 1
fi
"$RT" rm -f "dev-$(basename "$WORKSPACE")"-pind 2>/dev/null || true

# ---- Walk scenarios ----
PASS=0; FAIL=0; SKIP=0
declare -a FAIL_NAMES=()
declare -a SKIP_NAMES=()

for scenario in "$LOG_DIR"/scenarios/[0-9]*.sh; do
    name=$(basename "$scenario" .sh)
    echo
    echo "=== Running $name ==="
    {
        echo
        echo "=== $name ==="
    } >> "$LAST_LOG"
    if out=$(bash "$scenario" 2>&1); then
        # Scenario exited 0 — last log line tells us PASS or SKIP.
        if echo "$out" | grep -q '^\[PASS\]'; then
            PASS=$((PASS+1))
            echo "${GREEN}PASS${RESET}  $name"
            tail -1 <<< "$out" >> "$SUMMARY_LOG"
        elif echo "$out" | grep -q '^\[SKIP\]'; then
            SKIP=$((SKIP+1))
            SKIP_NAMES+=("$name")
            echo "${YELLOW}SKIP${RESET}  $name"
            tail -1 <<< "$out" >> "$SUMMARY_LOG"
        else
            # Exit 0 but no PASS/SKIP marker — count as fail for hygiene.
            FAIL=$((FAIL+1))
            FAIL_NAMES+=("$name")
            echo "${RED}FAIL${RESET}  $name (no PASS/SKIP marker emitted)"
        fi
    else
        FAIL=$((FAIL+1))
        FAIL_NAMES+=("$name")
        echo "${RED}FAIL${RESET}  $name (exit non-zero)"
    fi
    echo "$out" >> "$LAST_LOG"
done

echo
echo "===================================================="
echo "Summary: ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}, ${YELLOW}${SKIP} skipped${RESET}"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed scenarios:"
    for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
fi
if [ "$SKIP" -gt 0 ]; then
    echo "Skipped scenarios:"
    for n in "${SKIP_NAMES[@]}"; do echo "  - $n"; done
fi
echo "Full log: $LAST_LOG"
echo "===================================================="

[ "$FAIL" -eq 0 ]
