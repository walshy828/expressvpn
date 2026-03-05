# ExpressVPN Docker Gateway

A lightweight, ExpressVPN-native Docker container that replaces **gluetun** as a VPN sidecar for your arr-stack. Uses ExpressVPN's **Lightway protocol** for maximum throughput and stability.

## Features

- 🚀 **Lightway UDP** protocol by default — fastest available VPN protocol
- 🔒 **Kill-switch** — iptables drops all forwarded traffic if VPN disconnects
- 🔄 **Auto-reconnect** — watchdog loop detects drops and reconnects
- 🏥 **Health endpoint** — HTTP health check on port 8999 with Docker `service_healthy` support
- 🌐 **Network gateway** — all attached containers route through VPN via `network_mode: service:expressvpn`
- 🪶 **Lightweight** — `debian:bookworm-slim` base, minimal runtime dependencies

---

## Quick Start

### 1. Get Your Activation Code & Installer

1. Login at [expressvpn.com/setup#manual](https://www.expressvpn.com/setup#manual)
2. Copy your **Activation Code**
3. Navigate to **Download App -> Linux** and download the Universal Installer (`.run` file)
4. Rename the downloaded file to `expressvpn.run` and place it in the `releases/` folder within this project:
   ```bash
   mkdir -p releases
   mv ~/Downloads/expressvpn_*_amd64.run releases/expressvpn.run
   ```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env and set ACTIVATION_CODE=your_code_here
```

### 3. Build and Start

```bash
docker compose up -d --build
```

Watch the VPN connect:
```bash
docker compose logs -f expressvpn
```

### 4. Verify VPN is Working

```bash
# Check your real IP
curl ifconfig.me

# Check the IP being used by qBittorrent (should be an ExpressVPN exit IP)
docker compose exec qbittorrent curl -s https://ifconfig.me
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ACTIVATION_CODE` | *(required)* | ExpressVPN activation code from expressvpn.com/setup#manual |
| `SERVER` | `smart` | Server to connect to. See [server options](#server-options) |
| `PREFERRED_PROTOCOL` | `lightway_udp` | VPN protocol. See [protocol options](#protocol-options) |
| `LIGHTWAY_CIPHER` | `auto` | Cipher for Lightway. `auto`, `aes256`, or `chacha20` |
| `FIREWALL_OUTBOUND_SUBNETS` | `192.168.90.0/24` | Comma-separated LANs that bypass the kill-switch |
| `RECONNECT_DELAY` | `30` | Seconds between watchdog reconnect checks |
| `TZ` | `America/New_York` | Timezone |

### Protocol Options

| Protocol | Speed | Use When |
|----------|-------|----------|
| `lightway_udp` | ⚡⚡⚡ Fastest | Default — best for most connections |
| `lightway_tcp` | ⚡⚡ Fast | Restrictive networks, firewalls |
| `auto` | ⚡⚡ | ExpressVPN auto-selects |

### Server Options

```bash
# List all available servers (run after container is running)
docker compose exec expressvpn expressvpn list all

# Example values for SERVER:
# smart                     (auto-select best server)
# "USA - New York"
# "USA - New Jersey"
# "USA - Washington DC"
```

---

## Port Forwarding & qBittorrent Performance

> **⚠️ ExpressVPN does NOT support port forwarding.** This is a hard limitation of ExpressVPN's server infrastructure — their servers do not allow inbound port forwarding from the internet. This applies to their OpenVPN, Lightway, and all other protocols.

### What This Means for qBittorrent

Without port forwarding, other peers cannot initiate connections **to you** — you're in "unconnectable" mode for that direction. However, you **can still connect outbound** to other peers, which means:

- ✅ You will still download at full speed
- ✅ You will still seed to peers you connect to outbound
- ⚠️ Peers behind NAT without port forwarding cannot connect to you first
- ⚠️ Some private trackers may penalise unconnectable peers

### Maximise Performance Without Port Forwarding

Apply these settings in **qBittorrent → Options → BitTorrent**:

| Setting | Recommended Value | Why |
|---------|------------------|-----|
| **Global max connections** | 500 | More peers = more upload paths |
| **Max connections per torrent** | 200 | Saturate the swarm |
| **Global upload slots** | 40 | Allow more simultaneous uploads |
| **DHT** | ✅ Enabled | Finds peers without tracker |
| **Peer Exchange (PEX)** | ✅ Enabled | Discovers peers from other peers |
| **Local Peer Discovery** | ✅ Enabled | Finds LAN peers (fast, unmetered) |
| **Encryption mode** | Allow encryption | Broader peer compatibility |
| **Seeding ratio limit** | 2.0+ | Improves tracker reputation |

In **qBittorrent → Options → Connection**:
- Set **Listening port** to `6881` (matches the docker-compose port mapping)
- Enable **UPnP / NAT-PMP** off (irrelevant through VPN)

### If Port Forwarding is Critical

If you specifically need port forwarding (e.g., you're on private trackers that require it), consider these alternatives that DO support it:

- **AirVPN** — full port forwarding, WireGuard support
- **Mullvad** — port forwarding support (check current status; they've adjusted this)
- **Private Internet Access (PIA)** — built-in port forwarding, works with gluetun

These can be used with gluetun in the same docker-compose structure.

---

## Health Check

The container exposes an HTTP health endpoint:

```bash
curl http://localhost:8999
# → "connected"   (HTTP 200) = healthy
# → "disconnected" (HTTP 503) = unhealthy / reconnecting
```

All arr containers use `condition: service_healthy` — they will not start until the VPN is fully connected.

---

## Kill Switch

By design, if the VPN drops, **all forwarded traffic is immediately blocked** by iptables. This prevents IP leaks from qBittorrent or any other service.

The kill-switch is restored on reconnect via the watchdog. To test it manually:

```bash
# Disconnect VPN inside the container
docker compose exec expressvpn expressvpn disconnect

# Try to reach the internet from qBittorrent (should be blocked)
docker compose exec qbittorrent curl --max-time 5 https://ifconfig.me
# Expected: curl: (28) Connection timed out

# VPN will auto-reconnect within RECONNECT_DELAY seconds
```

---

## Project Structure

```
expressvpn/
├── Dockerfile              # Multi-stage build — debian-slim base
├── docker-compose.yml      # Full arr-stack (replaces gluetun)
├── .env.example            # Environment variable template
├── README.md               # This file
└── scripts/
    ├── entrypoint.sh       # Main startup: activate, connect, iptables, watchdog
    ├── activate.exp        # Expect script for non-interactive activation
    └── healthcheck.sh      # Docker HEALTHCHECK script
```

---

## Updating ExpressVPN

To upgrade to a new ExpressVPN release, change `APP_VERSION` in `docker-compose.yml`:

```yaml
build:
  args:
    APP_VERSION: "3.70.0.0-1"  # Check expressvpn.com for latest
```

Then rebuild:
```bash
docker compose build expressvpn
docker compose up -d expressvpn
```

---

## Credits

- Inspired by [polkaned/dockerfiles](https://github.com/polkaned/dockerfiles/tree/master/expressvpn)
- Architecture modelled after [gluetun](https://github.com/qdm12/gluetun)
