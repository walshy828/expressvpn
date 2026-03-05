#!/usr/bin/env bash
# =============================================================================
# ExpressVPN Docker Gateway — Entrypoint
# =============================================================================
# 1. Validates required env vars
# 2. Starts expressvpnd daemon
# 3. Activates + configures ExpressVPN (Lightway protocol)
# 4. Connects to VPN server
# 5. Waits for tun0 interface
# 6. Configures iptables NAT (so attached containers route through VPN)
# 7. Configures kill-switch (blocks all non-VPN forwarded traffic)
# 8. Starts HTTP health endpoint
# 9. Runs watchdog loop (auto-reconnect on disconnect)
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[expressvpn]${NC} $*"; }
warn() { echo -e "${YELLOW}[expressvpn]${NC} $*"; }
err()  { echo -e "${RED}[expressvpn]${NC} $*" >&2; }

# ── Validate required env ─────────────────────────────────────────────────────
if [ -z "${ACTIVATION_CODE:-}" ]; then
  err "ACTIVATION_CODE is required. Get yours at https://www.expressvpn.com/setup#manual"
  exit 1
fi

: "${SERVER:=smart}"
: "${PREFERRED_PROTOCOL:=lightway_udp}"
: "${LIGHTWAY_CIPHER:=auto}"
: "${FIREWALL_OUTBOUND_SUBNETS:=192.168.90.0/24}"
: "${RECONNECT_DELAY:=30}"
: "${HEALTH_PORT:=8999}"

log "Starting ExpressVPN Gateway"
log "  Version:   ${EXPRESSVPN_VERSION:-v4}"
log "  Server:    ${SERVER}"
log "  Protocol:  ${PREFERRED_PROTOCOL}"
log "  Cipher:    ${LIGHTWAY_CIPHER}"
log "  LAN Nets:  ${FIREWALL_OUTBOUND_SUBNETS}"

# ── Fix resolv.conf (Docker bind-mount issue with expressvpnd) ─────────────────
cp /etc/resolv.conf /tmp/resolv.conf.bak
# expressvpnd requires write access to manage DNS — unmount the bind file
umount /etc/resolv.conf 2>/dev/null || true
cp /tmp/resolv.conf.bak /etc/resolv.conf

# ── Check for local installer drop-in ──────────────────────────────────────────
# If you drop an installer into /docker/arr-stack/expressvpn/ (mapped to /data)
if [ -f "/data/expressvpn.run" ]; then
  log "Found local installer at /data/expressvpn.run. Installing..."
  # Removed --quiet to see errors, and removed || true so it fails if install fails
  chmod +x "/data/expressvpn.run"
  "/data/expressvpn.run" --accept 
  
  # Only move if successful
  mv "/data/expressvpn.run" "/data/expressvpn.run.installed-$(date +%s)"
  log "Installation complete."
fi

# ── Start expressvpnd daemon ───────────────────────────────────────────────────
log "Starting expressvpn daemon..."
# v4 changed service name from 'expressvpn' to 'expressvpn-daemon' on some builds.
# Try both names; fall back to direct binary invocation.
sed -i 's/DAEMON_ARGS=.*/DAEMON_ARGS=""/' /etc/init.d/expressvpn 2>/dev/null || true
sed -i 's/DAEMON_ARGS=.*/DAEMON_ARGS=""/' /etc/init.d/expressvpn-daemon 2>/dev/null || true

if service expressvpn-daemon restart 2>/dev/null; then
  DAEMON_SVC="expressvpn-daemon"
elif service expressvpn restart 2>/dev/null; then
  DAEMON_SVC="expressvpn"
elif [ -x /usr/bin/expressvpnd ]; then
  # Direct binary fallback for minimal installs
  /usr/bin/expressvpnd &
  DAEMON_SVC="direct"
else
  err "Cannot start expressvpn daemon — is the package installed correctly?"
  exit 1
fi
log "Daemon started via: ${DAEMON_SVC}"

# Wait for daemon to be ready
for i in $(seq 1 30); do
  if expressvpn status &>/dev/null; then
    log "expressvpnd is ready"
    break
  fi
  [ "$i" -eq 30 ] && { err "expressvpnd failed to start"; exit 1; }
  sleep 1
done

# ── Activate ExpressVPN ────────────────────────────────────────────────────────
log "Activating ExpressVPN..."
expect /usr/local/bin/activate.exp

# ── Configure Lightway Protocol ───────────────────────────────────────────────
log "Configuring protocol: ${PREFERRED_PROTOCOL} / cipher: ${LIGHTWAY_CIPHER}"
expressvpn preferences set preferred_protocol "${PREFERRED_PROTOCOL}"
expressvpn preferences set lightway_cipher "${LIGHTWAY_CIPHER}"
expressvpn preferences set auto_connect true
# Send anonymous analytics (off for privacy)
expressvpn preferences set send_diagnostics false 2>/dev/null || true

# ── Connect ────────────────────────────────────────────────────────────────────
connect_vpn() {
  log "Connecting to: ${SERVER}"
  expressvpn connect "${SERVER}" && return 0
  err "Connection failed — retrying in ${RECONNECT_DELAY}s..."
  return 1
}

connect_vpn || true

# ── Wait for tun0 interface ────────────────────────────────────────────────────
log "Waiting for VPN tunnel interface..."
TUN_IFACE=""
for i in $(seq 1 60); do
  # ExpressVPN Lightway uses 'utun0' on some systems, 'tun0' on Linux
  for iface in tun0 utun0; do
    if ip link show "$iface" &>/dev/null 2>&1; then
      TUN_IFACE="$iface"
      break 2
    fi
  done
  [ "$i" -eq 60 ] && { err "Timeout waiting for VPN interface. Check activation code and server."; exit 1; }
  sleep 1
done
log "VPN tunnel up on ${TUN_IFACE}"

# ── iptables: NAT / IP Masquerade ─────────────────────────────────────────────
# Attached containers use network_mode: service:expressvpn.
# They share this network namespace — their traffic exits via tun0 after MASQUERADE.
log "Configuring iptables NAT on ${TUN_IFACE}..."

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true  # Prevent IPv6 leaks

# Flush existing rules (clean slate)
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# ── Kill-switch: default FORWARD DROP ─────────────────────────────────────────
# Any traffic that cannot route through the VPN tunnel is silently dropped.
iptables -P INPUT   ACCEPT   # Container can receive replies
iptables -P OUTPUT  ACCEPT   # Container can initiate — expressvpnd handles this
iptables -P FORWARD DROP     # Kill-switch: block forwarded traffic by default

# Allow loopback
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related on all interfaces (return traffic)
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow forwarded traffic only through the VPN tunnel
iptables -A FORWARD -o "${TUN_IFACE}" -j ACCEPT
iptables -A FORWARD -i "${TUN_IFACE}" -j ACCEPT

# NAT: masquerade outbound traffic through the VPN tunnel
iptables -t nat -A POSTROUTING -o "${TUN_IFACE}" -j MASQUERADE

# Allow LAN subnets to bypass kill-switch (for Sonarr→NAS access etc.)
IFS=',' read -ra SUBNETS <<< "${FIREWALL_OUTBOUND_SUBNETS}"
for SUBNET in "${SUBNETS[@]}"; do
  SUBNET="${SUBNET// /}"  # trim spaces
  [ -z "$SUBNET" ] && continue
  log "  Allowing LAN subnet: ${SUBNET}"
  iptables -A FORWARD -d "${SUBNET}" -j ACCEPT
  iptables -A FORWARD -s "${SUBNET}" -j ACCEPT
done

log "iptables NAT + kill-switch configured"

# ── Health HTTP Endpoint ───────────────────────────────────────────────────────
# Simple HTTP server on HEALTH_PORT — returns 200 "connected" or 503 "disconnected"
# Used by Docker HEALTHCHECK and by docker-compose depends_on health condition.
log "Starting health endpoint on :${HEALTH_PORT}..."

health_server() {
  while true; do
    STATUS=$(expressvpn status 2>/dev/null || echo "error")
    if echo "$STATUS" | grep -qi "Connected"; then
      HTTP_STATUS="200 OK"
      BODY="connected"
    else
      HTTP_STATUS="503 Service Unavailable"
      BODY="disconnected"
    fi
    # socat: accept one connection, respond, loop
    echo -e "HTTP/1.1 ${HTTP_STATUS}\r\nContent-Type: text/plain\r\nContent-Length: ${#BODY}\r\nConnection: close\r\n\r\n${BODY}" \
      | socat TCP-LISTEN:${HEALTH_PORT},reuseaddr,fork STDIN 2>/dev/null &
    sleep 5
    kill %1 2>/dev/null || true
  done
}

# Better socat-based health server (handles concurrent requests properly)
socat_health() {
  while true; do
    STATUS=$(expressvpn status 2>/dev/null || echo "error")
    if echo "$STATUS" | grep -qi "Connected"; then
      RESP="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nconnected"
    else
      RESP="HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\n\r\ndisconnected"
    fi
    echo -e "$RESP" | timeout 2 socat -u - TCP-LISTEN:${HEALTH_PORT},reuseaddr 2>/dev/null || true
  done
}

socat_health &
HEALTH_PID=$!

# ── Watchdog: Auto-reconnect ───────────────────────────────────────────────────
watchdog() {
  log "Watchdog started (interval: ${RECONNECT_DELAY}s)"
  while true; do
    sleep "${RECONNECT_DELAY}"
    STATUS=$(expressvpn status 2>/dev/null || echo "error")
    if ! echo "$STATUS" | grep -qi "Connected"; then
      warn "VPN disconnected — reconnecting to ${SERVER}..."
      expressvpn connect "${SERVER}" 2>/dev/null || true
      # Re-check tun interface after reconnect (it may change)
      for iface in tun0 utun0; do
        if ip link show "$iface" &>/dev/null 2>&1; then
          if [ "$iface" != "$TUN_IFACE" ]; then
            warn "Tunnel interface changed to ${iface}, updating iptables..."
            iptables -t nat -F POSTROUTING
            iptables -t nat -A POSTROUTING -o "${iface}" -j MASQUERADE
            TUN_IFACE="$iface"
          fi
          break
        fi
      done
    fi
  done
}

watchdog &
WATCHDOG_PID=$!

log "ExpressVPN Gateway is READY"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
expressvpn status

# ── Graceful shutdown ─────────────────────────────────────────────────────────
cleanup() {
  log "Shutting down..."
  kill "$WATCHDOG_PID" 2>/dev/null || true
  kill "$HEALTH_PID"   2>/dev/null || true
  expressvpn disconnect 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

# Keep container alive — wait on watchdog
wait "$WATCHDOG_PID"
