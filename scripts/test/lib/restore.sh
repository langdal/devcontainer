# scripts/test/lib/restore.sh
# shellcheck shell=bash
#
# Snapshot/restore primitives. Scenarios call snapshot_* before mutating
# host state, then `trap restore_host EXIT` to ensure cleanup.

declare -A _RESTORE_SYSCTL=()
declare -a _RESTORE_PATHS=()
declare -a _RESTORE_FILES_MODE=()        # entries: "path:mode"
declare -a _RESTORE_VOLUMES=()           # named volumes to remove
declare -a _RESTORE_PKGS=()              # packages to apt-remove if we installed
declare -a _RESTORE_CONTAINERS=()        # containers to force-remove

snapshot_sysctl() {
    local key="$1"
    _RESTORE_SYSCTL["$key"]=$(sysctl -n "$key" 2>/dev/null || echo "")
}

snapshot_file_mode() {
    local f="$1"
    local m
    m=$(stat -c '%a' "$f" 2>/dev/null || echo "")
    [ -n "$m" ] && _RESTORE_FILES_MODE+=("$f:$m")
}

remember_path_overlay() {
    _RESTORE_PATHS+=("$1")
}

remember_volume() {
    _RESTORE_VOLUMES+=("$1")
}

remember_container() {
    _RESTORE_CONTAINERS+=("$1")
}

remember_pkg_install() {
    _RESTORE_PKGS+=("$1")
}

restore_host() {
    set +e
    local rc=0

    for c in "${_RESTORE_CONTAINERS[@]:-}"; do
        [ -z "$c" ] && continue
        ${RUNTIME:-docker} rm -f "$c" >/dev/null 2>&1
    done

    for v in "${_RESTORE_VOLUMES[@]:-}"; do
        [ -z "$v" ] && continue
        ${RUNTIME:-docker} volume rm "$v" >/dev/null 2>&1
    done

    for entry in "${_RESTORE_FILES_MODE[@]:-}"; do
        [ -z "$entry" ] && continue
        local f="${entry%:*}" m="${entry##*:}"
        sudo chmod "$m" "$f" 2>/dev/null
    done

    for d in "${_RESTORE_PATHS[@]:-}"; do
        [ -z "$d" ] && continue
        # PATH overlays are session-local; nothing to do besides removing the temp dir.
        rm -rf "$d"
    done

    for k in "${!_RESTORE_SYSCTL[@]}"; do
        local v="${_RESTORE_SYSCTL[$k]}"
        [ -z "$v" ] && continue
        sudo sysctl -w "$k=$v" >/dev/null 2>&1
    done

    # Only remove packages that THIS scenario installed. The
    # PKG_INSTALLED_BY_TEST_<name> marker is set by apt_install_remember
    # iff dpkg reported the package missing before the install. Without
    # this guard, scenarios that idempotently called apt_install_remember
    # (no-op when already installed) would still uninstall the package
    # on cleanup, taking docker.io / podman off the host between scenarios
    # and breaking everything that follows.
    local removed_any=0
    for p in "${_RESTORE_PKGS[@]:-}"; do
        [ -z "$p" ] && continue
        local var="PKG_INSTALLED_BY_TEST_${p//-/_}"
        if [ "${!var:-0}" = "1" ]; then
            sudo apt-get remove -y "$p" >/dev/null 2>&1 || true
            removed_any=1
        fi
    done
    if [ "$removed_any" = "1" ]; then
        sudo apt-get autoremove -y >/dev/null 2>&1 || true
    fi

    return $rc
}
