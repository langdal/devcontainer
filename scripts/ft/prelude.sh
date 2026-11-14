#!/usr/bin/env bash
# scripts/ft/prelude.sh — prepended to every scripts/ft/inner-*.sh by
# _ft_exec_script (cat prelude script | bash -s). Shared container-side
# helpers; defines functions only, decides nothing by itself.

# True when a herdr server answers on the local socket. Exit codes are not
# trustworthy here — a status-style query can exit 0 while reporting that no
# server runs — so probe with a command that needs the server and read the
# reply: the documented error signature wins over the exit code.
ft_server_up() {
  _ft_out=$(herdr tab list 2>&1)
  _ft_rc=$?
  case "$_ft_out" in
    *server_not_running*) return 1 ;;
  esac
  [ "$_ft_rc" -eq 0 ]
}

# herdr's CLI talks to a local server socket; a fresh container has no server
# until something starts one. `herdr server` runs it headless (documented for
# supervised setups) and then persists for the container's lifetime — tabs
# and agents live in it. stdin must be /dev/null: this prelude itself arrives
# over the script's stdin pipe, and a backgrounded child sharing that pipe
# could consume the rest of the script.
ft_ensure_server() {
  command -v herdr >/dev/null 2>&1 || {
    echo "ft: herdr is not in this container — run 'dev ft sync' on the host first." >&2
    return 1
  }
  ft_server_up && return 0
  # The server spawns agent binaries itself (no shell), inheriting the PATH it
  # was started with — the exec'd image environment, which lacks ~/.local/bin,
  # where user-installed agents (and ft sync's herdr symlink) live. Prefix it.
  PATH="$HOME/.local/bin:$PATH" nohup herdr server </dev/null >"$HOME/.herdr-server.log" 2>&1 &
  _ft_i=0
  while [ "$_ft_i" -lt 30 ]; do
    ft_server_up && return 0
    sleep 1
    _ft_i=$((_ft_i + 1))
  done
  echo "ft: could not start the herdr server. Tail of ~/.herdr-server.log:" >&2
  tail -n 20 "$HOME/.herdr-server.log" >&2 2>/dev/null || true
  echo "ft: try 'herdr server' inside 'dev shell' to see why." >&2
  return 1
}
