# E2E validation: `box --docker` (Docker inside the sandbox)

**Date:** 2026-06-15 · **Host:** Linux 6.8 nested-KVM, `msb` 0.5.7

Live validation of in-sandbox Docker. The first design (a `--script`/`--entrypoint`
that launched dockerd as PID 1) was found broken and replaced with a systemd
(`--init auto`) approach, then validated end-to-end.

## What broke in the first design (and why)

- **`--entrypoint boxdockerd` wedged `msb exec`.** With the entrypoint overridden,
  the VM booted (`msb ps` showed it running) but *every* `msb exec` — even
  `echo` — hung indefinitely (this was the observed "9 minute" hang). Root cause:
  overriding the entrypoint replaces the guest init/agent relay that `msb exec`
  depends on. Confirmed by booting the same image **without** `--entrypoint`:
  `msb exec … echo` returned instantly.
- **You cannot start a persistent daemon via `msb exec` either.** Launching
  `dockerd` with `setsid …  &` from inside an exec also hung — `msb exec` waits
  on the session's process group, so a long-lived child never lets it return.

Conclusion: a long-lived daemon must be started by a real init, not by
`--entrypoint` or `msb exec`.

## The working design: systemd via `--init auto`

`msb run --init auto` hands PID 1 to systemd; `msb exec` keeps working. The
packaged `docker.service` then starts `dockerd`. Validated steps (raw `msb`):

1. **systemd boots + exec works.** `msb run -d --init auto --cpus 2 --memory 2G
   --mount-named box-docker:/var/lib/docker:kind=disk,size=20G <img>` →
   `msb exec … echo` returns; `systemctl is-active docker` → `active`.
2. **dockerd healthy.** `docker info` →
   `Server Version: 29.1.3`, `Cgroup Driver: systemd`, `Cgroup Version: 2`.
3. **overlay2 required.** With docker 29's default **containerd** image store,
   `docker run` failed: `mount … fstype: overlay … err: invalid argument` — its
   snapshots live at `/var/lib/containerd` on the VM's erofs/overlay rootfs,
   where overlay mounts are invalid. Forcing the classic **overlay2** driver via
   `/etc/docker/daemon.json` (`containerd-snapshotter: false`, `storage-driver:
   overlay2`) moves the store to `/var/lib/docker` — the disk-backed ext4 volume —
   and `docker run --rm hello-world` → **`Hello from Docker!`**; `docker build`
   also succeeds.
4. **Egress allowlist binds nested pulls.** Under `--net-default-egress deny` +
   the registry allowlist, `docker pull` reached `registry-1.docker.io`. With an
   intentionally incomplete rule the config blob from
   `production.cloudfront.docker.com` was **DNS-blocked** (`no such host`) —
   proving nested-container traffic is subject to the host egress policy. With
   the full `allowlist.dind` set (cloudflare + cloudfront + `*.cloudfront.net` +
   `*.r2.cloudflarestorage.com` + `*.docker.io`), pulls complete.
5. **Cold-boot readiness.** `docker.service` becomes active well after
   `msb run -d` returns (the agent relay comes up before systemd finishes), so
   `box` must wait for `docker info` before running the user's command.

## Integrated `box --docker` run (the real path)

```
$ box build                 # systemd+docker image → msb image load → .box-image   (~33s)
$ box --docker -- bash -lc 'docker run --rm hello-world'
box: first run for box-box-dind-e2e; provisioning (open egress)...
mise all tools are installed
box: waiting for dockerd to start inside the sandbox...
Hello from Docker!          # ~15s total (provision + systemd boot + dockerd wait + pull)
```

## Implementation (all microsandbox specifics in lib/msb.sh)

- `msb_docker_args`: `--init auto --cpus 2 --memory 2G --mount-named
  box-docker:/var/lib/docker:kind=disk,size=20G` (tunable via `BOX_DOCKER_CPUS`,
  `BOX_DOCKER_MEMORY`, `BOX_DOCKER_SIZE`). No entrypoint override.
- `msb_docker_wait`: polls `docker info` (≤120s) after a cold `msb_up`.
- `box`: `--docker` flag / `.box-docker` marker → `BOX_DOCKER=1`; merges
  `allowlist.dind`; waits for dockerd on cold boot.
- `Dockerfile.box.docker`: `systemd systemd-sysv docker.io …`, `systemctl enable
  docker`, and the overlay2 `daemon.json`.

## Notes / limitations

- Validated on Linux nested-KVM, msb 0.5.7, with the devcontainers-base + docker
  image. macOS unverified.
- dockerd logs a benign `nft: executable file not found` warning (docker.io uses
  iptables; nftables tooling absent) — networking still works.
- The docker image is large; `box build` + first boot take longer than the plain
  base. Subsequent boots reuse the cached image and the `box-docker` volume.
