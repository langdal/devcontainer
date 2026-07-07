# Podman-in-Podman (`--pind`) Design

**Date:** 2026-07-07
**Status:** Approved for planning
**Related:** [dind design](2026-04-30-dind-design.md), [agent sandbox firewall design](2026-04-30-agent-sandbox-firewall-design.md)

## Summary

Add an opt-in `--pind` mode that runs a **rootless podman** engine inside the
dev container, as a sibling to the existing `--dind` (rootless dockerd) mode.
The existing `--dind` mode is left untouched. `--pind` meets the same
security bar as `--dind`: all nested image pulls and nested-container egress
flow through the tinyproxy allowlist, so the project's exfiltration threat
model holds identically.

This is a "build alongside" feature (Approach A): a parallel Dockerfile
target, init script, `dev` flag, container name, and cache volume. Shared
code is factored out only where it is clearly free (the runtime
device/capability/security block, the two preflights, and the registry
allowlist).

## Motivation

Users who prefer podman as their nested container engine — for its daemonless
model, rootless-by-default posture, or tooling preference — currently have no
option: `--dind` always provides Docker's `dockerd`, regardless of the host
runtime. `--pind` gives them a nested podman engine while preserving the full
firewall/exfiltration guarantees that are the project's primary security
feature.

## Key architectural difference: podman is daemonless

Unlike `dockerd`, podman has no long-lived daemon for image operations.
`podman pull` and `podman build` execute **in the calling `vscode` process,
in the container's main network namespace**. This changes the networking
story in one important way:

- **dind:** `dockerd-rootless` runs in its own RootlessKit network namespace,
  separate from the container's main-ns OUTPUT chain. Its own pulls must be
  routed to the proxy at the slirp gateway address `10.0.2.2:8888`.
- **pind:** podman's own pulls happen in the container's main netns, so they
  traverse the same OUTPUT chain as an ordinary `curl` and reach tinyproxy
  directly at `127.0.0.1:8888` — a cleaner, more direct parity story.

The `10.0.2.2` indirection is still needed for **nested** workloads (see
Networking below), so pind ends up with the same split dind uses:
`127.0.0.1` for the engine's own pulls, `10.0.2.2` for nested containers.

One decided feature (see "Docker-compat socket" below) does reintroduce a
background process: `podman system service`. But the image-pull path itself
remains daemonless and simpler than dind.

## Component inventory

`pind` mirrors `dind` piece-for-piece:

| Piece | dind (existing) | pind (new) |
|---|---|---|
| Dockerfile target | `dind` | `pind` (also `FROM base`) |
| Init script | `dind-init.sh` | `pind-init.sh` |
| `dev` flag | `--dind` | `--pind` |
| Container name | `dev-<dir>-dind` | `dev-<dir>-pind` |
| Cache volume | `devcontainer-dind` | `devcontainer-pind` |
| Env signal | `DEVCONTAINER_DIND=1` | `DEVCONTAINER_PIND=1` |
| Storage path | `~/.local/share/docker` | `~/.local/share/containers` |
| Verify probe | `verify-dind.sh` | `verify-pind.sh` |

### Shared, factored out (serves both modes)

- **Runtime device/capability/security block** in `lib/dev/lifecycle.sh`:
  `--device=/dev/fuse`, `--device=/dev/net/tun`, `--cap-add=SYS_ADMIN`,
  `--security-opt apparmor=unconfined`, `seccomp=unconfined`,
  `systempaths=unconfined`, `label=disable`. Rootless podman needs the same
  set: `newuidmap`/`newgidmap` require `CAP_SYS_ADMIN` in the writer's userns
  chain for multi-range maps; slirp4netns needs `/dev/net/tun`;
  fuse-overlayfs needs `/dev/fuse`; nested `runc`/`crun` needs the proc-mask
  and SELinux relaxations. Gate this block on `[[ "$DIND" == true || "$PIND"
  == true ]]`.
- **Preflights** in `lib/dev/preflight.sh`: `preflight_apparmor_userns`
  (requires `kernel.apparmor_restrict_unprivileged_userns=0`) and the
  rootless subid grant (≥165535 subuids/subgids). Both apply unchanged to
  `--pind`. Extend their trigger condition to include `PIND`.
- **Registry allowlist** `allowlist.dind`: the registry hostnames
  (Docker Hub, MCR, Quay, GCR, CloudFront/R2 CDNs) are identical for both
  engines. Keep the filename; merge it into the tinyproxy filter whenever
  **either** nested mode is active (`DEVCONTAINER_DIND` **or**
  `DEVCONTAINER_PIND`), rather than duplicating the list into an
  `allowlist.pind`.

### Mutual exclusion

The current three-way conflict guard (normal / maintenance / dind) becomes
four-way. Both `--pind --dind` and `--pind --maintenance` are fatal errors,
mirroring the existing `--dind --maintenance` guard in `dev`. The
cross-context `refuse_if_running` checks gain a `pind` entry so starting one
mode refuses when another mode's container for the same workspace is running.

## Components

### 1. Dockerfile `pind` target

`FROM base AS pind`, staying as root (entrypoint drops to vscode via gosu),
mirroring the `dind` target's structure:

- Install podman and its rootless dependencies via apt:
  `podman`, `slirp4netns`, `fuse-overlayfs`, `uidmap`, `dbus-user-session`,
  `jq`. (apt pulls in `crun`/`conmon`/`containers-common` transitively.) OS
  mirrors are already in `allowlist.base`, so the build survives the
  firewall.
- Install the **docker compose v2 CLI plugin** under the system-wide plugin
  path (reuse the exact block from the `dind` target), so `docker compose`
  works against the compat socket.
- No static docker/rootless-extras bundle (that is dind-specific).

Pinning strategy: prefer distro-pinned podman from the Ubuntu repos for
reproducibility consistent with the rest of the base image; if a specific
podman version is required, pin it explicitly with a comment on how to bump,
matching the `DOCKER_VERSION` convention in the `dind` target.

### 2. `pind-init.sh`

Runs from `entrypoint.sh` as root when `DEVCONTAINER_PIND=1`, drops to
`vscode` for the engine setup. Fail-closed (any error → non-zero → entrypoint
aborts the container). Steps:

1. **Allocate `vscode` subuid/subgid** — identical to `dind-init.sh` step 1
   (`vscode:100000:65536` appended to `/etc/subuid` and `/etc/subgid` if
   absent). Done at runtime because `--build-arg USER_UID` can rewrite the
   user after the base image build.
2. **Prepare the containers storage dir** on the fresh named volume:
   `mkdir -p ~/.local/share/containers`, `chown -R vscode:vscode`.
3. **Write `~/.config/containers/storage.conf`**:
   `driver = "overlay"` with `mount_program = "/usr/bin/fuse-overlayfs"`.
4. **Write `~/.config/containers/containers.conf`**:
   - `[network] network_backend = "slirp4netns"` (pin it — see Networking).
   - Inject `http_proxy`/`https_proxy`/`no_proxy` into the nested containers'
     environment (`[containers] env = [...]`) pointing at `10.0.2.2:8888`, so
     nested `podman build` RUN steps and `podman run` workloads reach
     tinyproxy. This is the podman analogue of dind's
     `~/.docker/config.json` `proxies.default` block. Merge, don't clobber,
     any existing config on the home volume.
5. **Set podman's own pull proxy env** via `/etc/profile.d/pind.sh` and the
   service launch env: `HTTPS_PROXY=http://127.0.0.1:8888` (direct, main
   netns).
6. **Start `podman system service`** on a unix socket (see next section),
   export `DOCKER_HOST` and `XDG_RUNTIME_DIR` for interactive shells via
   `/etc/profile.d/pind.sh` and for `dev -- <cmd>` via `entrypoint.sh`
   exports. Wipe stale runtime-dir state on every boot (same rationale as
   dind: the runtime dir lives under the `/home/vscode` named volume and must
   be treated as ephemeral).

### 3. Docker-compat socket (`podman system service`)

Decision: **pind provides a Docker-API-compatible socket** so testcontainers,
docker-compose, and any `DOCKER_HOST`-based tooling work unchanged — a true
drop-in for dind's use cases (dind's verify suite includes a postgres
testcontainers smoke test).

- `pind-init.sh` launches `podman system service --time=0 unix://<sock>` as
  `vscode` in the background.
- Socket location: `~/.pind-run/podman.sock` (parallel to dind's
  `~/.dind-run/docker.sock`), run dir `chmod 0700`, wiped on boot.
- `entrypoint.sh` exports `DOCKER_HOST=unix://.../podman.sock` and
  `XDG_RUNTIME_DIR` when `DEVCONTAINER_PIND=1`.
- Reuse dind's socket-ready wait pattern (poll up to ~15s for the socket,
  tail the log and abort on timeout).

This reintroduces one background process and a socket wait; the image-pull
path stays daemonless.

### 4. `dev` / `lib/dev/lifecycle.sh` wiring

- New `--pind` flag setting `PIND=true` (parsed in the same places `--dind`
  is: main arg loop, scaffold subcommand args).
- New `PIND_NAME="dev-${WORKSPACE_BASENAME}-pind"`.
- When `PIND=true`: `IMAGE_TAG="${IMAGE_NAME}:pind"`, `BUILD_TARGET="pind"`,
  `CONTAINER_NAME="$PIND_NAME"`.
- Add the shared device/cap/security block (gated on `DIND || PIND`) and the
  pind-specific volume mount
  `-v devcontainer-pind:/home/vscode/.local/share/containers` and
  `-e DEVCONTAINER_PIND=1`.
- Four-way mutual-exclusion guard and `refuse_if_running` entries for the
  `pind` container.
- Podman-machine / rootful-connection handling: mirror the dind
  `DIND_RUNTIME_ARGS` logic for macOS+podman if `--pind` on a rootless
  connection hits the same `/dev/net/tun` limitation (validate during
  implementation; likely identical since it is the same slirp4netns/tun
  path).

### 5. `./dev scaffold --pind`

Extend `lib/dev/scaffold.sh` to emit a `.devcontainer/` for pind mode: the
`:pind` image, `DEVCONTAINER_PIND=1`, and the same
`--device`/`--security-opt` run args the dind scaffold uses, plus the apparmor
sysctl comment.

## Networking & firewall

The firewall itself is **unchanged**: iptables `OUTPUT` defaults to DROP,
only the `proxy` uid may reach `:80`/`:443`, tinyproxy filters HTTPS by
hostname against the merged allowlist. vscode has no sudo and cannot alter
iptables. Two egress paths must be funneled through the proxy:

1. **podman's own image pulls** — run as `vscode` in the container main
   netns, so `HTTPS_PROXY=http://127.0.0.1:8888` routes them straight through
   tinyproxy. Reuses the ordinary-`curl` path. Low risk.
2. **nested-container / `podman build` egress** — the nested container's
   network is provided by slirp4netns running in vscode's netns; its egress
   surfaces in the main netns as vscode-owned traffic and is DROPped unless
   proxied. The nested workload reaches tinyproxy on the host container's
   loopback via the slirp gateway `10.0.2.2:8888` — the exact mechanism dind
   relies on. **This is the item most likely to need iteration.**

### The one real risk

Podman 5.x defaults its network backend to **pasta**, whose host-loopback
mapping differs from slirp4netns and would not expose `10.0.2.2` the way
dockerd's slirp does. Mitigation: **pin `network_backend = "slirp4netns"`**
in `containers.conf` so pind reuses the proven `10.0.2.2:8888` path. If
slirp4netns proves problematic under nested podman, the fallback is pasta with
`--map-guest-addr` to expose the container loopback; that path is documented
as the contingency but not the default.

The threat model is preserved: every egress path (engine pulls + nested
workloads) is forced through the allowlist-filtering proxy, and there is no
in-container route to disable iptables.

## Testing & verification

- **Generalize `verify-firewall.sh` checks 8–12** from docker-specific to
  nested-runtime-agnostic. Gate the block on `DEVCONTAINER_DIND ||
  DEVCONTAINER_PIND`, and branch the probe commands (`docker` vs `podman` /
  the compat socket) on which is set. Checks: (8) engine/service reachable,
  (9) rootless mode, (10) registry pull through proxy, (11) nested egress
  blocked, (12) nested loopback reachable.
- **New `scripts/verify-pind.sh`** sibling to `verify-dind.sh`: smoke
  pull/run, postgres testcontainers smoke via the compat socket, and a
  self-build of this repo's Dockerfile with `podman build`.
- **New e2e scenario** `scripts/test/scenarios/NN-pind-*.sh` parallel to the
  dind scenario in the matrix run by `scripts/test/run-all.sh`.
- **Extend preflight scenarios** (subid grant, apparmor) to also exercise
  `--pind`.

## Documentation

- README.md: add a `--pind` section parallel to the `--dind` section
  (what it is, when to use it, the compat socket, the slirp4netns pin).
- CLAUDE.md: update the "Build and Run" and "Opt-in Docker-in-Docker"
  sections to mention `--pind` and the four-way mutual exclusion.
- Deprecated-alias table: no change (no old spelling for `--pind`).

## Out of scope (YAGNI)

- Refactoring dind and pind behind a unified `--nested=docker|podman`
  abstraction (Approach B). Revisit only after pind ships and the shared
  surface is proven.
- A combined single-image build carrying both engines (Approach C, rejected).
- Auto-matching the nested engine to the host runtime. `--pind` is an
  explicit opt-in, orthogonal to `DEV_RUNTIME`.
- pasta as the default network backend (kept as documented contingency only).

## Success criteria

1. `./dev --pind` starts a `dev-<dir>-pind` container with a working rootless
   podman and a `DOCKER_HOST` compat socket.
2. `podman pull` of an allowlisted registry succeeds; a pull of a
   non-allowlisted host is blocked by the proxy.
3. A nested `podman build` whose RUN steps fetch from allowlisted hosts
   succeeds; direct egress from a nested container to a non-allowlisted host
   is DROPped.
4. `verify-firewall.sh` checks 8–12 and `verify-pind.sh` pass under
   `DEVCONTAINER_PIND=1`.
5. `--pind` is mutually exclusive with `--dind` and `--maintenance`.
6. The existing `--dind` mode is behaviorally unchanged.
