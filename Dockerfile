# syntax=docker/dockerfile:1
# ──────────────────────────────────────────────────────────────────────────────
# ExpressVPN Docker Gateway
# Replaces gluetun as a VPN sidecar for arr-stack containers.
# Uses ExpressVPN's Lightway protocol for maximum throughput.
# ──────────────────────────────────────────────────────────────────────────────

# Build-arg: pin a specific ExpressVPN v4 release
# ⚠️ v3.x certificates expire March 31, 2026 — v4+ required.
# Override at build time: docker build --build-arg APP_VERSION=4.0.2 .
ARG APP_VERSION=4.0.1

# ── Stage 1: Local installer prep ──────────────────────────────────────────────
# We now use a locally downloaded installer file instead of fetching from the web
# Place the downloaded .run file from ExpressVPN into the `releases/` directory
# and name it `expressvpn.run`.
FROM debian:bookworm-slim AS downloader

COPY releases/expressvpn.run /tmp/expressvpn.run
RUN chmod +x /tmp/expressvpn.run
# ── Stage 2: Final runtime image ───────────────────────────────────────────────

LABEL maintainer="expressvpn-docker-gateway"
LABEL description="ExpressVPN gateway container — Lightway protocol, iptables NAT + kill-switch"
LABEL org.opencontainers.image.source="https://github.com/expressvpn"

FROM debian:bookworm-slim AS runtime
# v4 no longer requires NetworkManager (libnm0) or ReadKey
RUN apt-get update && apt-get install -y --no-install-recommends \
    expect iproute2 iptables ca-certificates procps curl socat \
    && rm -rf /var/lib/apt/lists/*

# Install ExpressVPN v4 via the universal installer
COPY --from=downloader /tmp/expressvpn.deb /tmp/expressvpn.deb

RUN dpkg -i /tmp/expressvpn.deb || apt-get install -f -y && \
    rm /tmp/expressvpn.deb
# ── Scripts ────────────────────────────────────────────────────────────────────
COPY scripts/entrypoint.sh      /usr/local/bin/entrypoint.sh
COPY scripts/activate.exp       /usr/local/bin/activate.exp
COPY scripts/healthcheck.sh     /usr/local/bin/healthcheck.sh

RUN chmod +x \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/healthcheck.sh

# ── Environment defaults (override via .env or docker-compose) ─────────────────
# ACTIVATION_CODE  : Required — from https://www.expressvpn.com/setup#manual
# SERVER           : smart | <country> | <alias>  (e.g. "USA - New York")
# PREFERRED_PROTOCOL: lightway_udp | lightway_tcp | auto
# LIGHTWAY_CIPHER  : auto | aes256 | chacha20
# FIREWALL_OUTBOUND_SUBNETS: comma-separated CIDR(s) to bypass kill-switch (LAN access)
# RECONNECT_DELAY  : seconds between watchdog reconnect attempts
# HEALTH_PORT      : port for the internal HTTP health endpoint
# EXPRESSVPN_VERSION: informational — shows which v4 build is installed
ENV ACTIVATION_CODE=""
ENV SERVER="smart"
ENV PREFERRED_PROTOCOL="lightway_udp"
ENV LIGHTWAY_CIPHER="auto"
ENV FIREWALL_OUTBOUND_SUBNETS="192.168.90.0/24"
ENV RECONNECT_DELAY="30"
ENV HEALTH_PORT="8999"
ENV TZ="America/New_York"
ARG APP_VERSION
ENV EXPRESSVPN_VERSION="${APP_VERSION}"

# ── Ports ──────────────────────────────────────────────────────────────────────
# Expose the health port; all other ports are published in docker-compose.yml
EXPOSE ${HEALTH_PORT}

# ── Health check ───────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# ── Capabilities needed ────────────────────────────────────────────────────────
# NET_ADMIN and /dev/net/tun must be granted in docker-compose.yml; they cannot
# be set in the Dockerfile itself.

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
