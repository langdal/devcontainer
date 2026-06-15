# TODO.box.md — deferred scope and known limitations

## Deferred slices (from the spec)

- **Allowlist modes polish / ergonomics** (spec slice 4) — better error messages
  for unknown hosts, possibly a `box allowlist add` helper, and per-project
  default-mode override.
- **`box install`** (spec slice 5) — alias the run flow under the agent's own
  name via `msb install`, so `claude` (or any agent binary) starts its own box
  directly.
- **Snapshot-based provisioning optimization** — provision once, snapshot, boot
  subsequent runs from the snapshot instead of re-running `mise install`. Named
  volumes already carry the state; snapshots would reduce cold-start time.
- **macOS (Apple Silicon) validation** — `box` is written to be portable, but
  has only been exercised on Linux/KVM. Needs a real Apple Silicon host run.
- **Docker-in-microVM** — IMPLEMENTED as `box --docker` (disk-backed
  `/var/lib/docker`, memory bump, dockerd boot entrypoint, `allowlist.dind`
  merge; sample `Dockerfile.box.docker`). Still needs **live validation** on a
  real VM (build a docker image, `box --docker`, confirm `docker run hello-world`
  and that pulls honor the allowlist). The dockerd boot script (`exec sleep
  infinity` keepalive, 60s readiness wait) is unverified end-to-end.
- **Remove the legacy stack** — once this prototype is accepted, remove
  `Dockerfile`, `entrypoint.sh`, `dev`, `firewall-init.sh`, `firewall-disable.sh`,
  `tinyproxy.conf`, `allowlist.base`, and the `--maintenance` / `--dind` /
  `--monitor` / `--monitor-fw` / `--disable-firewall` / `--enable-firewall`
  flags from `dev`. The `box` stack fully replaces them.

## Known limitations

- **Agent runs as root inside the guest.** `msb exec` runs as root; this is
  necessary because the `/workspace` bind mount is owned by guest-root (the
  host user maps to guest-root inside the VM), and a non-root guest user cannot
  write to it. The microVM itself is the isolation boundary, but in-guest root
  is a hardening gap to revisit — ideally the guest user would be unprivileged
  once microsandbox supports a configurable UID mapping.

- **`mise.base.toml` is unused.** `box provision` runs `mise install` against
  the project's `mise.toml` only — the baked-tools list in `mise.base.toml`
  (node, ripgrep, eza, lazygit, neovim) is not wired in. Either pass
  `mise.base.toml` explicitly to the provision script or remove it; as-is the
  base tools are not available inside the sandbox.

- **Cosmetic mise version-check warnings.** On every `mise` invocation the
  guest emits ~3 `mise WARN HTTP GET https://mise.en.dev/VERSION ... failed`
  lines on stderr. This is mise's self-update check hitting a host that is
  correctly not on the allowlist. Tool resolution and exit codes are unaffected.
  `MISE_VERSION_CHECK`, `MISE_NO_VERSION_CHECK`, and `MISE_CHECK_FOR_UPDATES`
  were all tried and did not suppress it on mise 2026.6.10. Revisit if the
  noise becomes a problem.

- **Provisioned marker can go stale.** The host-side marker file
  (`~/.local/state/box/<name>.provisioned`) records that provision has run.
  If the `box-mise` or `box-home` named volumes are removed outside `box reset`
  (e.g. via `msb volume rm` directly), the marker stays behind and `box` skips
  re-provisioning, leaving an empty volume. Run `box reset` then `box provision`
  to recover, or delete the marker manually.

- **Validated on Linux nested-KVM with msb 0.5.7 only.** microsandbox is beta;
  CLI syntax or behaviour may change in future releases. All `msb` invocations
  are in `lib/msb.sh` to contain the blast radius.
- `--net` is only honored before a subcommand; `box shell --net full` silently falls back to the default `sanctioned` mode (flags-first contract; a guard should reject misplaced flags).
