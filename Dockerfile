FROM mcr.microsoft.com/devcontainers/base:ubuntu

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
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        tinyproxy \
        dnsutils \
        gosu \
        iproute2 && \
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

# Copy mise.toml to mise config location
COPY --chown=vscode:vscode mise.toml /mise/config.toml

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
