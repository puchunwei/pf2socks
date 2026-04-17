# Full Setup Guide — pf2socks + xray with Dedicated User

A complete, loop-free macOS transparent proxy stack using pf2socks as the pf-to-SOCKS5 bridge and xray as the proxy engine.

## Architecture

```
┌──────────────┐
│ Application  │  (any process, no proxy config)
└──────┬───────┘
       │ TCP to any destination
       ▼
┌──────────────────────────────┐
│ pf (macOS firewall)          │
│  • route-to lo0              │
│  • rdr on lo0 to :26662      │
│  • user _xray → bypass       │  ← prevents loop
└──────┬───────────────────────┘
       │
       ▼
┌──────────────┐
│ pf2socks     │  (root, LaunchDaemon)
│  • DIOCNATLOOK → original dst
│  • TLS SNI sniffing
│  • SOCKS5 CONNECT to xray
└──────┬───────┘
       │ SOCKS5 on 127.0.0.1:28880
       ▼
┌──────────────┐
│ xray         │  (user: _xray, LaunchDaemon)
│  • sniffing  → domain
│  • routing   → proxy/direct/blocked
└──────┬───────┘
       │
       ├──→ proxy (VLESS to upstream) → target
       └──→ direct (freedom) → target  ← not caught by pf (user _xray filter)
```

## Why dedicated user

Without it, the `direct` outbound from xray would be caught by pf again:

```
app → pf → pf2socks → xray → direct → target IP
                                   ↓
                              pf sees outbound → route-to lo0 → LOOP!
```

macOS pf filter rules support the `user` keyword. Running xray as `_xray` lets us bypass its traffic:

```pf
pass out quick proto tcp user _xray keep state  # xray's outbound bypasses route-to
```

## Prerequisites

- macOS (Darwin), Apple Silicon or Intel
- Go 1.18+ (for building pf2socks)
- xray installed via Homebrew (`brew install xray`)

## Setup Steps

### 1. Configure xray

Edit `/opt/homebrew/etc/xray/config.json` with your SOCKS5 and HTTP inbounds, VLESS outbound, and routing rules. Minimal example:

```json
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": 28880,
      "settings": { "auth": "noauth", "udp": true },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "tag": "http-in",
      "protocol": "http",
      "listen": "127.0.0.1",
      "port": 28881,
      "settings": { "allowTransparent": false },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": { /* your VLESS config */ }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "blocked" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "port": "0-65535", "outboundTag": "proxy" }
    ]
  }
}
```

### 2. Run xray as dedicated `_xray` user

Use the provided script:

```bash
sudo bash scripts/setup-xray-dedicated-user.sh
```

This will:
- Create `_xray` user (UID 399) and group (GID 420)
- Set xray config permissions (`root:_xray 640`)
- Stop brew-managed xray service
- Install `/Library/LaunchDaemons/io.xray.xray.plist` running xray as `_xray`
- Start the new service

### 3. Install pf2socks

```bash
sudo bash install.sh 127.0.0.1:26662 127.0.0.1:28880
```

This installs:
- `/usr/local/bin/pf2socks`
- `/usr/local/bin/tproxy` (control script)
- `/Library/LaunchDaemons/io.pf2socks.pf2socks.plist`
- `/usr/local/etc/pf2socks/pf.conf.example`

### 4. Configure pf rules

Copy the example and customize for your network:

```bash
sudo cp /usr/local/etc/pf2socks/pf.conf.example /usr/local/etc/pf2socks/pf.conf
sudo vim /usr/local/etc/pf2socks/pf.conf
```

Adjust:
- `proxy_server` — your VLESS upstream IP
- `skip_nets` — local networks, VPN ranges
- Network interfaces — replace `en0` with your actual interface(s)

Use `pf-transparent-user.conf.example` if you set up the dedicated `_xray` user.

### 5. Enable

```bash
sudo tproxy on
```

### 6. Verify

```bash
# Should return your proxy IP, not your local IP
curl https://ipinfo.io/ip

# Direct routing still works
curl https://www.baidu.com

# Check status
tproxy status
```

## Daily Usage

```bash
sudo tproxy on       # Enable transparent proxy
sudo tproxy off      # Disable pf (keep pf2socks running)
tproxy status        # Show current state
tproxy log           # Tail pf2socks logs
sudo tproxy restart  # Restart pf2socks
```

## Rollback

```bash
sudo tproxy off                                       # Disable pf
sudo bash install.sh uninstall                        # Uninstall pf2socks
sudo bash scripts/setup-xray-dedicated-user.sh undo   # Revert xray to brew service
```
