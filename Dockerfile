FROM mcr.microsoft.com/devcontainers/base:ubuntu AS base

# Use bash with pipefail for every RUN. This catches early-pipeline
# failures (e.g. `curl … | sh` failing on the curl side) that the
# default `sh -c` swallows.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Allow UID/GID override so the image can be built for the invoking
# host user. The dev script reads `id -u` / `id -g` and passes both
# as build-args; the labels are what the dev script later inspects to
# detect a mismatch on subsequent runs.
ARG USER_UID=1000
ARG USER_GID=1000

# Apply UID/GID override if needed (vscode already exists at 1000:1000
# in the base image). On macOS the host's primary GID is 20, which
# collides with Ubuntu's `dialout` group; renumber any conflicting
# group out of the way before remapping vscode.
RUN if [ "${USER_UID}" != "1000" ] || [ "${USER_GID}" != "1000" ]; then \
        if getent group "${USER_GID}" >/dev/null 2>&1 \
           && [ "$(getent group "${USER_GID}" | cut -d: -f1)" != "vscode" ]; then \
            existing_group="$(getent group "${USER_GID}" | cut -d: -f1)"; \
            groupmod --gid 65334 "$existing_group"; \
        fi && \
        groupmod --gid ${USER_GID} vscode && \
        usermod --uid ${USER_UID} --gid ${USER_GID} vscode && \
        chown -R ${USER_UID}:${USER_GID} /home/vscode; \
    fi

LABEL dev.uid="${USER_UID}" dev.gid="${USER_GID}"

# Install firewall stack and supporting tools.
# - iptables/ipset: kernel-level packet filtering
# - tinyproxy: hostname-filtering forward proxy
# - dnsutils: getent/dig for diagnostics
# - gosu: clean privilege drop in the entrypoint
# - iproute2: 'ss' for tinyproxy bind verification
# - tcpdump: read NFLOG group for `dev --monitor-fw`
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        tinyproxy \
        dnsutils \
        gosu \
        iproute2 \
        tcpdump && \
    rm -rf /var/lib/apt/lists/*

# Strip vscode's passwordless sudo. vscode is the agent-facing user; if it
# can sudo, it can flush iptables and defeat the firewall. Maintenance mode
# re-creates a sudoers fragment at container runtime.
RUN rm -f /etc/sudoers.d/vscode /etc/sudoers.d/nopasswd && \
    if grep -rEl '^[[:space:]]*vscode[[:space:]]' /etc/sudoers.d/ 2>/dev/null; then \
        grep -rEl '^[[:space:]]*vscode[[:space:]]' /etc/sudoers.d/ | xargs -r rm -f; \
    fi

# Install mise to /usr/local/bin/mise
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Set mise environment variables (critical for baked tools pattern)
ENV MISE_DATA_DIR="/mise" \
    MISE_CONFIG_DIR="/mise" \
    MISE_CACHE_DIR="/mise/cache" \
    MISE_TRUSTED_CONFIG_PATHS="/workspace" \
    MISE_YES=1

# Add mise shims to PATH for non-interactive use
ENV PATH="/mise/shims:${PATH}"

# Create /mise directory owned by vscode user
RUN mkdir -p /mise && chown -R vscode:vscode /mise

# Copy base tool list to mise config location (named mise.base.toml so it
# does not get picked up as a mise config when this repo itself is opened)
COPY --chown=vscode:vscode mise.base.toml /mise/config.toml

# Switch to vscode user and install base tools
USER vscode
RUN mise install

# Add mise shell activation to zsh. Single quotes are intentional — we
# want the literal '$(mise activate zsh)' written to .zshrc, not the
# build-time expansion.
# hadolint ignore=DL3059,SC2016
RUN echo 'eval "$(mise activate zsh)"' >> /home/vscode/.zshrc

# Stage reference copy of managed home files for entrypoint sync
USER root
RUN mkdir -p /etc/skel.devcontainer && \
    cp /home/vscode/.zshrc /etc/skel.devcontainer/.zshrc

# --- Firewall staging ---
# Ensure the 'proxy' system user exists (the tinyproxy package may already
# create it). iptables -m owner uses this UID to allow only the proxy process
# out on 80/443. The image intentionally finalises as root: entrypoint.sh
# runs firewall-init.sh (needs root) and then drops to vscode via gosu.
# hadolint ignore=DL3002
USER root
RUN id proxy >/dev/null 2>&1 || \
        useradd --system --no-create-home --shell /usr/sbin/nologin proxy
RUN mkdir -p /etc/devcontainer

# Bake the base allowlist and the firewall init script into the image.
COPY allowlist.base /etc/devcontainer/allowlist.base
COPY --chmod=755 firewall-init.sh /usr/local/sbin/firewall-init.sh

# Set working directory
WORKDIR /workspace

# Copy entrypoint script
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Use entrypoint for initialization. CMD is "sleep infinity" so the
# container stays alive when something else supplies the long-running
# foreground process via docker run / docker compose / a devcontainer.json
# with overrideCommand=false. `./dev` always passes its own command
# (zsh, or `--`-passthrough), so it never sees this default.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]

# ===========================================================================
# DinD stage: rootless dockerd, fuse-overlayfs, uidmap.
# Built with: docker build --target dind -t generic-devcontainer:dind .
# Used by `dev --dind`. Adds the rootless docker bundle on top of base.
# ===========================================================================
FROM base AS dind
# Reassert pipefail for the dind stage (SHELL doesn't always carry across
# multi-stage builds for some static analysers).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Like the base image, dind stays as root: entrypoint runs firewall-init.sh
# and dind-init.sh as root before dropping to vscode via gosu.
# hadolint ignore=DL3002
USER root

# fuse-overlayfs   - storage driver for rootless docker
# uidmap           - newuidmap / newgidmap for user-namespace allocation
# slirp4netns      - per-container network stack for rootless docker
# dbus-user-session- enables systemd-style user session paths if present
# iproute2         - already in base, listed for clarity
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        fuse-overlayfs \
        uidmap \
        slirp4netns \
        dbus-user-session && \
    rm -rf /var/lib/apt/lists/*

# Pinned rootless docker bundle. We fetch the published .sha256 sidecar
# from download.docker.com and verify with sha256sum -c. Version pinning +
# sha256 verification means the image is reproducible from a known good
# tarball and survives the firewall (download.docker.com is allowlisted).
ARG DOCKER_VERSION=27.3.1
# 'cd /tmp' here is local to this RUN; WORKDIR would change the WORKDIR
# globally for the image and the image's working directory is /workspace.
# hadolint ignore=DL3003
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    for bundle in docker docker-rootless-extras; do \
        url="https://download.docker.com/linux/static/stable/${arch}/${bundle}-${DOCKER_VERSION}.tgz"; \
        curl -fsSLo "${bundle}.tgz" "${url}"; \
        curl -fsSLo "${bundle}.tgz.sha256" "${url}.sha256" \
            || (cd /tmp && sha256sum "${bundle}.tgz" > "${bundle}.tgz.sha256.computed" \
                && echo "WARN: docker.com did not publish a .sha256 sidecar for ${bundle}; computed locally:" \
                && cat "${bundle}.tgz.sha256.computed" \
                && cp "${bundle}.tgz.sha256.computed" "${bundle}.tgz.sha256"); \
        sha256sum -c "${bundle}.tgz.sha256"; \
        tar -xzf "${bundle}.tgz" -C /usr/local/bin --strip-components=1; \
        rm -f "${bundle}.tgz" "${bundle}.tgz.sha256"; \
    done

# docker compose v2 CLI plugin. Installed under the system-wide plugin
# path so `docker compose ...` resolves for the rootless dockerd run by
# vscode.
ARG COMPOSE_VERSION=2.30.3
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${arch}"; \
    curl -fsSLo /tmp/docker-compose "${url}"; \
    expected="$(curl -fsSL "${url}.sha256" | awk '{print $1}')"; \
    echo "${expected}  /tmp/docker-compose" | sha256sum -c -; \
    install -D -m 0755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose; \
    rm -f /tmp/docker-compose

COPY allowlist.dind /etc/devcontainer/allowlist.dind
COPY --chmod=755 dind-init.sh /usr/local/sbin/dind-init.sh

# NOTE: do NOT switch USER to vscode here. The entrypoint runs as root in
# the base image (firewall-init.sh + dind-init.sh both need root) and drops
# to vscode via gosu. Setting `USER vscode` would break firewall-init.
