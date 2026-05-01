# scripts/test/lib/privilege.sh
#
# When the orchestrator (or a single scenario) is invoked via `sudo …`,
# this helper re-execs the calling script as the original user with the
# docker socket's group added as a supplementary group. That way:
#   - `./dev` sees a real (non-root) UID/GID and bakes correct labels
#   - `docker …` calls inside scenarios succeed via group membership
#   - Privileged operations still go through explicit `sudo`, which works
#     because SUDO_USER is in sudoers (it ran the parent sudo).

drop_privs_if_root() {
    [ "$(id -u)" -ne 0 ] && return 0
    local target_user="${TEST_USER:-${SUDO_USER:-}}"
    if [ -z "$target_user" ]; then
        echo "FATAL: running as root with no SUDO_USER set. Invoke via 'sudo bash …' or set TEST_USER=<non-root user>." >&2
        exit 1
    fi
    if ! id "$target_user" >/dev/null 2>&1; then
        echo "FATAL: target user '$target_user' does not exist." >&2
        exit 1
    fi
    local sock_gid sock_group
    sock_gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "")
    sock_group=$(getent group "$sock_gid" 2>/dev/null | cut -d: -f1)
    if [ -z "$sock_group" ]; then
        echo "FATAL: cannot resolve docker socket group from /var/run/docker.sock; install docker first." >&2
        exit 1
    fi
    local home_dir
    home_dir=$(getent passwd "$target_user" | cut -d: -f6)
    export HOME="$home_dir"
    export USER="$target_user"
    export LOGNAME="$target_user"
    # runuser is the right tool here: as root we can grant any group, and
    # -m preserves env (DEV_EXTRA_RUN_ARGS, DEV_ASSUME_YES, etc.) so the
    # re-execed script sees the same context.
    exec runuser -u "$target_user" -g "$target_user" -G "$sock_group" -m -- \
        bash "$0" "$@"
}
