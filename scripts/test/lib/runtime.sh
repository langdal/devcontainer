# scripts/test/lib/runtime.sh
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
