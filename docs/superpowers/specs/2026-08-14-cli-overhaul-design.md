# dev CLI overhaul + codebase simplification — design

Date: 2026-08-14
Status: approved in discussion; pending spec review
Scope: workstreams 1+2 of the org-rollout roadmap (simplify for human
review, streamline the CLI). Precedes the VM hardening/testing matrix
(workstream 3).

## Goals

1. The security-critical parts are reviewable by a colleague in one sitting.
2. The CLI is discoverable and recognizable for org newcomers (compose-style
   verbs), with exactly one spelling per action.
3. Clean break: no deprecated aliases, no back-compat layer. Ships as a major
   release.

Threat model reminder (drives review priorities): the sandbox protects
against an agent **finding and using host keys/secrets by accident or in
misguided loyalty** — containment of agent reach, not exfiltration
prevention. Host isolation boundaries and the egress firewall are the
review-critical surface; CLI convenience code is not.

## Decisions (made during brainstorming)

- **Compose-style verbs**, no bare-`dev` shortcut (bare `dev` prints usage).
- **Stay bash** (zero-dependency portability, macOS bash 3.2 compatible);
  reviewability comes from structure, not a language change.
- **Prune**: delete `scaffold` and all deprecated `--flag` aliases. Keep
  `dotfile`, `DEV_SHARED_HOME=1`, `--host-port`.
- **Incremental in place**: 4 PRs, e2e scenario suite green after each.

## 1. Command surface (final)

```
dev up [--dind|--pind|--maint] [--open] [--host-port P]... [--build] [--dry-run]
dev shell                 # attach another shell to the running container
dev exec [--dind|--pind|--maint] -- CMD [ARGS...]
dev down                  # stop this workspace's container(s)
dev status                # what's running, which mode, firewall state
dev fw off|on|log|drops
dev agent add|list|rm [NAME]
dev dotfile add|rm PATH [--secret]
dev reset                 # remove containers + prompt per named volume
dev update                # git-checkout self-update to latest release tag
dev install               # symlink dev onto PATH (install.sh hands off here)
```

- `up` = build image if needed, create-or-start container, attach an
  interactive shell. Mode/lifecycle options exist on `up` (and `exec`, see
  below) only.
- `exec` **auto-starts** the container when none is running — a deliberate
  divergence from `docker exec`. Rationale: "run one command in the sandbox"
  is the gesture agents and CI scripts use; it must have exactly one
  spelling and must not depend on prior state. `exec` therefore accepts the
  same mode flags as `up` for the cold-start case; if the running container's
  mode conflicts with the requested mode, the four-way conflict guard errors.
- `shell` requires a running container (one-line actionable error otherwise).
- `fw off|on` renames `fw disable|enable`. `--open` on `up` replaces the
  "fw disable with no container running starts one open" dual behaviour —
  `fw off|on` then only ever acts on a running container (single
  responsibility; the cold-start-open path has its own spelling).
- Bare `dev`, unknown verbs, and `-h/--help` print usage. `--version` stays.
- Env vars unchanged: `DEV_RUNTIME`, `DEV_ASSUME_YES`, `DEV_SHARED_HOME`,
  `DEV_SKIP_APPARMOR_CHECK`, `DEV_SKIP_SUBID_CHECK`, `DEV_EXTRA_RUN_ARGS`.
- Deleted: `scaffold`, every deprecated alias (`--disable-firewall`,
  `--enable-firewall`, `--monitor`, `--monitor-fw`, `--reset`,
  `--self-update`, `--create-dev-container`), and the alias-rerouting layer.

## 2. File layout

```
dev                      # dispatcher only, target ≤ ~150 lines:
                         #   resolve script dir, source lib, parse global
                         #   flags, dispatch verb, usage/version
lib/dev/
  up.sh  exec.sh  shell.sh  down.sh  status.sh   # one module per verb
  fw.sh  agent.sh  dotfile.sh  reset.sh  update.sh
  runtime.sh             # runtime pick, rootless detection, keep-id logic
  container.sh           # names, labels, reuse/attach, 4-way conflict guard
  volumes.sh             # home/mise/dind/pind volumes, chown migration
  image.sh               # build, version-label check
  preflight.sh           # apparmor/subid/kvm checks
```

Soft budget: no module over ~250 lines — exceeding it is a smell to split
or prune, not a hard gate. `up` and `exec` share the create-or-start path in
`container.sh`; verbs never duplicate lifecycle logic.

## 3. Security-core reviewability

Review-critical set (enforces the boundary): `Dockerfile`, `entrypoint.sh`,
`firewall-init.sh`, `firewall-disable.sh`, `allowlist.base`,
`allowlist.dind`. Rules for this work:

- **No new features** in these files during the restructure (the recent
  fix-pack — IPv6 parity, no-aaaa, dc-tinyproxy, exec env, JVM proxy
  seeding — is already in).
- Each gets a short threat-model header: what the file may do, what it must
  never do (e.g. firewall-init: "reads only baked/approved allowlists, never
  /workspace"; entrypoint: "may seed, never overwrite, user files").
- New `SECURITY.md`: reviewer's guide — threat model, reading order
  (Dockerfile → entrypoint → firewall-init → allowlists → dev's exec/mount
  surface), what to look for, explicit non-goals (exfiltration prevention via
  allowlisted hosts, protection from a malicious *image*, etc.).
- The CLI never re-implements enforcement: `dev fw` execs the in-container
  scripts; `dev up` passes env/mounts but contains no firewall logic.

## 4. Migration plan (4 PRs, suite green after each)

1. **PR1 — dispatcher + verb skeleton.** New verb dispatch in `dev`; verbs
   delegate to existing internals. Old spellings keep working unchanged
   (internal delegation, no user-facing deprecation layer added).
2. **PR2 — migrate callers.** All ~40 `scripts/test/scenarios/*.sh`, the
   verify scripts' docs, README examples, and CLAUDE.md move to verb
   spellings.
3. **PR3 — the clean break.** Delete old flag parsing, deprecated aliases,
   `scaffold` (module, docs, scenario 45), and dead code. Major-version
   release-please commit (`feat!:`).
4. **PR4 — final layout.** Split/rename modules to the target layout, add
   SECURITY.md and threat-model headers, rewrite README/CLAUDE.md
   structure. Line budgets checked here.

Testing per PR: `shellcheck` + `hadolint` clean; full
`sudo bash scripts/test/run-all.sh` matrix on the Linux host; scenario
additions where behaviour changed (`exec` auto-start; `fw off` no longer
cold-starts; `up --open` does).

## 5. Error handling

- Four-way mode-conflict guard (normal/maint/dind/pind) lives in
  `container.sh`; every container-touching verb goes through it.
- `shell`/`down`/`status` with nothing running: one-line error naming the
  fix (`nothing running for this workspace — 'dev up' starts one`); exit 1.
  `status` prints state rather than erroring when *something* exists.
- `up` keeps fail-closed startup: firewall-init failure refuses the
  container.
- Unknown verb/flag: usage to stderr, exit 2.

## Out of scope

- Any firewall/entrypoint behaviour change (done separately in the
  fix-pack; further hardening belongs to workstream 3).
- The VM test matrix (workstream 3, own design).
- New features of any kind (YAGNI; the goal is a smaller, reviewable tool).
