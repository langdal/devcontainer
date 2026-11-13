#!/usr/bin/env bash
# scripts/ft/prelude.sh — prepended to every scripts/ft/inner-*.sh by
# _ft_exec_script (cat prelude script | bash -s). Shared container-side
# helpers; defines functions only, decides nothing by itself.

# herdr's CLI talks to a local server socket; a fresh container has no server
# until something starts one. `herdr server` runs it headless (documented for
# supervised setups), and it then persists for the container's lifetime —
# agents and tabs live in it.
ft_ensure_server() {
  command -v herdr >/dev/null 2>&1 || {
    echo "ft: herdr is not in this container — run 'dev ft sync' on the host first." >&2
    return 1
  }
  herdr status server >/dev/null 2>&1 && return 0
  nohup herdr server >/dev/null 2>&1 &
  _ft_i=0
  while [ "$_ft_i" -lt 30 ]; do
    herdr status server >/dev/null 2>&1 && return 0
    sleep 1
    _ft_i=$((_ft_i + 1))
  done
  echo "ft: could not start the herdr server — try 'herdr server' inside 'dev shell' to see why." >&2
  return 1
}
