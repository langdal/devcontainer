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
