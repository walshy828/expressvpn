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

FROM debian:bookworm-slim AS runtime

LABEL maintainer="expressvpn-docker-gateway"
LABEL description="ExpressVPN gateway container — Lightway protocol, iptables NAT + kill-switch"
LABEL org.opencontainers.image.source="https://github.com/expressvpn"

# v4 no longer requires NetworkManager (libnm0) or ReadKey, but still needs DBus
RUN apt-get update && apt-get install -y --no-install-recommends \
    expect iproute2 iptables ca-certificates procps curl socat python3 \
    psmisc libatomic1 libglib2.0-0 libbrotli1 libdbus-1-3 libasound2 \
    dbus dnsmasq libxkbcommon0 libxkbcommon-x11-0 libgl1 libegl1 libopengl0 \
    libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-render-util0 \
    libsm6 libice6 libfontconfig1 libfreetype6 libxau6 libxdmcp6 \
    && rm -rf /var/lib/apt/lists/*
# ── Scripts ────────────────────────────────────────────────────────────────────
COPY scripts/entrypoint.sh      /usr/local/bin/entrypoint.sh
COPY scripts/activate.exp       /usr/local/bin/activate.exp
COPY scripts/healthcheck.sh     /usr/local/bin/healthcheck.sh
COPY scripts/vpn_api.py        /usr/local/bin/vpn_api.py

RUN chmod +x \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/healthcheck.sh \
    /usr/local/bin/vpn_api.py

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
# v4 protocol names changed: lightway_udp → lightwayudp, lightway_tcp → lightwaytcp
ENV PREFERRED_PROTOCOL="lightwayudp"
ENV LIGHTWAY_CIPHER="auto"
ENV FIREWALL_OUTBOUND_SUBNETS="192.168.90.0/24"
ENV RECONNECT_DELAY="30"
ENV HEALTH_PORT="8999"
ENV TZ="America/New_York"
# Qt headless mode — prevents the v4 client binary from aborting on missing display
ENV QT_QPA_PLATFORM="offscreen"
ENV LANG="C.UTF-8"
ARG APP_VERSION
ENV EXPRESSVPN_VERSION="${APP_VERSION}"
ENV INSTALLER_PATH="/data/expressvpn.run"

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
