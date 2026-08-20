# scripts/test/lib/runtime.sh
# shellcheck shell=bash
#
# Helpers around the host runtime (docker / podman) that scenarios use
# beyond what `dev` itself does.

# Pretend a runtime is missing by prepending a temp dir with a stub script
# that exits non-zero when invoked. Returns the temp dir path on stdout so
# the caller can pass it to restore_path_overlay.
mask_runtime() {
    local cmd="$1"
    local d
    d=$(mktemp -d)
    cat > "$d/$cmd" <<EOF
#!/bin/bash
echo "$cmd: not installed (masked by test scenario)" >&2
exit 127
EOF
    chmod +x "$d/$cmd"
    echo "$d"
}

# Add a directory to the front of PATH for the rest of this script.
prepend_path() {
    local d="$1"
    PATH="$d:$PATH"
    export PATH
}

# Mask a runtime, prepend the stub dir to PATH, and register cleanup. After
# the call returns, the calling shell's PATH has the stub dir at the front,
# so `command -v <cmd>` resolves to the stub and `<cmd>` exits 127.
#
# IMPORTANT: do NOT call this inside `$(...)`. Command substitution runs the
# function in a subshell, so the PATH export and the _RESTORE_PATHS append
# would only affect that subshell and disappear before the scenario could
# observe them. Call it as a plain statement; the masked dir path is also
# stashed in MASKED_DIR for scenarios that need to reference it.
MASKED_DIR=""
mask_and_prepend() {
    local cmd="$1"
    MASKED_DIR=$(mask_runtime "$cmd")
    PATH="$MASKED_DIR:$PATH"
    export PATH
    _RESTORE_PATHS+=("$MASKED_DIR")
}

# Apt install a package idempotently and remember whether we installed it.
# Sets PKG_INSTALLED_BY_TEST_<pkg>=1 if we did.
apt_install_remember() {
    local pkg="$1"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        return 0
    fi
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "$pkg"
    eval "PKG_INSTALLED_BY_TEST_${pkg//-/_}=1"
    export "PKG_INSTALLED_BY_TEST_${pkg//-/_}"
}

apt_remove_if_installed_by_test() {
    local pkg="$1"
    local var="PKG_INSTALLED_BY_TEST_${pkg//-/_}"
    if [ "${!var:-0}" = "1" ]; then
        sudo apt-get remove -y "$pkg" >/dev/null 2>&1 || true
        sudo apt-get autoremove -y >/dev/null 2>&1 || true
    fi
}

# Build a scenario-specific image, forwarding GITHUB_TOKEN as a build secret
# when set, mirroring dev's own runtime_build() — without it, `mise install`
# in the Dockerfile hits GitHub's API anonymously, and the 60/hr
# unauthenticated limit is shared across the whole CI runner IP pool, so
# it's easy to exhaust well before these scenarios run. On failure, prints
# the captured build output via the given failure message so the real error
# doesn't get silently lost. Extra args (e.g. --build-arg, -t) are passed
# through as-is.
#
# Branches on $RUNTIME the same way runtime_build() in lib/dev/image.sh
# does: docker uses buildx, podman uses its built-in build. This is not
# cosmetic — under a rootless-podman host where `docker` is a CLI shim
# routed at the podman socket via DOCKER_HOST (see run-rootless.sh),
# `docker buildx build --network=host` auto-provisions a docker-container
# buildkit builder that refuses the network.host entitlement by default:
#   "granting entitlement network.host is not allowed by build daemon
#   configuration"
# `podman build` has no such builder indirection and takes --network=host
# and --secret id=...,env=... directly, so it isn't affected.
build_scenario_image() {
    local fail_msg="$1"; shift
    local extra=() out rc
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        extra+=(--secret "id=github_token,env=GITHUB_TOKEN")
    fi
    if [ "${RUNTIME:-docker}" = "podman" ]; then
        out=$(podman build --network=host "${extra[@]}" "$@" . 2>&1)
    else
        out=$(docker buildx build --network=host "${extra[@]}" "$@" . 2>&1)
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log_fail "${fail_msg}: ${out}"
    fi
    return "$rc"
}

# Build the image with a given UID/GID pair, the way the uid-gid-mismatch
# scenarios do to simulate a stale/foreign image. See build_scenario_image
# for why GITHUB_TOKEN forwarding matters here.
build_image_with_uid_gid() {
    local uid="$1" gid="$2" tag="${3:-generic-devcontainer}"
    build_scenario_image "could not build mismatched image" \
        --build-arg "USER_UID=${uid}" --build-arg "USER_GID=${gid}" \
        -t "$tag"
}

# Host-side runtime for cleanup/probing, mirroring dev's preference order
# (DEV_RUNTIME override, then docker, then podman). Scenarios and the
# orchestrator use this instead of hardcoding docker so podman-only hosts
# clean up correctly.
host_runtime() {
    if [ -n "${DEV_RUNTIME:-}" ] && command -v "$DEV_RUNTIME" >/dev/null 2>&1; then
        echo "$DEV_RUNTIME"
        return
    fi
    if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
        echo docker
        return
    fi
    echo podman
}

# The uid/gid dev will build the image for on THIS host, and the
# --userns=keep-id flag it will pass, printed as "<uid> <gid> <flag>" (the flag
# is empty when the runtime does not remap ids).
#
# These are NOT always the invoking user's ids, which is why scenarios must not
# assume `id -u`. Under rootless podman 4.3+ dev deliberately keeps vscode at
# 1000 and maps the host user onto it, because a host uid outside the user's
# /etc/subuid grant cannot be baked at all (lib/dev/ids.sh explains it in full).
# Scenarios that hardcoded `id -u` here were correct only on a host whose uid
# happened to BE 1000 — they passed on a dev laptop and failed on CI, whose
# runner is uid 1001.
#
# Derived from lib/dev/ids.sh rather than restated, so the harness cannot drift
# from the product's decision; unit/test-image-ids.sh is what pins that decision
# itself, and unit/test-expected-image-ids.sh pins this reader.
#
# Runs in a subshell: the dev modules define names that collide with the
# harness's own ($RUNTIME among them). checks-catalog-nested.sh comes along for
# subid_total, which ids.sh calls on the pre-4.3 fallback path.
expected_image_ids() {
    (
        _eii_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
        # shellcheck disable=SC2034  # read by resolve_image_ids (lib/dev/ids.sh), sourced below
        RUNTIME_ARGS=""
        # shellcheck disable=SC2034  # ditto
        HOST_UID=$(id -u)
        # shellcheck disable=SC2034  # ditto
        HOST_GID=$(id -g)
        # Not followed by shellcheck on purpose: lib/dev/runtime.sh assigns
        # $RUNTIME, and following it here makes every later "$RUNTIME" in a
        # calling scenario look like a use-after-subshell (SC2031). The
        # containment is the point and unit/test-expected-image-ids.sh asserts
        # it; these files are shellchecked directly by scripts/lint.sh anyway.
        # shellcheck source=/dev/null
        . "$_eii_root/lib/dev/runtime.sh"
        # shellcheck source=/dev/null
        . "$_eii_root/lib/dev/checks-catalog-nested.sh"
        # shellcheck source=/dev/null
        . "$_eii_root/lib/dev/ids.sh"
        resolve_image_ids >/dev/null 2>&1
        printf '%s %s %s\n' "$IMAGE_UID" "$IMAGE_GID" "$KEEPID_FLAG"
    )
}
