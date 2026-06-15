# shellcheck shell=bash
# allowlist_merge FILE...  ->  deduped, sorted hostnames on stdout.
# Strips `#` comments and all whitespace; skips blank lines and missing files.
# (Same normalisation the legacy firewall-init.sh used.)
allowlist_merge() {
  local f
  for f in "$@"; do
    if [[ -f "$f" ]]; then cat "$f"; fi
  done | sed 's/#.*//' | tr -d ' \t' | awk 'NF' | sort -u
}
