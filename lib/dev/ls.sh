# shellcheck shell=bash
# lib/dev/ls.sh — `dev ls`: a machine-wide, read-only inventory of the dev
# containers and devcontainer-* volumes this tool has left on the host. Every
# other verb is scoped to the current workspace's four container names; this one
# answers "what is here, and what can I delete". Nothing is destroyed —
# container-less volumes are named, with the command to remove them.
# Sourced by dev; not executed directly.

# cmd_ls: the `dev ls` verb (alias `dev list`).
cmd_ls() {
  LS_SIZES=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sizes)   LS_SIZES=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*)
        echo "Error: unknown option for 'dev ls': '$1'" >&2
        echo "       Only --sizes is accepted. Run 'dev --help' for usage." >&2
        exit 2 ;;
      *)
        echo "Error: 'dev ls' takes no arguments (got '$1')." >&2
        exit 2 ;;
    esac
  done
  detect_runtime
  # Unlike `dev status` and `dev doctor`, listing genuinely needs the engine: on
  # macOS a stopped podman machine has to say so, rather than print an empty
  # table that reads as "nothing left on this machine".
  # shellcheck disable=SC2034  # consumed by ensure_runtime_ready
  NEEDS_ENGINE=true
  ensure_runtime_ready
  _resolve_workspace_names
  ls_report
  exit 0
}

# Collect every storage, then print.
#
# Rows accumulate as tab-delimited lines rather than printing as they are found:
# column widths are only known once every row is in hand, and bash 3.2 (macOS)
# has no associative arrays to key them by. Every row carries EVERY field and
# _ls_table picks the columns that apply, so the row format never varies with
# the host or the flags.
#   _LS_CONTAINERS  mark, mode, name, state, workspace, storage
#   _LS_VOLUMES     mark, name, scope, in-use, size, storage
#   _LS_INUSE       " <storage>:<volume> " per volume a listed container mounts.
#                   Volume names cannot contain spaces, so a glob test is exact.
#   _LS_DF          cached `system df -v` for the storage being scanned.
#
# On macOS+podman the --dind/--pind containers and volumes live in the rootful
# connection while normal/maint live in the default rootless one: two genuinely
# separate storages, so one shared volume name can exist in both and each row
# says which it came from. DIND_RUNTIME_ARGS is empty on every other host, where
# the second pass is skipped and the STORAGE column never appears.
ls_report() {
  _LS_CONTAINERS=""
  _LS_VOLUMES=""
  _LS_INUSE=" "
  _LS_DF=""
  _LS_MARKED=false
  _ls_scan_storage "" "default"
  if [[ -n "$DIND_RUNTIME_ARGS" ]]; then
    _ls_scan_storage "$DIND_RUNTIME_ARGS" "rootful"
  fi
  if [[ -z "$_LS_CONTAINERS" && -z "$_LS_VOLUMES" ]]; then
    echo "No dev containers or devcontainer-* volumes on this machine."
    echo "'dev up' in a project directory creates them."
    return 0
  fi
  _ls_print_section "CONTAINERS" "$_LS_CONTAINERS" "1,2,3,4,5" \
    $' \tMODE\tNAME\tSTATE\tWORKSPACE' false
  echo
  _ls_print_section "VOLUMES" "$_LS_VOLUMES" "1,2,3,4" \
    $' \tNAME\tSCOPE\tIN USE' true
  if [[ "$_LS_MARKED" == true ]]; then
    echo
    echo "* belongs to this directory's workspace (${WORKSPACE_BASENAME})"
  fi
  _ls_print_hints
}

# Walk one storage ($1 = connection args, empty for the default; $2 = STORAGE
# label). Containers first: the volume table's in-use column is derived from
# their mounts, not guessed from the naming scheme.
_ls_scan_storage() {
  _ls_scan_containers "$1" "$2"
  if [[ "$LS_SIZES" == true ]]; then
    _ls_load_sizes "$1"
  fi
  _ls_scan_volumes "$1" "$2"
}

# Collect this storage's dev containers. The name filter is applied loosely
# server-side (docker and podman disagree about anchoring) and strictly here.
_ls_scan_containers() {
  local args="$1" storage="$2"
  local name state info img keepid ws mode mark tab
  tab=$'\t'
  while IFS="$tab" read -r name state; do
    [[ -n "$name" ]] || continue
    case "$name" in dev-*) ;; *) continue ;; esac
    info=$(_ls_inspect_container "$args" "$name") || continue
    img=""; keepid=""; ws="-"
    _ls_parse_container_info "$info" "$storage"
    _ls_is_dev_container "$img" "$keepid" || continue
    mode=$(_ls_mode_for "$name")
    mark=" "
    if _ls_is_current_workspace_container "$name"; then
      mark="*"; _LS_MARKED=true
    fi
    _LS_CONTAINERS="${_LS_CONTAINERS}${mark}${tab}${mode}${tab}${name}${tab}${state}${tab}${ws}${tab}${storage}
"
  done < <(_ls_container_candidates "$args")
}

# Names + human-readable state for one storage. {{"\t"}} rather than a literal
# \t: the Go template emits the tab itself, which both CLIs render identically.
_ls_container_candidates() {
  # shellcheck disable=SC2086  # intentional word-splitting of $1
  $RUNTIME $1 ps -a --filter name=dev- \
    --format '{{.Names}}{{"\t"}}{{.Status}}' 2>/dev/null || true
}

# Image, dev.keepid label and mounts as a line-based record: line 1 image, line
# 2 label, then one "type|name|destination|source" line per mount. Fails when
# the container vanished between the ps and here.
_ls_inspect_container() {
  # shellcheck disable=SC2086  # intentional word-splitting of $1
  $RUNTIME $1 inspect "$2" --format '{{.Config.Image}}
{{index .Config.Labels "dev.keepid"}}
{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Destination}}|{{.Source}}
{{end}}' 2>/dev/null
}

# Parse that record. Assigns img/keepid/ws in the CALLER's locals (declared
# there) and appends this container's volumes to _LS_INUSE under storage $2.
_ls_parse_container_info() {
  local storage="$2" line i=0 mtype mname mdest msrc rest
  while IFS= read -r line; do
    i=$((i + 1))
    if [[ "$i" -eq 1 ]]; then img="$line"; continue; fi
    if [[ "$i" -eq 2 ]]; then keepid="$line"; continue; fi
    [[ -n "$line" ]] || continue
    mtype="${line%%|*}"; rest="${line#*|}"
    mname="${rest%%|*}"; rest="${rest#*|}"
    mdest="${rest%%|*}"; msrc="${rest#*|}"
    # The real host directory behind this container — what disambiguates two
    # workspaces that share a basename.
    if [[ "$mdest" == "/workspace" ]]; then
      ws="$msrc"
    fi
    if [[ "$mtype" == "volume" && -n "$mname" ]]; then
      _LS_INUSE="${_LS_INUSE}${storage}:${mname} "
    fi
  done <<EOF
$1
EOF
}

# Is this dev-* container one of ours? The name alone is not proof — a user's
# unrelated `dev-api` matches it too. Every container dev creates carries the
# dev.keepid label (lib/dev/lifecycle.sh); one created before that label existed
# is recognised by its image. A missing label renders as "<no value>", not empty.
_ls_is_dev_container() {
  case "$2" in ''|'<no value>') ;; *) return 0 ;; esac
  case "$1" in *"$IMAGE_NAME"*) return 0 ;; esac
  return 1
}

# Mode from the name suffix. A workspace directory named "api-dind" produces
# dev-api-dind and reads as dind mode for workspace "api" — an ambiguity
# inherent to the dev-<dir>[-mode] scheme, and why the WORKSPACE column shows
# the container's real bind-mount source.
_ls_mode_for() {
  case "$1" in
    *-maint) echo "maint" ;;
    *-dind)  echo "dind" ;;
    *-pind)  echo "pind" ;;
    *)       echo "normal" ;;
  esac
}

_ls_is_current_workspace_container() {
  case "$1" in
    "$NORMAL_NAME"|"$MAINT_NAME"|"$DIND_NAME"|"$PIND_NAME") return 0 ;;
  esac
  return 1
}

_ls_scan_volumes() {
  local args="$1" storage="$2" name scope inuse size mark tab
  tab=$'\t'
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in devcontainer-*) ;; *) continue ;; esac
    scope=$(_ls_volume_scope "$name")
    inuse="no"
    case "$_LS_INUSE" in *" ${storage}:${name} "*) inuse="yes" ;; esac
    size="-"
    if [[ "$LS_SIZES" == true ]]; then
      size=$(_ls_volume_size "$name")
    fi
    mark=" "
    if [[ "$name" == "$HOME_VOLUME" ]]; then
      mark="*"; _LS_MARKED=true
    fi
    _LS_VOLUMES="${_LS_VOLUMES}${mark}${tab}${name}${tab}${scope}${tab}${inuse}${tab}${size}${tab}${storage}
"
  done < <(_ls_volume_candidates "$args")
}

_ls_volume_candidates() {
  # shellcheck disable=SC2086  # intentional word-splitting of $1
  $RUNTIME $1 volume ls --format '{{.Name}}' 2>/dev/null || true
}

# shared    = used by every workspace (tool cache, nested-engine image caches,
#             legacy DEV_SHARED_HOME=1 home volume)
# workspace = one project's home volume (devcontainer-home-<dir>). Two
#             directories sharing a basename share one — the documented
#             basename-collision caveat.
# other     = a devcontainer-* volume dev does not recognise. Listed, never
#             assumed ours.
_ls_volume_scope() {
  case "$1" in
    devcontainer-mise|devcontainer-dind|devcontainer-pind) echo "shared" ;;
    devcontainer-home)   echo "shared" ;;
    devcontainer-home-*) echo "workspace" ;;
    *)                   echo "other" ;;
  esac
}

# `system df -v` renders human-readable sizes and is the only size source both
# engines agree on without jq, which is not guaranteed on the host. There is
# deliberately no `du` fallback on the mountpoint: under rootless podman the
# volume's subdirectories are owned by the subuid range, so `du` as the invoking
# user walks a fraction of the tree and returns a plausible, wrong number with
# no error at all. A '?' is better than a lie.
_ls_load_sizes() {
  local args="$1"
  # shellcheck disable=SC2086  # intentional word-splitting of $args
  _LS_DF=$($RUNTIME $args system df -v 2>/dev/null) || _LS_DF=""
  if [[ -z "$_LS_DF" ]]; then
    echo "Note: '$RUNTIME${args:+ $args} system df -v' returned nothing; sizes show as '?'." >&2
  fi
}

# Size of volume $1, or '?'. Scoped to the "Local Volumes space usage" section
# both engines print, so an image repository sharing a volume's name cannot
# supply the number.
_ls_volume_size() {
  printf '%s\n' "$_LS_DF" | awk -v want="$1" '
    /Local Volumes space usage/ { in_vols = 1; next }
    /space usage/               { in_vols = 0 }
    in_vols && $1 == want       { print $NF; found = 1; exit }
    END                         { if (!found) print "?" }'
}
