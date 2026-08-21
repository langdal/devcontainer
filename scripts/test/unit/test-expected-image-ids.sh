#!/usr/bin/env bash
# Unit: expected_image_ids (scripts/test/lib/runtime.sh) — the harness's reader
# for which uid/gid dev builds the image for, and which --userns=keep-id form it
# passes, on the host the suite is running on.
#
# This exists because seven scenarios hardcoded `id -u` for those values. That
# was correct only on a host whose uid happened to be 1000: under rootless
# podman 4.3+ dev deliberately bakes 1000 and maps the host user onto it, so on
# CI (runner uid 1001) every one of those assertions was wrong. The numbers are
# now read from lib/dev/ids.sh, and this pins the reader on any host — including
# the branches this host cannot reach, via a stub CLI.
#
# No engine is contacted and no image is built.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# shellcheck source=scripts/test/lib/runtime.sh
. "$ROOT/scripts/test/lib/runtime.sh"

fail() { echo "FAIL: $1"; exit 1; }

command -v expected_image_ids >/dev/null 2>&1 \
    || fail "expected_image_ids is not defined in scripts/test/lib/runtime.sh"

# $1 stub name, $2 `--version` output, $3 rootless, $4 podman info Version.
make_stub() {
    cat >"$WORK/$1" <<STUB
#!/usr/bin/env bash
case "\$1 \$3" in
  "info {{.Host.Security.Rootless}}") echo '$3'; exit 0 ;;
  "info {{.Version.Version}}")        echo '$4'; exit 0 ;;
  "info {{.SecurityOptions}}")        echo '[name=seccomp,profile=default]'; exit 0 ;;
esac
case "\$1" in
  --version) echo '$2'; exit 0 ;;
esac
exit 1
STUB
    chmod +x "$WORK/$1"
}

HOST_UID=$(id -u)
HOST_GID=$(id -g)
# expected_image_ids reads this; the stubs ignore connection args.
# shellcheck disable=SC2034  # consumed inside expected_image_ids' subshell
RUNTIME_ARGS=""

read_ids() { read -r GOT_UID GOT_GID GOT_FLAG <<< "$(expected_image_ids)"; }

# 1. Rootless podman 4.3+: the image keeps vscode at 1000 and the host user is
#    mapped onto it. The flag is the discriminating part — on a uid-1000 host
#    the numbers alone cannot tell "baked 1000" from "the host's own uid".
make_stub podman5 'podman version 4.9.3' true '4.9.3'
RUNTIME="$WORK/podman5"
read_ids
[ "$GOT_UID" = 1000 ] || fail "rootless podman 4.9: uid=$GOT_UID, want 1000"
[ "$GOT_GID" = 1000 ] || fail "rootless podman 4.9: gid=$GOT_GID, want 1000"
[ "$GOT_FLAG" = "--userns=keep-id:uid=1000,gid=1000" ] \
    || fail "rootless podman 4.9: flag='$GOT_FLAG', want --userns=keep-id:uid=1000,gid=1000"

# 2. Docker: no id remapping, so the image bakes the invoking user's own ids and
#    there is no keep-id flag at all.
make_stub dockerstub 'Docker version 29.1.3, build x' false ''
RUNTIME="$WORK/dockerstub"
read_ids
[ "$GOT_UID" = "$HOST_UID" ] || fail "docker: uid=$GOT_UID, want $HOST_UID"
[ "$GOT_GID" = "$HOST_GID" ] || fail "docker: gid=$GOT_GID, want $HOST_GID"
[ -z "$GOT_FLAG" ] || fail "docker should get no keep-id flag, got '$GOT_FLAG'"

# 3. Rootful podman: like docker — the initial userns already has every id.
make_stub podmanroot 'podman version 4.9.3' false '4.9.3'
RUNTIME="$WORK/podmanroot"
read_ids
[ "$GOT_UID" = "$HOST_UID" ] || fail "rootful podman: uid=$GOT_UID, want $HOST_UID"
[ -z "$GOT_FLAG" ] || fail "rootful podman should get no keep-id flag, got '$GOT_FLAG'"

# 4. Rootless podman older than 4.3 has no keep-id:uid=, so dev falls back to
#    baking the host uid with the bare flag. Scenario probes must follow that,
#    which is why they read the flag rather than hardcoding either form.
make_stub podman42 'podman version 4.2.0' true '4.2.0'
RUNTIME="$WORK/podman42"
read_ids
[ "$GOT_UID" = "$HOST_UID" ] || fail "rootless podman 4.2: uid=$GOT_UID, want $HOST_UID"
[ "$GOT_FLAG" = "--userns=keep-id" ] \
    || fail "rootless podman 4.2: flag='$GOT_FLAG', want bare --userns=keep-id"

# 5. The subshell must not leak: a scenario's own $RUNTIME and the memoized
#    IMAGE_UID inside ids.sh must not survive into the caller, or the second
#    call in a scenario would return the first call's answer.
[ "$RUNTIME" = "$WORK/podman42" ] || fail "expected_image_ids clobbered the caller's RUNTIME"
[ -z "${IMAGE_UID:-}" ] || fail "expected_image_ids leaked IMAGE_UID='$IMAGE_UID' into the caller"
make_stub podman5b 'podman version 4.9.3' true '4.9.3'
RUNTIME="$WORK/podman5b"
read_ids
[ "$GOT_UID" = 1000 ] || fail "second call did not re-resolve (memoization leaked): uid=$GOT_UID"

echo ok
