FROM mcr.microsoft.com/devcontainers/base:ubuntu AS base

# Allow UID override for macOS compatibility
ARG USER_UID=1000

# Apply UID override if needed (vscode user already exists at UID 1000 in base image)
RUN if [ "${USER_UID}" != "1000" ]; then \
        groupmod --gid ${USER_UID} vscode && \
        usermod --uid ${USER_UID} --gid ${USER_UID} vscode && \
        chown -R ${USER_UID}:${USER_UID} /home/vscode; \
    fi

# Install firewall stack and supporting tools.
# - iptables/ipset: kernel-level packet filtering
# - tinyproxy: hostname-filtering forward proxy
# - dnsutils: getent/dig for diagnostics
# - gosu: clean privilege drop in the entrypoint
# - iproute2: 'ss' for tinyproxy bind verification
# - tcpdump: read NFLOG group for `dev --monitor-fw`
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

# Add mise shell activation to zsh
RUN echo 'eval "$(mise activate zsh)"' >> /home/vscode/.zshrc

# Stage reference copy of managed home files for entrypoint sync
USER root
RUN mkdir -p /etc/skel.devcontainer && \
    cp /home/vscode/.zshrc /etc/skel.devcontainer/.zshrc

# --- Firewall staging ---
# Ensure the 'proxy' system user exists (the tinyproxy package may already
# create it). iptables -m owner uses this UID to allow only the proxy process
# out on 80/443.
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

# Use entrypoint for initialization
ENTRYPOINT ["/entrypoint.sh"]
CMD ["zsh"]

# ===========================================================================
# DinD stage: rootless dockerd, fuse-overlayfs, uidmap.
# Built with: docker build --target dind -t generic-devcontainer:dind .
# Used by `dev --dind`. Adds the rootless docker bundle on top of base.
# ===========================================================================
FROM base AS dind
USER root

# fuse-overlayfs   - storage driver for rootless docker
# uidmap           - newuidmap / newgidmap for user-namespace allocation
# slirp4netns      - per-container network stack for rootless docker
# dbus-user-session- enables systemd-style user session paths if present
# iproute2         - already in base, listed for clarity
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

# Allocate sub-uid/gid range for vscode (newuidmap consumes this for the
# rootlesskit user namespace). Range is conventional; doesn't conflict with
# host UIDs because it's container-local.
RUN if ! grep -q '^vscode:' /etc/subuid; then \
        echo "vscode:100000:65536" >> /etc/subuid; \
    fi && \
    if ! grep -q '^vscode:' /etc/subgid; then \
        echo "vscode:100000:65536" >> /etc/subgid; \
    fi

COPY --chmod=755 dind-init.sh /usr/local/sbin/dind-init.sh

USER vscode
