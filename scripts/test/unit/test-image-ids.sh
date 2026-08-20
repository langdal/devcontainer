#!/usr/bin/env bash
# Unit: image id / keep-id mapping resolution (lib/dev/ids.sh).
#
# The image's baked vscode uid and the --userns=keep-id form are one decision,
# and rootless podman constrains it: every container id must fall inside the
# invoking user's /etc/subuid grant. A domain account's uid (millions) does
# not, so baking it made the build die in usermod with exit 12 ("Failed to
# change ownership of the home directory") on AD/LDAP-joined hosts. The fix
# keeps vscode at 1000 there and maps the host user onto it with
# keep-id:uid=,gid=, which podman gained in 4.3 — so the pre-4.3 fallback has
# to stay, and has to say why it may not work.
#
# No runtime is contacted: each case is a stub script on PATH.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Build a stub CLI. $1=name, $2=--version output, $3=Rootless value,
# $4=Version.Version output.
make_stub() {
    local name=$1 ver=$2 rootless=$3 pver=$4
    cat >"$WORK/$name" <<STUB
#!/usr/bin/env bash
case "\$1 \$3" in
  "info {{.Host.Security.Rootless}}") echo '$rootless' ;;
  "info {{.Version.Version}}")        echo '$pver' ;;
  "info {{.SecurityOptions}}")        echo '[name=seccomp,profile=default]' ;;
esac
case "\$1" in
  --version) echo '$ver' ;;
  version)   exit 1 ;;
esac
exit 0
STUB
    chmod +x "$WORK/$name"
}

# shellcheck source=lib/dev/runtime.sh
. "$ROOT/lib/dev/runtime.sh"
# shellcheck source=lib/dev/ids.sh
. "$ROOT/lib/dev/ids.sh"
RUNTIME_ARGS=""
# Deterministic grant: the pre-4.3 fallback warning keys off this.
subid_total() { echo 65536; }

fail() { echo "FAIL: $1"; exit 1; }

command -v resolve_image_ids >/dev/null 2>&1 \
    || fail "resolve_image_ids is not defined in lib/dev/ids.sh"

# A domain-account uid: far outside any default subuid grant.
HOST_UID=1198401
HOST_GID=1198401

reset() { unset IMAGE_UID IMAGE_GID EXPECT_KEEPID KEEPID_FLAG _ENGINE_IS_PODMAN 2>/dev/null || true; }

check() { # $1=label $2=want_uid $3=want_keepid $4=want_flag
    [ "$IMAGE_UID" = "$2" ] || fail "$1: IMAGE_UID=$IMAGE_UID, want $2"
    [ "$IMAGE_GID" = "$2" ] || fail "$1: IMAGE_GID=$IMAGE_GID, want $2"
    [ "$EXPECT_KEEPID" = "$3" ] || fail "$1: EXPECT_KEEPID=$EXPECT_KEEPID, want $3"
    [ "$KEEPID_FLAG" = "$4" ] || fail "$1: KEEPID_FLAG='$KEEPID_FLAG', want '$4'"
}

# 1. Docker: no id remapping, so the image bakes the host's own ids and there
#    is no keep-id flag at all.
reset; make_stub docker 'Docker version 29.1.3, build x' false ''
RUNTIME="$WORK/docker"
resolve_image_ids 2>/dev/null
check docker 1198401 false ''

# 2. Rootless podman 5.x: vscode stays at 1000, host user is mapped onto it.
#    This is the case that used to fail the build on a domain-joined host.
reset; make_stub podman5 'podman version 5.2.2' true '5.2.2'
RUNTIME="$WORK/podman5"
resolve_image_ids 2>/dev/null
check podman5-rootless 1000 true '--userns=keep-id:uid=1000,gid=1000'

# 3. Rootful podman: like docker, the initial userns has every id.
reset; make_stub podmanroot 'podman version 5.2.2' false '5.2.2'
RUNTIME="$WORK/podmanroot"
resolve_image_ids 2>/dev/null
check podman5-rootful 1198401 false ''

# 4. Rootless podman 3.4 (Ubuntu 22.04): no keep-id:uid= support, so fall back
#    to baking the host uid — and warn, because a 65536-id grant cannot map it.
reset; make_stub podman34 'podman version 3.4.4' true '3.4.4'
RUNTIME="$WORK/podman34"
# Not warn=$(resolve_image_ids ...): command substitution would resolve the
# ids in a subshell and leave the assertions below reading an unset IMAGE_UID.
resolve_image_ids 2>"$WORK/warn34"
warn=$(cat "$WORK/warn34")
check podman34-rootless 1198401 true '--userns=keep-id'
case "$warn" in
  *"older than 4.3"*) ;;
  *) fail "podman34: expected a pre-4.3 warning, got: $warn" ;;
esac
case "$warn" in
  *"add-subuids"*) ;;
  *) fail "podman34: warning must name the remediation, got: $warn" ;;
esac

# 5. Rootless podman 4.3 exactly: the boundary is inclusive.
reset; make_stub podman43 'podman version 4.3.0' true '4.3.0'
RUNTIME="$WORK/podman43"
resolve_image_ids 2>/dev/null
check podman43-rootless 1000 true '--userns=keep-id:uid=1000,gid=1000'

# 6. keepid_active must set KEEPID_FLAG in the CALLER's shell — a $( ) call
#    would resolve it in a subshell and leave the caller with an empty flag,
#    which is how the injection helpers would silently lose the mapping.
reset; RUNTIME="$WORK/podman5"
if keepid_active; then
    [ -n "$KEEPID_FLAG" ] || fail "keepid_active: KEEPID_FLAG unset in caller"
else
    fail "keepid_active: expected true under rootless podman"
fi

echo "PASS: image id / keep-id mapping resolution"
