# Optional mesh image: workspace-base + the Tailscale client.
# Works with both Tailscale (SaaS) and Headscale (self-hosted) — the only
# difference is the --login-server URL, handled by mesh-up at runtime.
# Build: just build-mesh   (after: just build-base)
FROM workspace-base:latest

ARG TS_VERSION=1.98.3

USER root

# iproute2 helps tailscaled manage routes in kernel mode. iptables is already
# in the base image (used by the egress firewall / mesh containment).
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" \
       | tar -xz --strip-components=1 -C /usr/local/bin \
           "tailscale_${TS_VERSION}_amd64/tailscale" \
           "tailscale_${TS_VERSION}_amd64/tailscaled"

COPY mesh/mesh-up.sh /usr/local/bin/mesh-up
COPY mesh/mesh-firewall.sh /usr/local/bin/mesh-firewall
RUN chmod +x /usr/local/bin/mesh-up /usr/local/bin/mesh-firewall

USER vscode
