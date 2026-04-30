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

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$WORKSPACE"

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

# ---- Build both images up front so scenarios don't race the build ----
echo "Building images..."
if ! ./dev --build --dry-run >/dev/null 2>&1; then
    : # dry-run sanity probe is best-effort
fi
if ! ./dev --build -- true 2>&1 | tee -a "$LAST_LOG"; then
    echo "FATAL: failed to build base image" | tee -a "$LAST_LOG"
    exit 1
fi
docker rm -f dev-$(basename "$WORKSPACE") 2>/dev/null || true
if ! ./dev --build --dind -- true 2>&1 | tee -a "$LAST_LOG"; then
    echo "FATAL: failed to build :dind image" | tee -a "$LAST_LOG"
    exit 1
fi
docker rm -f dev-$(basename "$WORKSPACE")-dind 2>/dev/null || true

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
