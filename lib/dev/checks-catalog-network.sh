# shellcheck shell=bash
# lib/dev/checks-catalog-network.sh — the host-network probe/fix pairs for the
# registry in lib/dev/checks.sh. Split from checks-catalog.sh, which sits at
# its 300-line lint budget (scripts/lint.sh); see checks.sh for the registry
# format and the run_check/checks_select machinery that dispatches here by
# name. Probes reach the host only through the indirections in
# lib/dev/runtime.sh (_default_route_mtu) so they are unit-testable anywhere.
# Sourced by dev; not executed directly.

# --- phase 0, advisory ----------------------------------------------------

# The recommended DEV_MTU for a given uplink MTU. The host value itself is
# NOT safe for forwarded traffic: on the 2026-09-07 FortiClient host the
# uplink was 1280, the host's own sockets were fine at 1280, and the
# container still lost every packet above ~1180 because the tunnel adds its
# own overhead on top. 200 is twice the measured gap; 576 is the IPv4
# minimum and the floor for a host that reports something absurd.
_mtu_recommend() {
  local rec=$(( $1 - 200 ))
  [[ "$rec" -lt 576 ]] && rec=576
  echo "$rec"
}

# A VPN client that lowers the host's default-route MTU below 1500 leaves the
# container bridge at 1500. Forwarded packets above the tunnel's real limit
# are dropped with no ICMP back (a PMTUD blackhole), so small requests work
# and anything with a large first packet -- a rustls ClientHello with a
# post-quantum key share, an upload -- hangs until timeout, only inside the
# container. Advisory, never blocking: the probe cannot know the tunnel's
# true overhead, and hosts behind a userspace network stack (podman machine,
# pasta) may be unaffected. DEV_MTU set means the user already acted: pass.
_chk_uplink_mtu() {
  [[ -n "${DEV_MTU:-}" ]] && return 0
  local mtu; mtu="$(_default_route_mtu)"
  case "$mtu" in ''|*[!0-9]*) return 2 ;; esac
  [[ "$mtu" -lt 1500 ]] && return 1
  return 0
}
_chk_uplink_mtu_fix() {
  local mtu rec
  mtu="$(_default_route_mtu)"
  rec="$(_mtu_recommend "$mtu")"
  echo "The default-route interface has MTU $mtu; the container bridge assumes"
  echo "1500. Typical cause: a VPN client (e.g. FortiClient). Host sockets adapt,"
  echo "but forwarded container packets above the tunnel's real limit are silently"
  echo "dropped: small requests work, large ones (TLS handshakes with a big"
  echo "ClientHello, uploads) hang until timeout inside the container. Set a"
  echo "conservative container MTU -- the host value itself is NOT safe, the"
  echo "tunnel adds overhead on top of it -- then recreate the container:"
  echo "    export DEV_MTU=$rec    # put it in your shell profile to make it stick"
  echo "    dev down && dev up"
}
