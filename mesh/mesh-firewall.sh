#!/usr/bin/env bash
# OPTIONAL egress containment for a mesh workspace: deny ALL outbound except
# loopback, DNS, and the mesh itself. After this runs, the workspace can reach
# nothing on the internet except via the tailnet (and whatever your ACLs allow
# on the other side). Run as root AFTER `mesh-up`, with NET_ADMIN:
#
#   sudo -E mesh-firewall
#
# The tunnel still needs to reach its control plane + relays to stay up, so
# those hosts are permitted on TCP 443:
#   - Headscale: defaults to the host in TS_LOGIN_SERVER.
#   - Tailscale SaaS: controlplane.tailscale.com + log.tailscale.io are allowed,
#     but DERP relays (derpN.tailscale.com) are NOT enumerable by IP here — if
#     a direct (UDP 41641) path can't be established, relayed traffic may break.
#     Set TS_CONTROL_HOSTS to pin the relay/control hosts you rely on.
# Configurable:
#   TS_CONTROL_HOSTS  space/comma list of extra hosts to allow on TCP 443.
set -euo pipefail

command -v iptables >/dev/null || { echo "mesh-firewall: iptables missing" >&2; exit 1; }
ip link show tailscale0 >/dev/null 2>&1 || {
  echo "mesh-firewall: tailscale0 interface not found — run mesh-up first." >&2
  exit 1
}

# Build the list of control/relay hosts to permit during bring-up/keepalive.
hosts=()
if [ -n "${TS_LOGIN_SERVER:-}" ]; then
  # strip scheme + path + port → bare host
  h="${TS_LOGIN_SERVER#*://}"; h="${h%%/*}"; h="${h%%:*}"
  [ -n "$h" ] && hosts+=("$h")
else
  hosts+=(controlplane.tailscale.com log.tailscale.io)
fi
if [ -n "${TS_CONTROL_HOSTS:-}" ]; then
  for h in ${TS_CONTROL_HOSTS//,/ }; do [ -n "$h" ] && hosts+=("$h"); done
fi

apply() { # apply <iptables|ip6tables> <getent-family>
  local ipt="$1" fam="$2"
  command -v "$ipt" >/dev/null 2>&1 || return 0
  "$ipt" -F OUTPUT
  "$ipt" -P OUTPUT DROP
  "$ipt" -A OUTPUT -o lo -j ACCEPT
  "$ipt" -A OUTPUT -o tailscale0 -j ACCEPT          # all mesh traffic
  "$ipt" -A OUTPUT -p udp --dport 53 -j ACCEPT      # DNS
  "$ipt" -A OUTPUT -p tcp --dport 53 -j ACCEPT
  "$ipt" -A OUTPUT -p udp --dport 41641 -j ACCEPT   # tailscale direct
  "$ipt" -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  local h ip
  for h in "${hosts[@]}"; do
    for ip in $(getent "$fam" "$h" | awk '{print $1}' | sort -u); do
      "$ipt" -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
    done
  done
}

apply iptables  ahostsv4
apply ip6tables ahostsv6

echo "mesh-firewall: egress locked to mesh only (control hosts allowed: ${hosts[*]:-none})"
