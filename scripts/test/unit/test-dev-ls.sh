#!/usr/bin/env bash
# Unit: `dev ls` inventory (lib/dev/ls.sh + lib/dev/ls-render.sh).
#
# No runtime is contacted: the engine CLI is a stub script that replays
# fixtures, which is what lets this cover the classification rules (ours vs
# someone else's dev-* container, shared vs per-workspace volume, in-use from
# real mounts) on a host with no docker or podman at all.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixtures"; mkdir -p "$FIX"; export FIX

fail() { echo "FAIL: $1"; echo "--- output ---"; echo "${out:-}"; exit 1; }

cat >"$WORK/rt" <<'EOF'
#!/usr/bin/env bash
# Stub engine CLI. Connection flags come before the verb on a real CLI, so skip
# them the same way — otherwise the second (rootful) storage pass sees $1 as
# --connection=... and silently matches nothing.
while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
case "$1" in
  ps)      cat "$FIX/ps" ;;
  inspect) cat "$FIX/inspect-$2" 2>/dev/null || exit 1 ;;
  volume)  cat "$FIX/volumes" ;;
  system)  cat "$FIX/df" 2>/dev/null || exit 1 ;;
  *)       exit 1 ;;
esac
EOF
chmod +x "$WORK/rt"

# Four dev-* containers. dev-notours wears the name but is a user's own
# container: no dev.keepid label, unrelated image. `unrelated` fails the
# client-side dev- prefix check.
printf '%s\t%s\n' \
    dev-myproj      'Up 2 hours' \
    dev-other       'Exited (0) 3 days ago' \
    dev-myproj-dind 'Up 5 minutes' \
    dev-notours     'Up 1 hour' \
    unrelated       'Up 9 days' > "$FIX/ps"

# Records are: image, dev.keepid, then type|name|destination|source per mount.
cat > "$FIX/inspect-dev-myproj" <<'EOF'
generic-devcontainer:latest
true
bind||/workspace|/home/u/myproj
volume|devcontainer-mise|/mise|
volume|devcontainer-home-myproj|/home/vscode|
EOF
cat > "$FIX/inspect-dev-other" <<'EOF'
generic-devcontainer:latest
false
bind||/workspace|/srv/checkouts/other
volume|devcontainer-mise|/mise|
volume|devcontainer-home-other|/home/vscode|
EOF
cat > "$FIX/inspect-dev-myproj-dind" <<'EOF'
generic-devcontainer:dind
true
bind||/workspace|/home/u/myproj
volume|devcontainer-dind|/home/vscode/.local/share/docker|
EOF
cat > "$FIX/inspect-dev-notours" <<'EOF'
mycorp/api:1.2
<no value>
bind||/app|/home/u/api
EOF

cat > "$FIX/volumes" <<'EOF'
devcontainer-mise
devcontainer-home-myproj
devcontainer-home-other
devcontainer-home-ghost
devcontainer-dind
devcontainer-home
devcontainer-legacy-thing
some-other-volume
EOF

# Deliberately adversarial: an IMAGE repository named exactly like a volume,
# carrying a wildly different size. Section scoping must keep 999GB out of the
# devcontainer-home-ghost row, which has no volume entry at all.
cat > "$FIX/df" <<'EOF'
Images space usage:

REPOSITORY                TAG      IMAGE ID   CREATED      SIZE    SHARED SIZE   UNIQUE SIZE   CONTAINERS
devcontainer-home-ghost   latest   abc123     2 days ago   999GB   0B            999GB         0

Containers space usage:

CONTAINER ID   IMAGE   COMMAND   LOCAL VOLUMES   SIZE   CREATED   STATUS   NAMES

Local Volumes space usage:

VOLUME NAME                LINKS     SIZE
devcontainer-mise          1         4.2GB
devcontainer-home-myproj   1         812MB
devcontainer-dind          1         9.7GB
EOF

# shellcheck source=lib/dev/ls.sh
. "$ROOT/lib/dev/ls.sh"
# shellcheck source=lib/dev/ls-render.sh
. "$ROOT/lib/dev/ls-render.sh"

# The globals cmd_ls would have resolved via detect_runtime and
# _resolve_workspace_names. Current workspace is "myproj".
RUNTIME="$WORK/rt"
IMAGE_NAME="generic-devcontainer"
DIND_RUNTIME_ARGS=""
WORKSPACE_BASENAME="myproj"
NORMAL_NAME="dev-myproj"; MAINT_NAME="dev-myproj-maint"
DIND_NAME="dev-myproj-dind"; PIND_NAME="dev-myproj-pind"
HOME_VOLUME="devcontainer-home-myproj"

# ---------- 1. default report ----------
LS_SIZES=false
out=$(ls_report 2>&1)

echo "$out" | grep -q '^CONTAINERS$' || fail "no CONTAINERS section"
echo "$out" | grep -q '^VOLUMES$'    || fail "no VOLUMES section"

# Ours are listed with the right mode and the real bind-mount path.
echo "$out" | grep -Eq '^ +\* +normal +dev-myproj +Up 2 hours +/home/u/myproj$' \
    || fail "current-workspace container row wrong"
echo "$out" | grep -Eq '^ +\* +dind +dev-myproj-dind +Up 5 minutes +/home/u/myproj$' \
    || fail "dind mode/marker wrong"
# Another workspace: listed, unmarked, and its own path — the thing `dev
# status` cannot show.
echo "$out" | grep -Eq '^ +normal +dev-other +Exited \(0\) 3 days ago +/srv/checkouts/other$' \
    || fail "other-workspace container row wrong"

# Not ours: name matches dev-*, nothing else does.
echo "$out" | grep -q 'dev-notours' && fail "listed a container that is not dev's"
echo "$out" | grep -q 'unrelated'   && fail "listed a non-dev- container"

# Volume scope + in-use, derived from mounts rather than the naming scheme.
echo "$out" | grep -Eq '^ +\* +devcontainer-home-myproj +workspace +yes$' \
    || fail "current home volume row wrong"
echo "$out" | grep -Eq '^ +devcontainer-home-other +workspace +yes$' \
    || fail "other home volume should be in use by dev-other"
echo "$out" | grep -Eq '^ +devcontainer-home-ghost +workspace +no$' \
    || fail "container-less home volume should read 'no'"
echo "$out" | grep -Eq '^ +devcontainer-mise +shared +yes$' \
    || fail "mise volume should be shared + in use"
echo "$out" | grep -Eq '^ +devcontainer-home +shared +no$' \
    || fail "legacy devcontainer-home should be shared"
echo "$out" | grep -Eq '^ +devcontainer-legacy-thing +other +no$' \
    || fail "unrecognised devcontainer-* volume should be scope 'other'"
echo "$out" | grep -q 'some-other-volume' && fail "listed a non-devcontainer volume"

# No SIZE column without --sizes.
echo "$out" | grep -q 'SIZE' && fail "SIZE column present without --sizes"
# No STORAGE column on a single-storage host.
echo "$out" | grep -q 'STORAGE' && fail "STORAGE column present with one storage"

# The legend, and the delete-me hint naming ONLY the orphan.
echo "$out" | grep -q "belongs to this directory's workspace (myproj)" \
    || fail "marker legend missing"
hint=$(echo "$out" | sed -n '/No container is using/,$p')
echo "$hint" | grep -q 'devcontainer-home-ghost' || fail "hint omits the orphan volume"
echo "$hint" | grep -q 'devcontainer-home-myproj' && fail "hint names an in-use volume"
echo "$hint" | grep -q 'devcontainer-home$' && fail "hint names a shared volume"
echo "$hint" | grep -q 'volume rm' || fail "hint omits the removal command"

# ---------- 2. --sizes ----------
LS_SIZES=true
out=$(ls_report 2>&1)
echo "$out" | grep -q 'SIZE' || fail "--sizes did not add the SIZE column"
echo "$out" | grep -Eq '^ +devcontainer-mise +shared +yes +4\.2GB$' \
    || fail "size not read from the Local Volumes section"
# The image row of the same name must not supply a number.
echo "$out" | grep -Eq '^ +devcontainer-home-ghost +workspace +no +\?$' \
    || fail "unknown size should render '?'"
echo "$out" | grep -q '999GB' && fail "size leaked from the images section"

# ---------- 3. an unreadable df leaves every cell '?' ----------
rm -f "$FIX/df"
out=$(ls_report 2>&1)
echo "$out" | grep -q "system df -v' returned nothing" || fail "no note when df fails"
echo "$out" | grep -Eq '^ +devcontainer-mise +shared +yes +\?$' \
    || fail "df failure should give '?', not a stale or wrong size"

# ---------- 4. two storages (macOS+podman: dind lives in the rootful one) ----------
# The stub ignores connection args, so both passes replay the same fixtures — which
# is the point: one shared volume name legitimately exists in both storages and
# each row has to say which it came from rather than being deduplicated away.
DIND_RUNTIME_ARGS="--connection=podman-machine-default-root"
LS_SIZES=false
out=$(ls_report 2>&1)
echo "$out" | grep -q STORAGE || fail "STORAGE column missing with two storages"
echo "$out" | grep -Eq "^ +\\* +normal +dev-myproj +Up 2 hours +/home/u/myproj +default$" \
    || fail "default-storage container row wrong"
echo "$out" | grep -Eq "^ +\\* +normal +dev-myproj +Up 2 hours +/home/u/myproj +rootful$" \
    || fail "rootful-storage container row wrong"
[ "$(echo "$out" | grep -cE "^ +devcontainer-mise +shared +yes")" -eq 2 ] \
    || fail "shared volume should appear once per storage"
DIND_RUNTIME_ARGS=""

# ---------- 5. empty machine ----------
: > "$FIX/ps"; : > "$FIX/volumes"
LS_SIZES=false
out=$(ls_report 2>&1)
echo "$out" | grep -q 'No dev containers or devcontainer-\* volumes' \
    || fail "empty machine should say so"
echo "$out" | grep -q 'CONTAINERS' && fail "empty machine should not print tables"

# ---------- 6. argument contract, through the real entry point ----------
# cmd_ls parses flags before it touches the runtime, so these need no engine.
dev_ls() { (cd "$WORK" && "$ROOT/dev" "$@" </dev/null 2>&1); }
out=$(dev_ls ls --bogus); rc=$?
[ "$rc" -eq 2 ] || fail "unknown option should exit 2, got $rc"
echo "$out" | grep -q 'unknown option' || fail "no guidance on a bad option"
out=$(dev_ls ls extra); rc=$?
[ "$rc" -eq 2 ] || fail "positional argument should exit 2, got $rc"
out=$(dev_ls ls --help); rc=$?
[ "$rc" -eq 0 ] || fail "ls --help should exit 0, got $rc"
echo "$out" | grep -qi 'usage' || fail "ls --help printed no usage"

echo ok
