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

# ── Stage 1: Download the installer (isolates network fetch from final image) ──
# v4 ships a universal shell installer that wraps the .deb internally.
# The official download URL pattern for v4+:
#   https://www.expressvpn.com/clients/linux/expressvpn_<VER>_amd64.run
# (The .works mirror is for v3 only and does not carry v4 packages.)
FROM debian:bookworm-slim AS downloader

ARG APP_VERSION
ARG TARGETARCH

# Map Docker arch → ExpressVPN arch suffix (v4 supports amd64 and arm64)
RUN ARCH="amd64"; \
    [ "$TARGETARCH" = "arm64" ] && ARCH="arm64"; \
    INSTALLER="expressvpn_${APP_VERSION}_${ARCH}.run"; \
    apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    wget -q "https://www.expressvpn.com/clients/linux/${INSTALLER}" -O /tmp/expressvpn.run && \
    chmod +x /tmp/expressvpn.run

# ── Stage 2: Final runtime image ───────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

LABEL maintainer="expressvpn-docker-gateway"
LABEL description="ExpressVPN gateway container — Lightway protocol, iptables NAT + kill-switch"
LABEL org.opencontainers.image.source="https://github.com/expressvpn"

# Runtime dependencies only — keep image small
# libterm-readkey-perl + expect: needed for non-interactive activation
# iproute2: ip route / ip addr
# iptables: NAT + kill-switch rules
# procps: ps, used by healthcheck
# libnm0: NetworkManager lib required by expressvpnd
# curl: health probe + connectivity test
# socat: lightweight HTTP server for health endpoint
# v4 has reduced runtime dependencies vs v3:
#   REMOVED: libnm0 (NetworkManager no longer required)
#   REMOVED: libterm-readkey-perl (activation no longer needs it)
#   KEPT:    expect (still needed for non-interactive `expressvpn activate`)
RUN apt-get update && apt-get install -y --no-install-recommends \
    expect \
    iproute2 \
    iptables \
    ca-certificates \
    procps \
    curl \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Install ExpressVPN v4 via the universal installer
# --headless flag: skip GUI setup, install daemon + CLI only
# --no-gui: v4 flag to suppress GUI component installation
COPY --from=downloader /tmp/expressvpn.run /tmp/expressvpn.run
RUN /tmp/expressvpn.run --headless 2>/dev/null || \
    sh /tmp/expressvpn.run --headless || \
    apt-get install -fy 2>/dev/null ; \
    rm /tmp/expressvpn.run

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
