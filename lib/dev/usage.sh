# shellcheck shell=bash
# lib/dev/usage.sh — the `dev --help` text.
# Sourced by dev; not executed directly.

usage() {
  cat <<EOF
Usage: dev <verb> [options]

Run or attach to the generic devcontainer.

VERBS:
  up              Build image if needed, start the container, attach a shell.
                  --dind | --pind | --maint   Container mode (mutually
                                               exclusive).
                  --open           Start with egress open: no proxy, no
                                   allowlist, unfiltered outbound traffic
                                   (default; ignored in --maint, which never
                                   runs the firewall). See DEV_EGRESS below.
                  --closed         Start with egress closed: tinyproxy +
                                   hostname allowlist, default-deny iptables.
                  --build          Force rebuild the image.
                  --dry-run        Print the run command without executing.
                  --port PORT      Add additional port forwarding (repeatable).
                  --default-ports  Forward the default dev ports (5173,
                                   5174, 8080, 2345, 3000). Off by default.
                  --host-port PORT Allow egress from the container to
                                   host.docker.internal:PORT (repeatable),
                                   without disabling the firewall.
  shell           Attach another shell to the running container. Takes no
                  options; errors if nothing is running for this workspace.
  exec            Run one command inside (starts the container if needed):
                    dev exec [up-options] -- CMD [ARGS...]
  down            Stop this workspace's container(s). Takes no options.
  status          Show what is running for this workspace, its mode, and
                  firewall state. Takes no options.
  ls              List every dev container and devcontainer-* volume on
                  this machine, not just this workspace's. Read-only;
                  '*' marks rows belonging to the current directory.
                  Also spelled 'dev list'.
                  --sizes          Add a SIZE column for volumes, read
                                   from 'system df -v' ('?' when the
                                   engine does not report one).
  doctor          Check this host for everything dev needs and print a
                  report with fixes. Works before anything is set up.
                  Options: --dind / --pind (also require nested-mode
                  prerequisites). Exits 1 if anything blocking fails.
  fw open         Toggle egress open on the running workspace container
                  (normal, dind, or pind) in place: flush OUTPUT rules + ACCEPT
                  policy, and switch tinyproxy to an allow-all filter
                  (SIGHUP reload). Errors if nothing is running — use
                  'dev up --open' to start a fresh container with egress
                  already open.
  fw close        Re-run firewall-init.sh on the running workspace container
                  to rebuild the allowlist filter and restore the
                  default-deny iptables policy.
  fw log          Tail the running workspace container's egress log: in
                  closed mode, the tinyproxy log (/var/log/tinyproxy.log,
                  hostname-level); in open mode, tcpdump on the DNS port plus
                  the FW-CONN NFLOG group (connection tuples only — no
                  URLs/headers without a proxy). Does not start one.
  fw drops        Stream packets dropped by iptables in the running workspace
                  container (tcpdump on NFLOG group 1). Does not start one.
  agent add NAME  Copy a curated set of an agent's credentials + settings
                  (claude|opencode|pi, or 'all') from the host into this
                  workspace's home volume. One-way snapshot — never a host
                  mount, never baked into an image. Re-run to refresh.
                  --dry-run        Preview the file list without copying.
                  --dind|--pind    Target a dind/pind container's storage
                                   (required on macOS+podman).
  agent list      Show, per agent, whether it is present on the host and
                  whether it has been injected into this workspace.
  agent rm NAME   Remove an agent's injected files from this workspace's
                  home volume (confirms; DEV_ASSUME_YES=1 skips the prompt).
  dotfile add PATH  Copy an arbitrary host file/dir into this workspace's home
                  volume, mirroring its path under \$HOME (e.g. ~/.config/nvim).
                  Symlinks are dereferenced. One-way snapshot, same as 'agent'.
                  --secret         chmod 600 the copied paths (tokens/keys).
                  --dind|--pind    Target a dind/pind container's storage
                                   (auto-detected from a running container).
  dotfile rm PATH   Remove a previously copied path from the home volume
                  (confirms; DEV_ASSUME_YES=1 skips the prompt).
  reset           Remove the dev container(s) for the current workspace
                  (normal, dind, and maintenance variants if present)
                  and prompt individually for each existing named
                  volume (devcontainer-mise, the workspace home volume
                  [devcontainer-home-<dir>, or devcontainer-home under
                  DEV_SHARED_HOME=1], devcontainer-dind). Does not
                  rebuild the image. Takes no options.
  update          Update the dev script's git checkout to the latest
                  released tag (the same source used by install.sh).
                  Requires SCRIPT_DIR to be a clean git checkout. The
                  image will prompt for a rebuild on the next 'dev' run
                  via the existing version-mismatch check.
                  --dry-run        Show what update would do.
  install         Symlink this script into a writable directory on PATH

  --help          Show this help message
  --version       Print the dev script version and exit

ENVIRONMENT:
  DEV_EGRESS=open|closed
                     Default egress mode for 'dev up'/'dev exec' when neither
                     --open nor --closed is given (default: open). An
                     explicit --open/--closed flag always wins over this. Any
                     other value is an error (exit 2). Ignored in --maint,
                     which never runs the firewall.
  DEV_RUNTIME=docker|podman
                     Force a runtime when both are installed. Default:
                     docker preferred on Linux; podman only on macOS.
  DEV_ASSUME_YES=1   Answer yes to the rebuild prompts triggered by a
                     UID/GID label mismatch or a dev-script version
                     mismatch (image's dev.version label vs the running
                     script's --version). Used by tests. Also
                     auto-approves .devcontainer-allowlist changes
                     without the interactive diff/prompt, so setting it
                     globally waives that review.
  DEV_SKIP_APPARMOR_CHECK=1
                     Bypass the --dind AppArmor preflight (only safe with
                     a custom profile that grants 'userns,').
  DEV_SKIP_SUBID_CHECK=1
                     Bypass the --dind preflight that requires a rootless
                     runtime host to grant at least 165535 subuids/subgids
                     (rootless dockerd must map the image's vscode subuid
                     range inside the container's user namespace).
  DEV_EXTRA_RUN_ARGS=...
                     Extra args appended to the runtime 'run' invocation
                     (e.g. --dns=8.8.8.8 on a host with broken IPv6
                     resolvers).
  DEV_SHARED_HOME=1  Use the legacy shared home volume (devcontainer-home) for
                     every workspace instead of the per-workspace default
                     (devcontainer-home-<dir>).
  GITHUB_TOKEN       If set on the host, injected into the container as an env
                     var (and forwarded to image builds as a BuildKit secret)
                     so 'mise install' can hit the GitHub API authenticated,
                     avoiding the 60/hr anonymous limit. A no-permission
                     fine-grained PAT is enough. Scope-guarded: a classic token
                     carrying OAuth scopes prompts [y/N] before it is handed to
                     the agent (DEV_ASSUME_YES=1 auto-approves; a non-TTY or
                     --dry-run run starts WITHOUT it).
  DEV_GITHUB_TOKEN   Explicit opt-in: injected as GITHUB_TOKEN with no scope
                     check and no prompt, taking precedence over an ambient
                     GITHUB_TOKEN. Use this to hand the agent a broader-scoped
                     token deliberately.

EXAMPLES:
  dev up                         # Start or attach to container with default shell
  dev up --build                 # Rebuild image and start container
  dev up --dry-run                # Show run command without running
  dev up --port 9000 --port 9001  # Add custom port forwarding
  dev up --default-ports          # Forward the default dev ports
  dev up --host-port 8080         # Reach host service at host.docker.internal:8080
  dev up --maint                  # Start in maintenance mode (no firewall, sudo enabled)
  dev up --dind                   # Start with rootless docker available inside
  dev up --open                   # Start fresh with egress open (the default)
  dev up --closed                 # Start fresh with egress closed (proxy + allowlist)
  dev exec -- npm run dev         # Run a custom command in the container
  dev shell                       # Attach another shell to the running container
  dev down                        # Stop this workspace's container(s)
  dev status                      # Show what is running, its firewall state, and egress mode
  dev ls                          # Inventory every dev container + volume on this machine
  dev ls --sizes                  # ...with volume disk usage
  dev fw log                      # Tail egress log of the running container (mode-aware)
  dev fw drops                    # Stream iptables-dropped packets of running container
  dev fw open                     # Toggle egress open on the running container
  dev fw close                    # Restore egress closed on the running container
  dev reset                       # Remove containers + prompt per volume
  dev update                      # Update the checkout to the latest tag
  dev update --dry-run            # Show what update would do
  dev install                     # Install 'dev' onto your PATH

EOF
}
