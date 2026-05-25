#!/usr/bin/env bash
# Opt-in egress allowlist. Requires --cap-add=NET_ADMIN. Default-deny outbound,
# allow DNS + loopback + an allowlist of hosts. Reads extra hosts (one per line)
# from ALLOWLIST_FILE if set (default /etc/workspace-allowlist).
set -euo pipefail

ALLOWLIST_FILE="${ALLOWLIST_FILE:-/etc/workspace-allowlist}"
DEFAULT_HOSTS=(registry.npmjs.org pypi.org files.pythonhosted.org github.com api.github.com codeload.github.com objects.githubusercontent.com)

command -v iptables >/dev/null || { echo "iptables missing; install in image or skip firewall" >&2; exit 1; }

iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
  # DNS to any resolver (Docker's embedded resolver is dynamic; pinning is
  # fragile). Note: this leaves a theoretical DNS-tunnel exfil channel open.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT      # DNS
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# IPv6: default-deny. Allowlist hosts are resolved as IPv4 only, so no v6
# allow-rules are added — this prevents IPv6 egress from bypassing the allowlist.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F OUTPUT
  ip6tables -P OUTPUT DROP
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
  ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
fi

hosts=("${DEFAULT_HOSTS[@]}")
if [ -f "$ALLOWLIST_FILE" ]; then
  while IFS= read -r h; do
    [[ "$h" =~ ^[[:space:]]*# ]] && continue   # skip comments
    [ -n "$h" ] && hosts+=("$h")
  done < "$ALLOWLIST_FILE"
fi

for h in "${hosts[@]}"; do
  mapfile -t ips < <(getent ahostsv4 "$h" | awk '{print $1}' | sort -u)
  if [ "${#ips[@]}" -eq 0 ]; then
    echo "firewall: WARNING: no IPs resolved for $h — it will be blocked" >&2
    continue
  fi
  for ip in "${ips[@]}"; do
    iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ip" --dport 80 -j ACCEPT
  done
done
echo "firewall: egress locked to ${#hosts[@]} allowed host(s)"
