#!/usr/bin/env bash
# scripts/test/run-in-vm.sh — boots a named distro in QEMU, runs a
# command (default: bash scripts/test/run-all.sh) inside, returns its
# exit code. See docs/ci-testing.md for usage and prerequisites.
#
# Source guard: setting DEV_CI_TEST_MODE=1 before sourcing this file
# suppresses main, so unit tests can call individual functions.
set -u

usage() {
    cat <<EOF
Usage: $(basename "$0") <distro> [--cmd "<command>"] [--shell]

Boots <distro> in QEMU and runs the suite inside.

Arguments:
  <distro>            One of: fedora, debian, ubuntu (matching scripts/test/vms/<distro>.conf)
  --cmd "<command>"   Command to run inside the VM (default: bash scripts/test/run-all.sh)
  --shell             After cloud-init finishes, drop to an interactive SSH shell.

Environment:
  DEV_CI_CACHE_DIR    Override image cache (default: \${XDG_CACHE_HOME:-\$HOME/.cache}/devcontainer-ci)
EOF
}

DISTRO=""
CMD=""
SHELL_MODE=0

parse_args() {
    DISTRO=""
    CMD=""
    SHELL_MODE=0
    if [ $# -eq 0 ]; then usage >&2; return 1; fi
    DISTRO="$1"; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --cmd) CMD="${2:-}"; shift 2 ;;
            --shell) SHELL_MODE=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) echo "Unknown argument: $1" >&2; usage >&2; return 1 ;;
        esac
    done
    return 0
}

load_distro_conf() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "Conf not found: $path" >&2
        return 1
    fi
    # Reset known vars so a missing required var isn't inherited.
    IMAGE_URL=""; IMAGE_SHA256=""; CLOUD_USER=""
    PACKAGES=""; PACKAGE_INSTALL_CMD=""
    # POST_BOOT_CMDS is set by some distro confs and read later by
    # render_user_data via the caller; shellcheck can't trace that path.
    # shellcheck disable=SC2034
    POST_BOOT_CMDS=""
    # shellcheck disable=SC1090
    . "$path"
    local missing=()
    [ -z "$IMAGE_URL" ] && missing+=(IMAGE_URL)
    [ -z "$IMAGE_SHA256" ] && missing+=(IMAGE_SHA256)
    [ -z "$CLOUD_USER" ] && missing+=(CLOUD_USER)
    [ -z "$PACKAGES" ] && missing+=(PACKAGES)
    [ -z "$PACKAGE_INSTALL_CMD" ] && missing+=(PACKAGE_INSTALL_CMD)
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Conf $path missing required vars: ${missing[*]}" >&2
        return 1
    fi
    return 0
}

sha256_of() {
    # Portable wrapper: GNU coreutils ships sha256sum; macOS ships
    # `shasum -a 256` instead. Both print "<hash>  <path>" on one line.
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        echo "Need one of: sha256sum, shasum" >&2
        return 1
    fi
}

pick_free_port() {
    # Try up to 50 random ports in 10000..65000. Use `ss` if available
    # (Linux), `netstat -an` as POSIX-ish fallback (macOS).
    local port checker_cmd
    if command -v ss >/dev/null 2>&1; then
        checker_cmd="ss -tlnH"
    else
        checker_cmd="netstat -an"
    fi
    for _ in $(seq 1 50); do
        port=$((RANDOM % 55001 + 10000))
        # shellcheck disable=SC2086
        # checker_cmd is intentionally a multi-word command ("ss -tlnH"
        # or "netstat -an") and must word-split here.
        if ! $checker_cmd 2>/dev/null | grep -qE "[.:]${port}[[:space:]]+"; then
            echo "$port"
            return 0
        fi
    done
    echo "Could not find a free port after 50 attempts" >&2
    return 1
}

acquire_image() {
    local url="$1" want_sha="$2" distro="$3"
    if [ "$want_sha" = "REPLACE_ME" ]; then
        echo "Distro conf for $distro has IMAGE_SHA256=REPLACE_ME; fill it in." >&2
        return 1
    fi
    local cache_root="${DEV_CI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/devcontainer-ci}"
    local cache_dir="$cache_root/images/$distro"
    local out="$cache_dir/$want_sha.qcow2"
    mkdir -p "$cache_dir"
    if [ -f "$out" ]; then
        local actual
        actual=$(sha256_of "$out")
        if [ "$actual" = "$want_sha" ]; then
            echo "$out"
            return 0
        fi
        echo "Cached file sha mismatch; redownloading: $out" >&2
        rm -f "$out"
    fi
    local tmp="$out.partial"
    if ! curl --fail --retry 3 --retry-connrefused -L -sS -o "$tmp" "$url" >&2; then
        rm -f "$tmp"
        return 1
    fi
    local actual_dl
    actual_dl=$(sha256_of "$tmp")
    if [ "$actual_dl" != "$want_sha" ]; then
        echo "Downloaded image sha mismatch for $distro: expected=$want_sha actual=$actual_dl" >&2
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"
    echo "$out"
}

generate_ephemeral_ssh_key() {
    # Writes private key to $1, public key to $1.pub. Caller's responsibility
    # to clean up; trap usually handles via $RUN_DIR removal.
    local out="$1"
    ssh-keygen -t ed25519 -N '' -C "devcontainer-ci-$(date +%s)" -f "$out" >/dev/null
}

make_seed_iso() {
    local out="$1" seed_dir="$2"
    if [ ! -f "$seed_dir/user-data" ] || [ ! -f "$seed_dir/meta-data" ]; then
        echo "seed dir must contain user-data and meta-data" >&2
        return 1
    fi
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$out" "$seed_dir/user-data" "$seed_dir/meta-data"
        return $?
    fi
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -output "$out" -volid CIDATA -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data" 2>/dev/null
        return $?
    fi
    if command -v mkisofs >/dev/null 2>&1; then
        mkisofs -output "$out" -volid CIDATA -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data" 2>/dev/null
        return $?
    fi
    if command -v genisoimage >/dev/null 2>&1; then
        genisoimage -output "$out" -volid CIDATA -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data" 2>/dev/null
        return $?
    fi
    echo "Need one of: cloud-localds, xorriso, mkisofs, genisoimage" >&2
    return 1
}

render_user_data() {
    # Args: cloud_user, ssh_public_key_text, package_install_cmd, packages, post_boot_cmds
    #
    # We use the cloud image's default user (already named fedora/debian/ubuntu
    # with sudo NOPASSWD) and only inject the SSH key. Listing groups that
    # don't yet exist (e.g. `docker` before package install on Fedora) causes
    # cloud-init to silently drop the user definition entirely on some distros.
    local cloud_user="$1" pubkey="$2" install_cmd="$3" packages="$4" post_boot="${5:-}"
    cat <<EOF
#cloud-config
hostname: devcontainer-ci
manage_etc_hosts: localhost
ssh_pwauth: false
users:
  - default
  - name: ${cloud_user}
    ssh_authorized_keys:
      - ${pubkey}
package_update: true
runcmd:
  - ${install_cmd} ${packages}
  - systemctl enable --now docker || true
  - systemctl enable --now containerd || true
  - usermod -aG docker ${cloud_user} || true
EOF
    if [ -n "$post_boot" ]; then
        # Embed POST_BOOT_CMDS as a single shell line in runcmd. The third
        # element of the [bash, -c, ...] flow sequence is a YAML single-quoted
        # string; YAML escapes single quotes by doubling them ('') — NOT
        # shell-style '\''.
        printf '  - [bash, -c, %s]\n' "$(printf '%s' "$post_boot" | sed "s/'/''/g; s/^/'/; s/$/'/")"
    fi
}

render_meta_data() {
    cat <<EOF
instance-id: devcontainer-ci-$(date +%s)
local-hostname: devcontainer-ci
EOF
}

detect_accel() {
    if [ -w /dev/kvm ]; then echo kvm; return; fi
    if qemu-system-x86_64 -accel help 2>&1 | grep -qi hvf; then echo hvf; return; fi
    echo tcg
}

require_host_tools() {
    local missing=()
    for t in qemu-system-x86_64 qemu-img ssh scp rsync curl ssh-keygen; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    # sha256: sha256sum (GNU) or shasum (macOS)
    if ! command -v sha256sum >/dev/null 2>&1 \
        && ! command -v shasum >/dev/null 2>&1; then
        missing+=("sha256sum|shasum")
    fi
    # ISO tool — make_seed_iso checks too, but better to fail early.
    if ! command -v cloud-localds >/dev/null 2>&1 \
        && ! command -v xorriso >/dev/null 2>&1 \
        && ! command -v mkisofs >/dev/null 2>&1 \
        && ! command -v genisoimage >/dev/null 2>&1; then
        missing+=("cloud-localds|xorriso|mkisofs|genisoimage")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required host tools: ${missing[*]}" >&2
        echo "Linux: apt install qemu-system-x86 qemu-utils cloud-image-utils openssh-client rsync" >&2
        echo "macOS: brew install qemu cdrtools openssh rsync" >&2
        return 1
    fi
    return 0
}

ssh_in() {
    # Run a command in the VM. All args after $1 are the remote command.
    local port="$1"; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" \
        -p "$port" "$CLOUD_USER@127.0.0.1" "$@"
}

ssh_in_tty() {
    # Same as ssh_in but forces a TTY (-t) — needed when the in-VM command
    # invokes tools that detect tty (the existing test scenarios use $(tty)
    # in places). Calling ssh_in with "-t" would treat -t as a remote command,
    # so we need this separate wrapper.
    local port="$1"; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -t -i "$RUN_DIR/id_ed25519" \
        -p "$port" "$CLOUD_USER@127.0.0.1" "$@"
}

wait_for_ssh() {
    # Call ssh directly (NOT via ssh_in) so we can add -o ConnectTimeout=5
    # as an ssh option rather than a remote command.
    local port="$1" deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=5 -i "$RUN_DIR/id_ed25519" \
            -p "$port" "$CLOUD_USER@127.0.0.1" true 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    echo "VM did not accept SSH within 5 min" >&2
    return 1
}

log_phase() {
    echo
    echo "=== [phase] $* ==="
}

main() {
    parse_args "$@" || exit $?
    require_host_tools || exit 1

    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local conf="$REPO_ROOT/scripts/test/vms/$DISTRO.conf"
    load_distro_conf "$conf" || exit 1

    # mktemp -t accepts a template differently between GNU (substitutes X's)
    # and BSD/macOS (uses as a prefix). Pass an explicit path to be portable.
    RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/devcontainer-ci-XXXXXX")
    SSH_PORT=$(pick_free_port)
    ACCEL=$(detect_accel)

    # shellcheck disable=SC2317  # invoked via trap
    cleanup() {
        local rc=$?
        if [ -f "$RUN_DIR/vm.pid" ]; then
            local pid; pid=$(cat "$RUN_DIR/vm.pid" 2>/dev/null || true)
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null || true
            fi
        fi
        # Always copy logs back to host workspace if they exist on the VM.
        if [ -n "${SSH_PORT:-}" ] && [ -f "$RUN_DIR/id_ed25519" ]; then
            for f in last-run.log last-summary.log; do
                scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
                    "$CLOUD_USER@127.0.0.1:/workspace/scripts/test/$f" \
                    "$REPO_ROOT/scripts/test/${f%.log}-$DISTRO.log" 2>/dev/null || true
            done
        fi
        if [ "$rc" -ne 0 ]; then
            if [ -f "$RUN_DIR/serial.log" ]; then
                cp "$RUN_DIR/serial.log" "$REPO_ROOT/scripts/test/serial-$DISTRO.log" 2>/dev/null || true
            fi
            if [ -f "$RUN_DIR/cloud-init-output.log" ]; then
                cp "$RUN_DIR/cloud-init-output.log" \
                    "$REPO_ROOT/scripts/test/cloud-init-output-$DISTRO.log" 2>/dev/null || true
            fi
        fi
        rm -rf "$RUN_DIR"
        exit "$rc"
    }
    trap cleanup EXIT INT TERM

    log_phase "1/8 acquire image ($DISTRO)"
    BASE_IMAGE=$(acquire_image "$IMAGE_URL" "$IMAGE_SHA256" "$DISTRO") || exit 1

    log_phase "2/8 generate cloud-init seed"
    generate_ephemeral_ssh_key "$RUN_DIR/id_ed25519"
    PUBKEY=$(cat "$RUN_DIR/id_ed25519.pub")
    mkdir -p "$RUN_DIR/seed"
    render_user_data "$CLOUD_USER" "$PUBKEY" "$PACKAGE_INSTALL_CMD" "$PACKAGES" "$POST_BOOT_CMDS" \
        > "$RUN_DIR/seed/user-data"
    render_meta_data > "$RUN_DIR/seed/meta-data"
    make_seed_iso "$RUN_DIR/seed.iso" "$RUN_DIR/seed" || exit 1

    log_phase "3/8 boot QEMU (accel=$ACCEL, port=$SSH_PORT)"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$RUN_DIR/overlay.qcow2" >/dev/null
    # Cloud images ship with a 3-5 GiB virtual disk — too small for the
    # devcontainer test suite (Docker images, package installs, DinD).
    # Resize to 24 GiB; cloud-init's growpart module expands the root
    # partition automatically on first boot.
    qemu-img resize "$RUN_DIR/overlay.qcow2" 24G >/dev/null
    local cpu_flag="host"
    [ "$ACCEL" = "tcg" ] && cpu_flag="max"
    # Note: per-distro kernel state (e.g. SELinux enforcing) is applied via
    # POST_BOOT_CMDS in cloud-init's runcmd, NOT via -append. QEMU's -append
    # is silently ignored when booting from a disk image (no -kernel passed),
    # which would mask the SELinux gate.
    # ACCEL, cpu_flag, SSH_PORT are intentionally word-split into the qemu
    # invocation; quoting them would corrupt the -machine/-cpu/hostfwd args.
    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -machine q35,accel=$ACCEL \
        -cpu $cpu_flag \
        -smp 4 -m 4096 \
        -drive file="$RUN_DIR/overlay.qcow2",if=virtio \
        -drive file="$RUN_DIR/seed.iso",if=virtio,format=raw \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
        -device virtio-net-pci,netdev=n0 \
        -display none -daemonize \
        -pidfile "$RUN_DIR/vm.pid" \
        -serial file:"$RUN_DIR/serial.log"
    wait_for_ssh "$SSH_PORT" || exit 1

    log_phase "4/8 wait for cloud-init"
    # cloud-init status exit codes: 0=done OK, 1=critical/not-run, 2=done
    # with recoverable errors (e.g. schema warnings, optional-group warnings).
    # We treat 0 and 2 as success but still capture the output log on 2 for
    # postmortem visibility. 1 is fatal.
    set +e
    ssh_in "$SSH_PORT" 'sudo cloud-init status --wait'
    local ci_rc=$?
    set -e
    if [ "$ci_rc" -eq 2 ]; then
        echo "cloud-init completed with recoverable errors (rc=2); continuing" >&2
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
            "$CLOUD_USER@127.0.0.1:/var/log/cloud-init-output.log" \
            "$RUN_DIR/cloud-init-output.log" 2>/dev/null || true
    elif [ "$ci_rc" -ne 0 ]; then
        echo "cloud-init failed (rc=$ci_rc); fetching output log" >&2
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
            "$CLOUD_USER@127.0.0.1:/var/log/cloud-init-output.log" \
            "$RUN_DIR/cloud-init-output.log" 2>/dev/null || true
        exit 1
    fi

    log_phase "5/8 sync workspace"
    ssh_in "$SSH_PORT" 'sudo mkdir -p /workspace && sudo chown -R '"$CLOUD_USER:$CLOUD_USER"' /workspace'
    rsync -az --delete \
        --exclude '.git' \
        --exclude 'scripts/test/last-*.log' \
        --exclude 'scripts/test/serial-*.log' \
        --exclude 'scripts/test/cloud-init-output-*.log' \
        -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $RUN_DIR/id_ed25519 -p $SSH_PORT" \
        "$REPO_ROOT/" "$CLOUD_USER@127.0.0.1:/workspace/"

    log_phase "6/8 exec command"
    local in_vm_cmd="${CMD:-bash scripts/test/run-all.sh}"
    if [ "$SHELL_MODE" = "1" ]; then
        echo "Dropping to interactive shell. Exit when done." >&2
        ssh_in "$SSH_PORT"
        exit 0
    fi
    # Forward a GitHub token into the VM so the in-VM image build (./dev
    # --build -> mise install) can make authenticated GitHub API calls. The
    # unauthenticated 60/hr limit is shared across the CI runner IP and is
    # routinely exhausted by the parallel matrix jobs -> HTTP 403 -> failed
    # build. Written to a 0600 file and read via command substitution on the
    # remote side so the value never appears in argv / ps / the serial log.
    local token_prefix=""
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf '%s' "$GITHUB_TOKEN" > "$RUN_DIR/gh_token"
        chmod 600 "$RUN_DIR/gh_token"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
            "$RUN_DIR/gh_token" "$CLOUD_USER@127.0.0.1:.gh_token"
        ssh_in "$SSH_PORT" 'chmod 600 ~/.gh_token'
        # Single quotes are intentional: the $(cat ...) must reach the remote
        # shell unexpanded so the token is read in-VM, never on the host.
        # shellcheck disable=SC2016
        token_prefix='export GITHUB_TOKEN="$(cat ~/.gh_token)"; '
    fi

    set +e
    ssh_in_tty "$SSH_PORT" "cd /workspace && ${token_prefix}$in_vm_cmd"
    local in_vm_rc=$?
    set -e

    log_phase "7/8 retrieve logs"
    # Trap also retrieves; explicit copy here makes the path well-known.
    for f in last-run.log last-summary.log; do
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -i "$RUN_DIR/id_ed25519" -P "$SSH_PORT" \
            "$CLOUD_USER@127.0.0.1:/workspace/scripts/test/$f" \
            "$REPO_ROOT/scripts/test/${f%.log}-$DISTRO.log" 2>/dev/null || true
    done

    log_phase "8/8 teardown"
    # cleanup trap handles VM kill + temp dir removal.
    exit $in_vm_rc
}

if [ "${DEV_CI_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
