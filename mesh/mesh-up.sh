#!/usr/bin/env bash
# Join a Tailscale (SaaS) or Headscale (self-hosted) mesh from inside a
# workspace. Run as root with the auth key in the environment, e.g.:
#
#   devcontainer exec --workspace-folder . \
#     --config .devcontainer/mesh/devcontainer.json \
#     --remote-env TS_AUTHKEY=tskey-... \
#     [--remote-env TS_LOGIN_SERVER=https://headscale.example] \
#     sudo -E mesh-up
#
# Required env:
#   TS_AUTHKEY        pre-auth key (use an EPHEMERAL, tagged key — see README)
# Optional env:
#   TS_LOGIN_SERVER   Headscale URL. Omit to use Tailscale's SaaS control plane.
#   TS_HOSTNAME       node name on the mesh (default: container hostname)
#   TS_TAGS           comma list for --advertise-tags, e.g. "tag:ws"
#   TS_ACCEPT_ROUTES  "1" to accept subnet routes from other nodes
#   TS_EXIT_NODE      ip/name of an exit node to route through
#   TS_USERSPACE      "1" for userspace networking (no /dev/net/tun / NET_ADMIN);
#                     apps must then use the SOCKS5/HTTP proxy on localhost:1055
#   TS_EXTRA_ARGS     extra args appended verbatim to `tailscale up`
set -euo pipefail

[ -n "${TS_AUTHKEY:-}" ] || { echo "mesh-up: TS_AUTHKEY is required" >&2; exit 1; }

state_dir=/var/lib/tailscale
sock=/var/run/tailscale/tailscaled.sock
mkdir -p "$state_dir" /var/run/tailscale /var/log

# Start tailscaled if its control socket isn't already present.
if [ ! -S "$sock" ]; then
  if [ "${TS_USERSPACE:-}" = "1" ]; then
    tailscaled --tun=userspace-networking \
      --socks5-server=localhost:1055 \
      --outbound-http-proxy-listen=localhost:1055 \
      --statedir="$state_dir" >/var/log/tailscaled.log 2>&1 &
  else
    [ -e /dev/net/tun ] || {
      echo "mesh-up: /dev/net/tun not present. Add \"--device=/dev/net/tun\" to" >&2
      echo "         runArgs (the mesh devcontainer does) or set TS_USERSPACE=1." >&2
      exit 1
    }
    tailscaled --state="$state_dir/tailscaled.state" \
      --socket="$sock" >/var/log/tailscaled.log 2>&1 &
  fi
  # Wait for the control socket to appear.
  for _ in $(seq 1 40); do [ -S "$sock" ] && break; sleep 0.25; done
  [ -S "$sock" ] || { echo "mesh-up: tailscaled did not start; see /var/log/tailscaled.log" >&2; exit 1; }
fi

args=(--authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-$(hostname)}")
[ -n "${TS_LOGIN_SERVER:-}" ] && args+=(--login-server="$TS_LOGIN_SERVER")
[ -n "${TS_TAGS:-}" ]         && args+=(--advertise-tags="$TS_TAGS")
[ "${TS_ACCEPT_ROUTES:-}" = "1" ] && args+=(--accept-routes)
[ -n "${TS_EXIT_NODE:-}" ]    && args+=(--exit-node="$TS_EXIT_NODE")
# shellcheck disable=SC2206  # intentional word-splitting for extra args
[ -n "${TS_EXTRA_ARGS:-}" ]   && args+=($TS_EXTRA_ARGS)

tailscale up "${args[@]}"
tailscale status || true
echo "mesh-up: joined as ${TS_HOSTNAME:-$(hostname)}${TS_LOGIN_SERVER:+ via $TS_LOGIN_SERVER}"
echo "mesh-up: to lock egress to the mesh only, run: sudo -E mesh-firewall"
