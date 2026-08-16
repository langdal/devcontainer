# shellcheck shell=bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
eval "$(awk '/^allowlist_to_filter\(\) \{/,/^\}/' "$ROOT/firewall-init.sh")"
