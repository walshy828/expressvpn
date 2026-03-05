#!/usr/bin/env bash
# =============================================================================
# ExpressVPN Gateway — Health Check
# =============================================================================
# Used by Docker HEALTHCHECK directive. Exits 0 = healthy, 1 = unhealthy.
# Checks both:
#   1. expressvpn status reports "Connected"
#   2. The tun0/utun0 interface exists (actual tunnel is up)

set -euo pipefail

# Check VPN status via expressvpn CLI
VPN_STATUS=$(expressvpn status 2>/dev/null || echo "error")

if ! echo "$VPN_STATUS" | grep -qi "Connected"; then
  echo "UNHEALTHY: ExpressVPN reports: ${VPN_STATUS}"
  exit 1
fi

# Check tunnel interface is present
if ! (ip link show tun0 &>/dev/null || ip link show utun0 &>/dev/null); then
  echo "UNHEALTHY: VPN status is Connected but no tunnel interface found"
  exit 1
fi

echo "HEALTHY: ${VPN_STATUS}"
exit 0
