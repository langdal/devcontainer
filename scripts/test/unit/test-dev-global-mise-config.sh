#!/usr/bin/env bash
# Unit: the host-side global mise config is bind-mounted read-only into
# /etc/mise/conf.d/ in the dry-run run command, resolved from DEV_MISE_CONFIG or
# the XDG default. A stub runtime stands in for docker, so this needs neither
# docker nor podman. DEV_FAKE_OS=Linux pins the docker path: on a macOS
# host (the macos-checks CI job) dev only accepts podman and would refuse
# the stub before reaching the mount logic.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/myproj" "$WORK/bin" "$WORK/xdg/devcontainer" "$WORK/other dir"
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
[[ "$1" == version ]] && echo 27.0.0
exit 0
EOF
chmod +x "$WORK/bin/docker"
TARGET=/etc/mise/conf.d/user.toml

dev() {
    (cd "$WORK/myproj" && env -u DEV_RUNTIME -u DEV_MISE_CONFIG \
        PATH="$WORK/bin:$PATH" DEV_NO_UPDATE_CHECK=1 XDG_CONFIG_HOME="$WORK/xdg" \
        DEV_FAKE_OS=Linux \
        "$@" "$ROOT/dev" exec --dry-run -- echo hi </dev/null 2>&1)
}
fail() { echo "$1: $out"; exit 1; }

# 1. No config anywhere: no conf.d mount, no warning.
out=$(dev)
echo "$out" | grep -q -- "$TARGET" && fail "mounted a config that does not exist"
echo "$out" | grep -qi 'warning.*mise' && fail "warned without DEV_MISE_CONFIG set"

# 2. XDG default path: mounted read-only.
echo '[tools]' > "$WORK/xdg/devcontainer/mise.toml"
out=$(dev)
echo "$out" | grep -qF -- "-v $WORK/xdg/devcontainer/mise.toml:$TARGET:ro" \
    || fail "XDG default config not mounted read-only"
# Regression: a target under /mise lands in the shared devcontainer-mise
# volume, where the runtime's root-owned mountpoint stub outlives the
# container and makes mise fail in every container started without the mount.
echo "$out" | grep -qF -- "mise.toml:/mise/" \
    && fail "global mise config mounted inside the shared /mise volume"

# 3. DEV_MISE_CONFIG overrides the default, relative paths resolve against
# the cwd, and a path with a space survives the dry-run quoting.
echo '[tools]' > "$WORK/other dir/m.toml"
out=$(dev DEV_MISE_CONFIG="../other dir/m.toml")
echo "$out" | grep -qF -- "$TARGET:ro" || fail "DEV_MISE_CONFIG not mounted"
echo "$out" | grep -qF -- "other\\ dir/m.toml:$TARGET" \
    || fail "DEV_MISE_CONFIG path not resolved/quoted"
echo "$out" | grep -qF -- "xdg/devcontainer/mise.toml" \
    && fail "default mounted despite DEV_MISE_CONFIG"

# 4. DEV_MISE_CONFIG set but empty disables the feature.
out=$(dev DEV_MISE_CONFIG=)
echo "$out" | grep -q -- "$TARGET" && fail "empty DEV_MISE_CONFIG did not disable"

# 5. DEV_MISE_CONFIG naming a missing file: warn, start without it.
out=$(dev DEV_MISE_CONFIG="$WORK/nope.toml")
echo "$out" | grep -q -- "$TARGET" && fail "mounted a missing DEV_MISE_CONFIG"
echo "$out" | grep -q 'DEV_MISE_CONFIG' || fail "no warning for missing DEV_MISE_CONFIG"
echo "$out" | grep -q 'echo hi' || fail "missing DEV_MISE_CONFIG blocked startup"

echo ok
