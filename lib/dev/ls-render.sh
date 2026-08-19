# shellcheck shell=bash
# lib/dev/ls-render.sh — presentation half of `dev ls`: turns the canonical rows
# lib/dev/ls.sh collected into aligned tables and prints the delete-me hint.
# Split out of ls.sh once that file passed its line budget, the same way
# checks-catalog-nested.sh was split out of checks-catalog.sh. Discovery decides
# WHAT is on this machine; this decides how it reads.
# Sourced by dev; not executed directly.

# Print one section: $1 title, $2 rows, $3 base field indices, $4 base headers,
# $5 whether this section has a SIZE column. Field 5 (SIZE) is shown only under
# --sizes and field 6 (STORAGE) only when a second storage exists; the rows
# always carry both.
_ls_print_section() {
  local title="$1" rows="$2" cols="$3" hdr="$4" has_size="$5"
  if [[ "$has_size" == true && "$LS_SIZES" == true ]]; then
    cols="${cols},5"; hdr="${hdr}"$'\tSIZE'
  fi
  if [[ -n "$DIND_RUNTIME_ARGS" ]]; then
    cols="${cols},6"; hdr="${hdr}"$'\tSTORAGE'
  fi
  echo "$title"
  if [[ -z "$rows" ]]; then
    echo "  (none)"
    return 0
  fi
  printf '%s' "$rows" | _ls_table "$cols" "$hdr"
}

# "Which of these can I delete" is the question this verb exists to answer, so
# name the per-workspace home volumes no container is using. Read-only: the
# removal command is printed, never run.
_ls_print_hints() {
  local orphans
  orphans=$(printf '%s' "$_LS_VOLUMES" \
    | awk -F'\t' '$3 == "workspace" && $4 == "no" { print $2 }')
  [[ -n "$orphans" ]] || return 0
  echo
  echo "No container is using these per-workspace home volumes:"
  printf '%s\n' "$orphans" | sed 's/^/  /'
  echo "Remove one from its own project directory with 'dev reset', or directly:"
  echo "  $RUNTIME volume rm <name>"
}

# Render tab-delimited rows (stdin) as an aligned table, indented two spaces.
# $1 = comma-separated 1-based field indices to show; $2 = tab-separated headers
# for exactly those fields. Widths span headers and rows together; the last
# shown column is left unpadded so one wide value cannot pull every line out.
# Padding counts bytes, which is why the cells stay ASCII — a multibyte dash
# would misalign the column.
_ls_table() {
  awk -F'\t' -v cols="$1" -v hdr="$2" '
    function pad(s, w) { return w > 0 ? sprintf("%-" w "s", s) : s }
    function render(f,   i, out) {
      out = ""
      for (i = 1; i <= n; i++) {
        out = out pad(f[i], (i < n ? w[i] : 0))
        if (i < n) out = out "  "
      }
      return "  " out
    }
    BEGIN { n = split(cols, c, ","); split(hdr, head, "\t")
            for (i = 1; i <= n; i++) w[i] = length(head[i]) }
    { rows[++r] = $0
      for (i = 1; i <= n; i++) if (length($(c[i])) > w[i]) w[i] = length($(c[i])) }
    END {
      print render(head)
      for (j = 1; j <= r; j++) {
        split(rows[j], raw, "\t")
        for (i = 1; i <= n; i++) cells[i] = raw[c[i]]
        print render(cells)
      }
    }'
}
