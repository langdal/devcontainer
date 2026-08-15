#!/bin/bash
# --- Threat model (see SECURITY.md) ---
# May: run firewall-init.sh as root before anything else and fail closed
# (abort container startup) if it errors; seed rc files/git identity/JVM
# proxy config only when absent, never overwriting a value already in the
# home volume.
# Must never: start the payload command (gosu vscode "$@") if
# firewall-init.sh/firewall-disable.sh/dind-init.sh/pind-init.sh reported
# failure, or fall through to an unfirewalled shell on any error.
set -u

# --- Suppress AAAA lookups ---
# Two reasons, either sufficient:
# 1. Firewalled mode: firewall-init.sh default-DROPs IPv6 OUTPUT, so AAAA
#    results are unusable for direct clients — and worse, actively harmful
#    for tinyproxy: a runtime that installs a v6 default route (podman 5's
#    pasta) makes getaddrinfo return AAAA first, and tinyproxy then hangs
#    ~20s per request trying unreachable v6 upstreams before any fallback.
# 2. No v6 default route (docker's default bridge): AAAA can't be used, and
#    some upstream resolvers (home routers, systemd-resolved forwarding to
#    one) silently drop AAAA queries, making glibc's parallel A+AAAA
#    getaddrinfo() intermittently return EAI_AGAIN ("Temporary failure in
#    name resolution" from tinyproxy). `getent`-style callers escape via
#    AI_ADDRCONFIG; tinyproxy and many others do not.
# Net: always skip AAAA except in maintenance mode on a host with a real v6
# route (the one case where v6 may genuinely work end-to-end).
if { [ -z "${DEVCONTAINER_MAINTENANCE:-}" ] || [ -z "$(ip -6 route show default 2>/dev/null)" ]; } \
   && [ -w /etc/resolv.conf ] \
   && ! grep -qE '^options[^#]*\bno-aaaa\b' /etc/resolv.conf; then
    echo 'options no-aaaa' >> /etc/resolv.conf
fi

# --- Firewall (skipped in maintenance mode) ---
if [ -z "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    if ! /usr/local/sbin/firewall-init.sh; then
        echo "FATAL: firewall-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    export HTTPS_PROXY=http://127.0.0.1:8888
    export HTTP_PROXY=http://127.0.0.1:8888
    export NO_PROXY=localhost,127.0.0.1,host.docker.internal
    cat > /etc/profile.d/proxy.sh <<'EOF'
export HTTPS_PROXY=http://127.0.0.1:8888
export HTTP_PROXY=http://127.0.0.1:8888
export NO_PROXY=localhost,127.0.0.1,host.docker.internal
EOF
    chmod 644 /etc/profile.d/proxy.sh

    # Opt-in: bring the container up with the firewall already open. Identical
    # effect to starting normally and then running `dev --disable-firewall`:
    # firewall-init.sh above set up tinyproxy + iptables; this tears the egress
    # block down and flips tinyproxy to allow-all. The proxy env vars stay
    # exported (tinyproxy keeps running, just permissive), so HTTP_PROXY-
    # honouring clients work exactly as in the toggle-off case.
    if [ -n "${DEVCONTAINER_FW_DISABLED:-}" ]; then
        if ! /usr/local/sbin/firewall-disable.sh; then
            echo "FATAL: firewall-disable.sh failed; refusing to start container" >&2
            exit 1
        fi
    fi
fi

# --- Maintenance mode: re-grant sudo for vscode and warn loudly ---
if [ -n "${DEVCONTAINER_MAINTENANCE:-}" ]; then
    cat > /etc/sudoers.d/vscode-maint <<'EOF'
vscode ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 /etc/sudoers.d/vscode-maint
    cat > /etc/profile.d/zz-maint-banner.sh <<'EOF'
echo
echo "=========================================================="
echo "  MAINTENANCE MODE - firewall disabled, sudo enabled."
echo "  Do not run untrusted code in this container."
echo "=========================================================="
echo
EOF
    chmod 644 /etc/profile.d/zz-maint-banner.sh
fi

# --- DinD mode: launch rootless dockerd ---
if [ -n "${DEVCONTAINER_DIND:-}" ]; then
    if ! /usr/local/sbin/dind-init.sh; then
        echo "FATAL: dind-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    # Export to entrypoint's env so non-login children (gosu vscode CMD)
    # see DOCKER_HOST / XDG_RUNTIME_DIR. dind-init.sh also writes these to
    # /etc/profile.d/dind.sh for interactive shells, but profile.d is only
    # sourced by login shells.
    export DOCKER_HOST=unix:///home/vscode/.dind-run/docker.sock
    export XDG_RUNTIME_DIR=/home/vscode/.dind-run
fi

# --- PinD mode: launch rootless podman system service ---
if [ -n "${DEVCONTAINER_PIND:-}" ]; then
    if ! /usr/local/sbin/pind-init.sh; then
        echo "FATAL: pind-init.sh failed; refusing to start container" >&2
        exit 1
    fi
    # Export to entrypoint's env so non-login children (gosu vscode CMD) see
    # DOCKER_HOST / XDG_RUNTIME_DIR. pind-init.sh also writes these to
    # /etc/profile.d/pind.sh for login shells.
    export DOCKER_HOST=unix:///home/vscode/.pind-run/podman.sock
    export XDG_RUNTIME_DIR=/home/vscode/.pind-run
fi

# Run user-context startup tasks as vscode (preserves file ownership under
# /home/vscode and /mise; ensures 'git config --global' lands in
# /home/vscode/.gitconfig).
gosu vscode bash <<'INNER'
set -u

# Seed .zshrc/.bashrc from the Dockerfile's staged copies if the home volume
# came up empty (the volume mount shadows the rc files baked into the image).
for rc in .zshrc .bashrc; do
    if [[ ! -f "/home/vscode/$rc" ]] && [[ -f "/etc/skel.devcontainer/$rc" ]]; then
        cp "/etc/skel.devcontainer/$rc" "/home/vscode/$rc"
    fi
done

# Idempotently ensure mise activation is present in both rc files. A home
# volume created by an older image (or a user's pre-existing one) can have an
# rc file that predates a given activation line — most notably .bashrc, which
# never carried `mise activate` before. Without activation a bash shell gets
# the /mise/shims PATH entry (so `java` resolves) but no exported tool env,
# leaving JAVA_HOME unset and breaking gradlew and similar. Append only when
# missing so a customised rc file is otherwise left untouched.
ensure_mise_activate() {
    local rc="/home/vscode/$1" shell="$2" line
    line="eval \"\$(mise activate ${shell})\""
    [[ -f "$rc" ]] || return 0
    grep -qF "mise activate ${shell}" "$rc" && return 0
    printf '%s\n' "$line" >> "$rc"
}
ensure_mise_activate .zshrc  zsh
ensure_mise_activate .bashrc bash

# Try to install mise-managed tools if a project mise.toml exists.
if [[ -f /workspace/mise.toml ]] || [[ -f /workspace/.mise.toml ]]; then
    if ! mise install; then
        echo "WARNING: mise install failed, but continuing with container startup" >&2
        # A common, easy-to-miss cause: a project tool downloads from a host
        # that is only in the workspace .devcontainer-allowlist, but that
        # allowlist was not approved on the host, so the firewall blocked the
        # download. The tool then silently never lands on PATH. Point at the
        # fix rather than leaving the user to rediscover it.
        if [[ -f /workspace/.devcontainer-allowlist ]] \
           && [[ "${DEVCONTAINER_PROJECT_ALLOWLIST:-}" != "applied" ]]; then
            echo "         NOTE: /workspace/.devcontainer-allowlist is present but was NOT" >&2
            echo "         applied to the firewall, so any download host listed only there" >&2
            echo "         is blocked. If that caused the failure above, approve the allowlist" >&2
            echo "         on the host: run 'dev' interactively and accept the prompt (or set" >&2
            echo "         DEV_ASSUME_YES=1), then restart the container so mise install retries." >&2
        fi
    fi
fi

# Seed Maven/Gradle proxy config. JVM tools ignore HTTP(S)_PROXY env vars, so
# without these files their downloads bypass tinyproxy, the kernel silently
# drops the packets, and the user sees "could not be resolved" with no network
# hint. Seed-only: never overwrite a file the user already customised (same
# contract as the git identity seeding below).
if [ -n "${HTTPS_PROXY:-}" ]; then
    if [ ! -f /home/vscode/.m2/settings.xml ]; then
        mkdir -p /home/vscode/.m2
        cat > /home/vscode/.m2/settings.xml <<'M2EOF'
<!-- Seeded by the devcontainer entrypoint: JVM tools do not honour the
     HTTPS_PROXY env var, so Maven needs the firewall proxy configured here.
     Safe to edit; the entrypoint never overwrites an existing file. -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <proxies>
    <proxy>
      <id>devcontainer-firewall</id>
      <active>true</active>
      <protocol>http</protocol>
      <host>127.0.0.1</host>
      <port>8888</port>
      <nonProxyHosts>localhost|127.0.0.1|host.docker.internal</nonProxyHosts>
    </proxy>
  </proxies>
</settings>
M2EOF
    fi
    if [ ! -f /home/vscode/.gradle/gradle.properties ]; then
        mkdir -p /home/vscode/.gradle
        cat > /home/vscode/.gradle/gradle.properties <<'GRADLEEOF'
# Seeded by the devcontainer entrypoint: JVM tools do not honour the
# HTTPS_PROXY env var, so Gradle needs the firewall proxy configured here.
# Safe to edit; the entrypoint never overwrites an existing file.
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=8888
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=8888
systemProp.http.nonProxyHosts=localhost|127.0.0.1|host.docker.internal
GRADLEEOF
    fi
fi

# Configure git to trust /workspace as a safe directory.
git config --global --add safe.directory /workspace

# Seed git identity from the host ONLY if the container has none yet (never
# clobber an identity already present on a persisted/shared home volume).
if [ -n "${DEV_GIT_NAME:-}" ] && [ -z "$(git config --global user.name || true)" ]; then
    git config --global user.name "$DEV_GIT_NAME"
fi
if [ -n "${DEV_GIT_EMAIL:-}" ] && [ -z "$(git config --global user.email || true)" ]; then
    git config --global user.email "$DEV_GIT_EMAIL"
fi
INNER

# Drop privileges to vscode for the actual command.
exec gosu vscode "$@"
