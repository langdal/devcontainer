# E2E validation: baked socat + reaching host services (`--host-port`)

**Date:** 2026-06-15 · **Host:** Linux 6.8 nested-KVM, `msb` 0.5.7

## Baked socat (default base image)

`box` now auto-builds a default base `box-base:local` (devcontainers base +
socat) from the bundled `Dockerfile.box.base`, the same on-demand way as the
docker base. Verified live: `box -- bash -lc 'command -v socat'` →
`/usr/bin/socat`. If no host docker/podman is available, box falls back to the
plain pulled devcontainers image and warns that socat isn't baked in.

## Reaching a host service from the guest (`--host-port`)

Use case: an agent inside the sandbox calling a local LLM (e.g. ollama) running
on the host.

**Mechanism.** microsandbox denies host/private access by default. `box
--host-port PORT` adds an `allow@host:tcp:PORT` egress rule (the `host` rule
target = the host machine). The guest reaches the host via the gateway.

**The IPv4/IPv6 gotcha (and fix).** microsandbox's own
`host.microsandbox.internal` resolves to an IPv6 ULA (e.g. `fd42:…::1`) as well
as the IPv4 gateway. A host service bound to IPv4 only (ollama defaults to
`127.0.0.1:11434`, plain `python -m http.server`, etc.) is unreachable over the
IPv6 address, and curl/clients that try IPv6 first fail with a recv error.

Live findings:
- by **IPv4 gateway** (`http://<gw>:11434`) → works (`hello-from-host`).
- by `host.microsandbox.internal` (default, IPv6-first) → fails (recv error 56).
- `curl -4 host.microsandbox.internal` → works.

**Fix in box.** On cold boot in `--host-port` mode, box injects an IPv4-only
`host.docker.internal` entry into the guest's `/etc/hosts` (pointed at the
default gateway). It has no competing AAAA record, so name resolution is IPv4
and matches typical host services — and it mirrors the old `dev`'s
`host.docker.internal`. Agents point at `host.docker.internal:PORT`.

**Integrated result.** With a host HTTP server on `:11434`:
```
$ box --host-port 11434 -- bash -lc 'curl -s http://host.docker.internal:11434/ping.txt'
box: host reachable at host.docker.internal:<port> (allowed ports: 11434)
hello-from-host          # request confirmed in the host server log
```

### For ollama specifically
Run ollama on the host, then inside the sandbox point the agent framework at
`http://host.docker.internal:11434`:
```
box --host-port 11434
# inside: OLLAMA_HOST=http://host.docker.internal:11434  (or the framework's base-url setting)
```
Note: ollama binds `127.0.0.1` by default; that's fine — the host.docker.internal
alias resolves to the IPv4 gateway and the `allow@host` rule permits it. (If you
ever switch to the IPv6 `host.microsandbox.internal` name, bind ollama dual-stack
or use an IPv4 client.)

## Implementation (all msb specifics in lib/msb.sh)

- `msb_net_args` (sanctioned) appends `allow@host:tcp:<port>` for each
  `BOX_HOST_PORTS` entry (CSV).
- `msb_host_alias NAME`: idempotently writes `<gateway> host.docker.internal`
  into the guest `/etc/hosts` (root exec).
- `box`: `--host-port PORT` (repeatable, numeric) → `BOX_HOST_PORTS`; on cold
  boot it calls `msb_host_alias` and prints the reachable address.

## Limitations
- Validated on Linux nested-KVM, msb 0.5.7. macOS unverified.
- The gateway IP is per-boot; the `host.docker.internal` alias is re-derived on
  each cold boot, so this is transparent to the user.
