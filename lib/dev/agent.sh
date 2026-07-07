# shellcheck shell=bash
# lib/dev/agent.sh — `dev agent {add,list,rm}` handlers. Copy a curated,
# per-agent allowlist of credentials + settings from the host into this
# workspace's home volume. One-way snapshot: never a host mount, never baked
# into an image. Sourced by dev; not executed directly.

# Known agent names, in display order. 'all' is a pseudo-name expanded by
# _agent_expand; it is intentionally NOT in this list.
AGENT_KNOWN=(claude opencode pi)

# _agent_is_known <name> -> 0 if name is a supported agent, else 1.
_agent_is_known() {
  local n
  for n in "${AGENT_KNOWN[@]}"; do
    [[ "$n" == "$1" ]] && return 0
  done
  return 1
}

_agent_usage() {
  cat <<'EOF'
Usage: dev agent add  <name>... | all    Copy an agent's creds+settings in
       dev agent list                    Show host / injected status
       dev agent rm   <name>... | all    Remove an agent's injected files

Agents: claude, opencode, pi

'add' is a one-way snapshot into this workspace's home volume (never a host
mount, never baked into an image). Re-run 'add' to refresh (tokens expire).
Preview with 'dev agent add <name> --dry-run'. Remove with 'dev agent rm'
or wipe the whole home volume with 'dev reset'.
EOF
}

# Stub handlers — implemented in later tasks. Each receives the argv that
# followed the action word (names and/or --dry-run).
_agent_add()  { echo "dev agent add: not yet implemented" >&2; exit 1; }
_agent_list() { echo "dev agent list: not yet implemented" >&2; exit 1; }
_agent_rm()   { echo "dev agent rm: not yet implemented" >&2; exit 1; }
