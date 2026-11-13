#!/usr/bin/env bash
# scripts/ft/inner-enable.sh — container side of `dev ft enable`. Generates
# the per-workspace ssh host key + minimal sshd_config in the home volume
# (fingerprint survives rebuilds; `dev reset` regenerates it) and authorizes
# the host user's public key, passed as $1. Starts nothing: the host-side
# ProxyCommand spawns `sshd -i` per connection, as vscode.
set -euo pipefail

pub=${1:-}
d="$HOME/.ssh"

command -v /usr/sbin/sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ] || {
  echo "ft enable: /usr/sbin/sshd is missing — rebuild the image ('dev up --build')." >&2; exit 1; }

mkdir -p "$d"
chmod 700 "$d"
[ -f "$d/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$d/host_ed25519"
chmod 600 "$d/host_ed25519"
printf 'HostKey %s/host_ed25519\nPasswordAuthentication no\nUsePAM no\n' "$d" > "$d/sshd_config"

if [ -n "$pub" ]; then
  touch "$d/authorized_keys"
  chmod 600 "$d/authorized_keys"
  grep -qxF "$pub" "$d/authorized_keys" || printf '%s\n' "$pub" >> "$d/authorized_keys"
fi
echo "ft enable: host key + sshd_config ready in $d"
