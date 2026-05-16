# scripts/test/lib/assert.sh
# shellcheck shell=bash
#
# Logging + assertion helpers for scenario scripts. Source this at the top
# of each scenario.
#
# Conventions:
#   - log_pass / log_fail / log_skip emit a single line and update the
#     global SCENARIO_RESULT (PASS / FAIL / SKIP).
#   - Each scenario should exit 0 on PASS or SKIP, non-zero on FAIL.
#   - The orchestrator captures stdout per-scenario and parses these lines.

# Drop privileges if a scenario was invoked as root via `sudo bash …`.
# Idempotent — when the orchestrator already dropped privileges, this
# is a no-op. Must run before any state-touching code in the scenario.
# shellcheck source=scripts/test/lib/privilege.sh
. "$(dirname "${BASH_SOURCE[0]}")/privilege.sh"
drop_privs_if_root "$@"

export SCENARIO_RESULT=""

_scenario_name() {
    basename "${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-unknown}}" .sh
}

log_pass() {
    printf '[PASS] %-50s  %s\n' "$(_scenario_name)" "${1:-}"
    SCENARIO_RESULT="PASS"
}

log_fail() {
    printf '[FAIL] %-50s  %s\n' "$(_scenario_name)" "${1:-}"
    SCENARIO_RESULT="FAIL"
}

log_skip() {
    printf '[SKIP] %-50s  %s\n' "$(_scenario_name)" "${1:-}"
    SCENARIO_RESULT="SKIP"
}

# Assert that $1 (a string) matches regex $2.
expect_grep() {
    local haystack="$1" needle="$2"
    echo "$haystack" | grep -Eq "$needle"
}

# Run a command; expect it to exit non-zero. Echo "ok" on success.
expect_exit_nonzero() {
    if "$@"; then
        return 1
    fi
    return 0
}

# Read scenario front-matter platform tag. Returns "linux" / "darwin" / "any".
scenario_platform() {
    local f="${BASH_SOURCE[1]}"
    local tag
    tag=$(awk '/^# platform:/{print $3; exit}' "$f" 2>/dev/null)
    echo "${tag:-any}"
}

# Skip the scenario if the host is not the expected platform.
require_platform() {
    local want="$1"
    local got
    got=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$want" in
        linux)  [[ "$got" == "linux"  ]] || { log_skip "scenario is $want only (host is $got)"; exit 0; } ;;
        darwin) [[ "$got" == "darwin" ]] || { log_skip "scenario is $want only (host is $got)"; exit 0; } ;;
        any)    : ;;
        *)      log_fail "unknown platform tag: $want"; exit 1 ;;
    esac
}
