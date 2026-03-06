#!/usr/bin/env bash
# =============================================================================
# ExpressVPN Docker Gateway — Entrypoint  (v4 compatible)
# =============================================================================
# Flow:
#   1.  Validate required env vars
#   2.  Install ExpressVPN v4 from mounted .run file (idempotent)
#   3.  Start expressvpnd daemon
#   4.  Wait for daemon IPC socket (daemon.sock)
#   5.  Enable background mode (allows headless CLI control)
#   6.  Activate via expressvpnctl login
#   7.  Configure protocol / cipher
#   8.  Connect
#   9.  Wait for tun interface
#   10. Configure iptables NAT + kill-switch
#   11. Run HTTP health endpoint + watchdog
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
: "${PREFERRED_PROTOCOL:=lightwayudp}"
: "${LIGHTWAY_CIPHER:=auto}"
: "${FIREWALL_OUTBOUND_SUBNETS:=192.168.90.0/24}"
: "${RECONNECT_DELAY:=30}"
: "${HEALTH_PORT:=8999}"
: "${TZ:=America/New_York}"

# ── Timezone setup ────────────────────────────────────────────────────────────
# Ensure /etc/localtime matches $TZ for system-wide consistency
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && echo "${TZ}" > /etc/timezone
  log "System timezone set to: ${TZ}"
fi

# Set library path early — required before ANY expressvpn binary is exec'd
export LD_LIBRARY_PATH="/opt/expressvpn/lib:${LD_LIBRARY_PATH:-}"
# Qt headless: prevents expressvpn-client from aborting when no display is present
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LANG="${LANG:-C.UTF-8}"
export TZ="${TZ}"

log "Starting ExpressVPN Gateway v${EXPRESSVPN_VERSION:-4}"
log "  Server:    ${SERVER}"
log "  Protocol:  ${PREFERRED_PROTOCOL}"
log "  Cipher:    ${LIGHTWAY_CIPHER}"
log "  LAN Nets:  ${FIREWALL_OUTBOUND_SUBNETS}"

# ── Fix resolv.conf (Docker bind-mount lock prevents daemon from managing DNS) ─
cp /etc/resolv.conf /tmp/resolv.conf.bak
umount /etc/resolv.conf 2>/dev/null || true
cp /tmp/resolv.conf.bak /etc/resolv.conf

# ── Install ExpressVPN v4 (idempotent) ─────────────────────────────────────────
# Skip if binaries are already in place (handles crash-loop restarts without
# re-extracting the ~190MB installer on every attempt).
EVPND_BIN="/usr/bin/expressvpnd"
EVPNCTL_BIN="/usr/bin/expressvpnctl"

if [ -f "${EVPND_BIN}" ] && [ -f "${EVPNCTL_BIN}" ]; then
  log "ExpressVPN binaries already installed — skipping extraction."
elif [ -f "/data/expressvpn.run" ]; then
  log "Found installer at /data/expressvpn.run. Beginning extraction..."

  ARCH=$(uname -m)
  case "$ARCH" in
    aarch64) EVPN_ARCH="arm64" ;;
    x86_64)  EVPN_ARCH="x64"   ;;
    *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  log "Architecture: $ARCH → installer path: $EVPN_ARCH"

  # Extract synchronously — wait for full completion before proceeding.
  # Use --noexec to ONLY extract files (skip the embedded installer script
  # which calls systemd/apt/dpkg and exits 1 in a headless Docker container).
  rm -rf /tmp/evpn-extract && mkdir -p /tmp/evpn-extract
  log "Extracting installer (may take 30–60s)..."
  bash "/data/expressvpn.run" --target /tmp/evpn-extract --nox11 --noexec
  log "Extraction complete."

  EXTRACT_ROOT="/tmp/evpn-extract/$EVPN_ARCH/expressvpnfiles"

  # Required unix groups for v4
  groupadd -f expressvpn     || true
  groupadd -f expressvpnhnsd || true

  # Copy all files synchronously before doing anything else
  log "Installing to /opt/expressvpn..."
  mkdir -p /opt/expressvpn
  cp -a "$EXTRACT_ROOT/." /opt/expressvpn/

  # Runtime directories the daemon writes to
  mkdir -p /opt/expressvpn/var/lib \
           /opt/expressvpn/var/run \
           /var/lib/expressvpn
  chown -R root:expressvpn /opt/expressvpn
  chmod -R 775 /opt/expressvpn/var

  # Routing tables required by Lightway / WireGuard
  for table in expressvpnrt expressvpnOnlyrt expressvpnWgrt expressvpnFwdrt; do
    if ! grep -q "$table" /etc/iproute2/rt_tables; then
      EX_COUNT=$(grep -c "expressvpn" /etc/iproute2/rt_tables || true)
      ID=$((100 + EX_COUNT))
      echo "$ID $table" >> /etc/iproute2/rt_tables
    fi
  done

  # Symlink v4 binaries to /usr/bin (conventional paths)
  log "Creating binary symlinks..."
  [ -f /opt/expressvpn/bin/expressvpn-client  ] && ln -sf /opt/expressvpn/bin/expressvpn-client  /usr/bin/expressvpn
  [ -f /opt/expressvpn/bin/expressvpn-daemon  ] && ln -sf /opt/expressvpn/bin/expressvpn-daemon  /usr/bin/expressvpnd
  [ -f /opt/expressvpn/bin/expressvpnctl      ] && ln -sf /opt/expressvpn/bin/expressvpnctl      /usr/bin/expressvpnctl

  # Register shared libs NOW — after all files are in place
  log "Registering shared libraries..."
  {
    echo "/opt/expressvpn/lib"
    echo "/usr/lib/expressvpn"
  } > /etc/ld.so.conf.d/expressvpn.conf
  ldconfig
  log "ldconfig cache updated."

  # Validate binary + library resolution
  for binary in "$EVPND_BIN" "$EVPNCTL_BIN"; do
    if [ ! -f "$binary" ]; then
      err "Missing binary after install: $binary"
      ls "$EXTRACT_ROOT/bin/" 2>/dev/null || true
      exit 1
    fi
    MISSING=$(LD_LIBRARY_PATH="/opt/expressvpn/lib:${LD_LIBRARY_PATH:-}" ldd "$binary" 2>&1 | grep "not found" || true)
    if [ -n "$MISSING" ]; then
      err "$binary has unresolved shared libraries — add them to the Dockerfile:"
      echo "$MISSING" >&2
      exit 1
    fi
  done
  log "Installation validated."

else
  err "No installer found at /data/expressvpn.run and no binaries in place."
  err "Mount the installer: volumes: - ./releases/expressvpn.run:/data/expressvpn.run:ro"
  exit 1
fi

# ── Start dbus (required by expressvpnd for IPC) ───────────────────────────────
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --fork 2>/dev/null || true

# ── Start expressvpnd daemon ───────────────────────────────────────────────────
log "Starting expressvpnd daemon..."

if command -v expressvpnd >/dev/null 2>&1; then
  expressvpnd &
  DAEMON_PID=$!
  log "Daemon started (PID ${DAEMON_PID})"
elif [ -x /opt/expressvpn/bin/expressvpn-daemon ]; then
  /opt/expressvpn/bin/expressvpn-daemon &
  DAEMON_PID=$!
  log "Daemon started via full path (PID ${DAEMON_PID})"
else
  err "Cannot find expressvpnd binary. Installation may have failed."
  exit 1
fi

# Brief pause to let the daemon process initialise before socket polling
sleep 2

# ── Wait for daemon IPC socket ─────────────────────────────────────────────────
# v4 daemon creates 'daemon.sock' in /opt/expressvpn/var/ (NOT a fixed path
# under /run). Poll for it specifically.
DAEMON_SOCK="/opt/expressvpn/var/daemon.sock"
log "Waiting for daemon socket at ${DAEMON_SOCK}..."
for i in $(seq 1 60); do
  if [ -S "$DAEMON_SOCK" ]; then
    log "Daemon socket ready (attempt ${i})"
    break
  fi
  [ "$i" -eq 60 ] && { err "Timeout: daemon socket never appeared. Check expressvpnd logs."; exit 1; }
  sleep 1
done

# Extra grace period — the socket appears before the IPC handler is fully wired up
log "Waiting for daemon IPC to become ready..."
sleep 15

# ── Enable background mode (CRITICAL for headless CLI operation) ───────────────
# Without this, expressvpnctl commands time out because the daemon treats itself
# as an accessory to the GUI client and suspends activity when no GUI connects.
log "Enabling background mode (headless CLI control)..."
BG_ENABLED=false
for i in $(seq 1 15); do
  if expressvpnctl background enable 2>/dev/null; then
    log "Background mode enabled (attempt ${i})"
    BG_ENABLED=true
    break
  fi
  warn "Waiting for daemon IPC (attempt ${i}/15)..."
  sleep 3
done
if [ "$BG_ENABLED" = "false" ]; then
  err "Failed to enable background mode after 15 attempts (~45s)."
  exit 1
fi

# ── Activate / Login ───────────────────────────────────────────────────────────
log "Activating ExpressVPN..."
# Check if already logged in — avoids burning activation requests on restart
EVPN_STATUS=$(expressvpnctl status 2>/dev/null || echo "unknown")
if echo "$EVPN_STATUS" | grep -qi "Not logged in\|not activated\|unknown"; then
  log "Not logged in — running activation..."
  ACTIVATE_FILE=$(mktemp)
  echo "${ACTIVATION_CODE}" > "$ACTIVATE_FILE"
  if ! expressvpnctl login "$ACTIVATE_FILE"; then
    err "Activation failed. Verify your ACTIVATION_CODE at https://www.expressvpn.com/setup#manual"
    rm -f "$ACTIVATE_FILE"
    exit 1
  fi
  rm -f "$ACTIVATE_FILE"
  log "Activation successful."
else
  log "Already activated. Skipping login. (status: $(echo "$EVPN_STATUS" | head -1))"
fi

# ── Configure Protocol / Cipher / Preferences ─────────────────────────────────
# v4 protocol names: lightwayudp | lightwaytcp | openvpnudp | openvpntcp | auto
log "Setting protocol: ${PREFERRED_PROTOCOL}"
expressvpnctl set protocol "${PREFERRED_PROTOCOL}" 2>/dev/null || \
  warn "Could not set protocol — check name (lightwayudp|lightwaytcp|auto)"

# Disable network lock (kill switch) managed here by iptables instead
expressvpnctl set networklock false 2>/dev/null || true

# ── Connect ────────────────────────────────────────────────────────────────────
connect_vpn() {
  log "Connecting to: ${SERVER}"
  expressvpnctl connect "${SERVER}" && return 0
  err "Connection failed — retrying in ${RECONNECT_DELAY}s..."
  return 1
}
connect_vpn || true

# ── Wait for tun interface ─────────────────────────────────────────────────────
log "Waiting for VPN tunnel interface..."
TUN_IFACE=""
for i in $(seq 1 90); do
  for iface in tun0 utun0; do
    if ip link show "$iface" &>/dev/null 2>&1; then
      TUN_IFACE="$iface"
      break 2
    fi
  done
  [ "$i" -eq 90 ] && { err "Timeout waiting for VPN interface. Check activation code and server."; exit 1; }
  sleep 1
done
log "VPN tunnel up on: ${TUN_IFACE}"
 
log "Forcing default routing through ${TUN_IFACE}..."
# Use /2 routes to bypass ExpressVPN's suppress_prefixlength 1 rule
# (which ignores routes with prefix length 0 or 1 in the main table).
ip route add 0.0.0.0/2 dev "${TUN_IFACE}" || true
ip route add 64.0.0.0/2 dev "${TUN_IFACE}" || true
ip route add 128.0.0.0/2 dev "${TUN_IFACE}" || true
ip route add 192.0.0.0/2 dev "${TUN_IFACE}" || true
log "Routing override applied (/2 routes)."

# ── iptables: NAT + Kill-switch ────────────────────────────────────────────────
log "Configuring iptables NAT + kill-switch on ${TUN_IFACE}..."

echo 1 > /proc/sys/net/ipv4/ip_forward
# Belt-and-suspenders IPv6 disable — prefer kernel sysctl but also set via ip6tables
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6  2>/dev/null || true
echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null || true

# ── Flush ALL existing rules (clean slate every boot) ──────────────────────────
iptables  -F; iptables  -X; iptables  -Z
iptables  -t nat    -F; iptables  -t nat    -X
iptables  -t mangle -F; iptables  -t mangle -X

# ── IPv6: Block everything — we are IPv4/VPN only ──────────────────────────────
# Even with disable_ipv6=1 at kernel level, add ip6tables rules as a hard backstop
# to prevent any IPv6 traffic escaping the container unencrypted.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F; ip6tables -X 2>/dev/null || true
  ip6tables -P INPUT   DROP
  ip6tables -P OUTPUT  DROP
  ip6tables -P FORWARD DROP
  # Allow loopback IPv6 (needed by some internal services)
  ip6tables -A INPUT  -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  log "ip6tables: all IPv6 forwarding blocked (full DROP policy)"
else
  warn "ip6tables not found — relying on kernel disable_ipv6 sysctl only"
fi

# ── IPv4 Kill-switch: default FORWARD DROP ─────────────────────────────────────
# Any packet that cannot route through the VPN tunnel is silently dropped.
# This is the "kill switch" — containers sharing this network namespace
# lose internet access the moment the tunnel goes down.
iptables -P INPUT   ACCEPT   # Container can receive replies on any interface
iptables -P OUTPUT  ACCEPT   # Container can originate — expressvpnd handles routing
iptables -P FORWARD DROP     # ← Kill-switch: nothing forwards by default

# Loopback is always allowed
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow return traffic for already-established connections (stateful)
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ── VPN tunnel forward rules ── ONLY tun0 traffic is permitted ─────────────────
# Outbound: allow forwarded packets going OUT through the VPN tunnel
iptables -A FORWARD -o "${TUN_IFACE}" -j ACCEPT
# Inbound: allow forwarded packets coming IN from the VPN tunnel
iptables -A FORWARD -i "${TUN_IFACE}" -j ACCEPT

# ── NAT: MASQUERADE scoped to tun0 only ───────────────────────────────────────
# If tun0 goes down, this rule vanishes too — no traffic would be masqueraded
# through a fallback interface (the FORWARD DROP above blocks it anyway).
iptables -t nat -A POSTROUTING -o "${TUN_IFACE}" -j MASQUERADE

# ── OUTPUT kill-switch: block cleartext egress on the physical interface ────────
# Containers using `network_mode: service:expressvpn` share this network namespace.
# Their traffic appears in the OUTPUT chain (not FORWARD) from the kernel's view.
# Without these rules, if tun0 drops, traffic leaks through eth0 (the host route).
#
# Strategy: ACCEPT on tun0, ACCEPT established return traffic on eth0,
#           DROP all new outbound on eth0/physical interfaces.
#
# Find the physical (non-VPN, non-loopback, non-virtual) interface
# Match eth*, ens*, enp*, wlan* — the real container/host NIC assigned by Docker
ETH_IFACE=$(ip -o link show | awk -F': ' '$2 ~ /^(eth|ens|enp|wlan)/ {print $2; exit}' | cut -d'@' -f1)
log "Physical interface for OUTPUT kill-switch: ${ETH_IFACE}"

# Allow all traffic on the VPN tunnel (outbound to VPN)
iptables -A OUTPUT -o "${TUN_IFACE}" -j ACCEPT
# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
# Allow established/related return packets on eth0 (e.g. DHCP, ARP, DNS replies)
iptables -A OUTPUT -o "${ETH_IFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Allow the VPN daemon itself to reach VPN servers over eth0 (lightway handshake, ICMP)
# Without this the daemon can't establish the tunnel on first boot
iptables -A OUTPUT -o "${ETH_IFACE}" -m owner --uid-owner 0 -p udp -j ACCEPT
iptables -A OUTPUT -o "${ETH_IFACE}" -m owner --uid-owner 0 -p tcp -j ACCEPT
# Block all other new outbound on physical interface — kills cleartext leak
iptables -A OUTPUT -o "${ETH_IFACE}" -j DROP

log "OUTPUT kill-switch: new cleartext egress on ${ETH_IFACE} is blocked for non-root."

# ── LAN bypass exceptions (e.g. Sonarr → NAS, or host admin access) ──────────
IFS=',' read -ra SUBNETS <<< "${FIREWALL_OUTBOUND_SUBNETS}"
for SUBNET in "${SUBNETS[@]}"; do
  SUBNET="${SUBNET// /}"
  [ -z "$SUBNET" ] && continue
  log "  Allowing LAN bypass: ${SUBNET}"
  iptables -A FORWARD -d "${SUBNET}" -j ACCEPT
  iptables -A FORWARD -s "${SUBNET}" -j ACCEPT
done

log "iptables NAT + kill-switch configured."

# ── Policy Routing: Ensure eth0 responses stay on eth0 ────────────────────────
# This prevents asymmetric routing (SYN on eth0 -> SYN-ACK on tun0)
# which happens when the source IP is considered "Internet" by the VPN.
ETH_GW=$(ip route show default dev "${ETH_IFACE}" | awk '{print $3}' | head -1)
if [ -n "${ETH_GW}" ]; then
  log "Setting up policy routing for ${ETH_IFACE} via ${ETH_GW}..."
  # Mark connections arriving on eth0
  iptables -t mangle -A PREROUTING -i "${ETH_IFACE}" -j CONNMARK --set-mark 0x8999
  # Restore mark to outgoing packets
  iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
  # Route marked packets via host gateway instead of tun0
  ip route add default via "${ETH_GW}" dev "${ETH_IFACE}" table 100 2>/dev/null || true
  # Add rule to use the table
  ip rule add fwmark 0x8999 table 100 priority 10
  log "  Policy routing active (table 100)."
else
  warn "Could not detect ${ETH_IFACE} gateway. API access from external IPs might fail."
fi

log "  IPv4 FORWARD default policy: $(iptables -L FORWARD | head -1 | grep -o 'policy [A-Z]*')"
log "  NAT MASQUERADE interface:    ${TUN_IFACE}"
log "  IPv6 FORWARD default policy: $(ip6tables -L FORWARD 2>/dev/null | head -1 | grep -o 'policy [A-Z]*' || echo 'kernel sysctl disabled')"

# ── VPN Control API & Health Endpoint ─────────────────────────────────────────
# Replaces the simple socat loop with a secure Python API that allows
# rotating locations and checking status.
log "Starting VPN Control API on :${HEALTH_PORT}..."
export API_KEY="${API_KEY:-}"
python3 /usr/local/bin/vpn_api.py &
API_PID=$!

# ── Watchdog: Auto-reconnect ───────────────────────────────────────────────────
watchdog() {
  log "Watchdog started (interval: ${RECONNECT_DELAY}s)"
  while true; do
    sleep "${RECONNECT_DELAY}"
    STATE=$(expressvpnctl get connectionstate 2>/dev/null || echo "error")
    if ! echo "$STATE" | grep -qi "^Connected$"; then
      warn "VPN not connected (state: ${STATE}) — reconnecting to ${SERVER}..."
      expressvpnctl connect "${SERVER}" 2>/dev/null || true

      # Update iptables if the tunnel interface changes after reconnect
      for iface in tun0 utun0; do
        if ip link show "$iface" &>/dev/null 2>&1; then
          if [ "$iface" != "$TUN_IFACE" ]; then
            warn "Tunnel interface changed: ${TUN_IFACE} → ${iface}. Updating iptables..."
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

log "ExpressVPN Gateway is READY ✓"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
expressvpnctl status 2>/dev/null || true

# ── Graceful shutdown ─────────────────────────────────────────────────────────
cleanup() {
  log "Shutting down..."
  kill "$WATCHDOG_PID" 2>/dev/null || true
  kill "$API_PID"      2>/dev/null || true
  expressvpnctl disconnect 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

# Keep container alive — block on watchdog
wait "$WATCHDOG_PID"
