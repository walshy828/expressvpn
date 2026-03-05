#!/usr/bin/env bash
# =============================================================================
# ExpressVPN Gateway — Health Check  (v4 compatible)
# =============================================================================
# Uses expressvpnctl (headless CLI) instead of expressvpn-client (Qt GUI).
# Exits 0 = healthy, 1 = unhealthy.
# Checks:
#   1. expressvpnctl reports "Connected" connection state
#   2. tun0 or utun0 interface exists (actual tunnel is active)

set -euo pipefail

export LD_LIBRARY_PATH="/opt/expressvpn/lib:${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LANG="${LANG:-C.UTF-8}"

# Check VPN connection state via headless CTL tool
VPN_STATE=$(expressvpnctl get connectionstate 2>/dev/null || echo "error")

if ! echo "$VPN_STATE" | grep -qi "^Connected$"; then
  echo "UNHEALTHY: VPN state is '${VPN_STATE}' (expected 'Connected')"
  exit 1
fi

# Check tunnel interface is actually present
if ! (ip link show tun0 &>/dev/null || ip link show utun0 &>/dev/null); then
  echo "UNHEALTHY: State is Connected but no tun0/utun0 interface found"
  exit 1
fi

echo "HEALTHY: Connected via $(ip link show tun0 &>/dev/null && echo tun0 || echo utun0)"
exit 0
