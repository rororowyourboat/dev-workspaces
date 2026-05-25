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
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT      # DNS
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

hosts=("${DEFAULT_HOSTS[@]}")
[ -f "$ALLOWLIST_FILE" ] && while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done < "$ALLOWLIST_FILE"

for h in "${hosts[@]}"; do
  for ip in $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u); do
    iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ip" --dport 80 -j ACCEPT
  done
done
echo "firewall: egress locked to ${#hosts[@]} allowed host(s)"
