# Pinned to a sha256 digest so the same image is reproduced byte-for-byte.
# Bump the digest deliberately by re-running:
#     docker manifest inspect mcr.microsoft.com/devcontainers/base:ubuntu \
#         | grep -i digest
FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:7ee7da33a68d997971660d91ecc8372e55a38a777c3c6bd6808daf91928052db AS base

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

# Install mise to /usr/local/bin/mise. Version is pinned so the same mise
# binary is fetched on every build; the installer script itself is fetched
# from https://mise.run and is small / vendor-published, so we trust TLS.
ARG MISE_VERSION=v2026.5.10
RUN curl -fsSL https://mise.run \
    | MISE_INSTALL_PATH=/usr/local/bin/mise MISE_VERSION="${MISE_VERSION}" sh

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

# Switch to vscode user and install base tools.
# Optionally consume a BuildKit secret named `github_token` so mise can
# authenticate against the GitHub API when fetching release assets — the
# unauthenticated rate limit (60/hr) is easy to exhaust on a cold build.
# The mount is non-required; builds without the secret still work, they
# just fall back to anonymous requests.
USER vscode
RUN --mount=type=secret,id=github_token,uid=1000 \
    if [ -s /run/secrets/github_token ]; then \
        GITHUB_TOKEN="$(cat /run/secrets/github_token)" \
        GITHUB_API_TOKEN="$(cat /run/secrets/github_token)" \
        mise install; \
    else \
        mise install; \
    fi

# Add mise shell activation to zsh AND bash. Single quotes are intentional —
# we want the literal '$(mise activate ...)' written to the rc file, not the
# build-time expansion. Activation (not just the /mise/shims PATH entry baked
# via ENV) is what exports tool env vars like JAVA_HOME; without it a bash
# shell resolves `java` via the shim but leaves JAVA_HOME unset, which breaks
# JAVA_HOME-dependent tooling such as gradlew.
# hadolint ignore=DL3059,SC2016
RUN echo 'eval "$(mise activate zsh)"'  >> /home/vscode/.zshrc && \
    echo 'eval "$(mise activate bash)"' >> /home/vscode/.bashrc

# Stage reference copy of managed home files for entrypoint sync
USER root
RUN mkdir -p /etc/skel.devcontainer && \
    cp /home/vscode/.zshrc  /etc/skel.devcontainer/.zshrc && \
    cp /home/vscode/.bashrc /etc/skel.devcontainer/.bashrc

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

# Bake the base allowlist and the firewall init/disable scripts into the image.
COPY allowlist.base /etc/devcontainer/allowlist.base
COPY --chmod=755 firewall-init.sh /usr/local/sbin/firewall-init.sh
COPY --chmod=755 firewall-disable.sh /usr/local/sbin/firewall-disable.sh

# Set working directory
WORKDIR /workspace

# Copy entrypoint script
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Stamp the dev-script version onto the image so `./dev` can detect when
# an image was built by an older script and prompt for a rebuild. Kept as
# the last LABEL layer so version bumps don't bust the heavy layers above;
# the dind stage inherits this label via FROM base.
#
# The no-op RUN below is required for the LABEL's cache to invalidate
# correctly: Docker's BuildKit includes an ARG's resolved value in the
# cache key of every following instruction, but podman/buildah's build
# engine does not do this for metadata-only instructions (LABEL/ENV) —
# only for instructions it substitutes into an actual shell command
# (RUN). Without it, `docker buildx build` on a host where `docker` is
# podman's docker-shim (common on Linux without real Docker installed)
# silently reuses the cached LABEL layer forever, so accepting `./dev`'s
# version-rebuild prompt never actually updates the label and the prompt
# reappears on every subsequent run.
ARG DEV_VERSION=unknown
RUN : "${DEV_VERSION}"
LABEL dev.version="${DEV_VERSION}"

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
# jq               - dind-init.sh merges the proxy config into ~/.docker/config.json
# iproute2         - already in base, listed for clarity
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        fuse-overlayfs \
        uidmap \
        slirp4netns \
        dbus-user-session \
        jq && \
    rm -rf /var/lib/apt/lists/*

# Pinned rootless docker bundle. download.docker.com publishes no .sha256
# sidecars for the static bundles, so the expected digests are pinned here,
# in-repo, next to the version they belong to. Recompute on a version bump
# (per arch and bundle):
#   curl -fsSL https://download.docker.com/linux/static/stable/<arch>/<bundle>-<version>.tgz | sha256sum
# Version pinning + sha256 verification means the image is reproducible
# from a known good tarball and survives the firewall (download.docker.com
# is allowlisted).
ARG DOCKER_VERSION=27.3.1
ARG DOCKER_SHA256_X86_64=9b4f6fe406e50f9085ee474c451e2bb5adb119a03591f467922d3b4e2ddf31d3
ARG DOCKER_SHA256_AARCH64=4da6a6c7502b7ab561675a5ff5ac192d9b49d76d0b8847cf17ade246122279f4
ARG DOCKER_ROOTLESS_SHA256_X86_64=4e897d5838c1d9d89a7540f4558a3a0d1ef90cfc263c32b7346e8f58415ce4c3
ARG DOCKER_ROOTLESS_SHA256_AARCH64=35a4c4d5e0bd3c3d2b4c83255cd91cc2882f35c1f5aa1dbd4d171427a3bfad66
# 'cd /tmp' here is local to this RUN; WORKDIR would change the WORKDIR
# globally for the image and the image's working directory is /workspace.
# hadolint ignore=DL3003
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)  docker_sha="$DOCKER_SHA256_X86_64";  rootless_sha="$DOCKER_ROOTLESS_SHA256_X86_64" ;; \
        aarch64) docker_sha="$DOCKER_SHA256_AARCH64"; rootless_sha="$DOCKER_ROOTLESS_SHA256_AARCH64" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    for bundle in docker docker-rootless-extras; do \
        case "$bundle" in \
            docker) expected="$docker_sha" ;; \
            *)      expected="$rootless_sha" ;; \
        esac; \
        url="https://download.docker.com/linux/static/stable/${arch}/${bundle}-${DOCKER_VERSION}.tgz"; \
        curl -fsSLo "${bundle}.tgz" "${url}"; \
        echo "${expected}  ${bundle}.tgz" | sha256sum -c -; \
        tar -xzf "${bundle}.tgz" -C /usr/local/bin --strip-components=1; \
        rm -f "${bundle}.tgz"; \
    done

# docker compose v2 CLI plugin. Installed under the system-wide plugin
# path so `docker compose ...` resolves for the rootless dockerd run by
# vscode.
ARG COMPOSE_VERSION=2.40.3
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

# docker buildx CLI plugin. Without it `docker build` falls back to the
# legacy builder, which cannot handle BuildKit Dockerfiles (`# syntax`,
# RUN --mount=type=cache/secret) — exactly what this repo's own Dockerfile
# and most modern projects use. buildx publishes a single checksums.txt per
# release rather than per-asset .sha256, so verify against that.
ARG BUILDX_VERSION=0.34.1
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)  bx_arch=amd64 ;; \
        aarch64) bx_arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}"; \
    asset="buildx-v${BUILDX_VERSION}.linux-${bx_arch}"; \
    curl -fsSLo /tmp/docker-buildx "${base}/${asset}"; \
    expected="$(curl -fsSL "${base}/checksums.txt" \
        | awk -v a="${asset}" '{ f=$2; sub(/^\*/,"",f); if (f==a) print $1 }')"; \
    echo "${expected}  /tmp/docker-buildx" | sha256sum -c -; \
    install -D -m 0755 /tmp/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx; \
    rm -f /tmp/docker-buildx

COPY allowlist.dind /etc/devcontainer/allowlist.dind
COPY --chmod=755 dind-init.sh /usr/local/sbin/dind-init.sh

# NOTE: do NOT switch USER to vscode here. The entrypoint runs as root in
# the base image (firewall-init.sh + dind-init.sh both need root) and drops
# to vscode via gosu. Setting `USER vscode` would break firewall-init.

# =============================================================================
FROM base AS pind
# Rootless podman engine as a sibling to the dind (rootless dockerd) target.
# Podman is daemonless: `podman pull`/`build` run in the calling vscode
# process in the container's main netns, so their own egress uses the same
# OUTPUT chain as an ordinary curl. Nested-container egress still routes via
# the slirp gateway 10.0.2.2:8888, exactly like dind.
# Stays root: entrypoint runs firewall-init.sh + pind-init.sh as root, then
# drops to vscode via gosu. Do NOT set USER vscode here.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3002
USER root

# podman            - the nested container engine (pulls in crun/conmon/
#                     containers-common transitively)
# fuse-overlayfs    - rootless storage driver
# uidmap            - newuidmap / newgidmap for user-namespace allocation
# slirp4netns       - per-container network stack (pinned backend; see
#                     containers.conf in pind-init.sh)
# dbus-user-session - user session paths for rootless podman
# jq                - pind-init.sh merges config json
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        podman \
        fuse-overlayfs \
        uidmap \
        slirp4netns \
        dbus-user-session \
        jq && \
    rm -rf /var/lib/apt/lists/*

# docker compose v2 CLI plugin, so `docker compose ...` (and DOCKER_HOST-based
# tooling) resolves against the podman compat socket. Installed under the
# system-wide plugin path.
ARG COMPOSE_VERSION=2.40.3
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
COPY --chmod=755 pind-init.sh /usr/local/sbin/pind-init.sh

# NOTE: do NOT switch USER to vscode here (same reason as the dind target).
