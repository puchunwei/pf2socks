# pf2socks

**Transparent proxy helper for macOS** — translates pf rdr to SOCKS5, the macOS equivalent of [ipt2socks](https://github.com/zfl9/ipt2socks).

## The Problem

Setting up transparent proxy on macOS is hard because:

1. **pf `rdr` doesn't intercept locally-originated traffic** — unlike Linux iptables, macOS pf redirect rules only apply to forwarded packets, not outbound packets from the host itself.
2. **Proxy tools (xray, v2ray, etc.) can't get the original destination after pf rdr on macOS** — they rely on `SO_ORIGINAL_DST` which only works on Linux. macOS requires `DIOCNATLOOK` ioctl on `/dev/pf`, which most proxy tools don't implement.

## The Solution

pf2socks solves both problems:

1. Uses **`route-to` + `rdr on lo0`** pf rules to intercept local outbound traffic
2. Queries the **original destination** via `DIOCNATLOOK` ioctl
3. Forwards the connection to any **SOCKS5 proxy** (xray, v2ray, clash, etc.)

```
App → pf route-to lo0 → rdr on lo0 → pf2socks → SOCKS5 proxy → target
```

## Quick Start

### Build

```bash
go build -o pf2socks
```

### Run

```bash
# pf2socks [listen_addr] [socks5_addr]
sudo ./pf2socks 127.0.0.1:1234 127.0.0.1:1080
```

Requires root (reads `/dev/pf`).

### Configure pf

Copy and edit the example pf rules:

```bash
cp pf/pf-transparent.conf.example pf/pf-transparent.conf
# Edit: set proxy_server IP, adjust interfaces (en0, en1, etc.)
vim pf/pf-transparent.conf
```

Load and enable:

```bash
sudo pfctl -f pf/pf-transparent.conf && sudo pfctl -e
```

### Test

```bash
# Should return your proxy IP, not your local IP
curl https://ipinfo.io/ip
```

### Emergency Recovery

```bash
sudo pfctl -d    # Disable pf, restore all networking immediately
```

## How It Works

### Why `route-to` is needed

macOS pf `rdr` only processes packets arriving on an interface (inbound). Locally-originated packets go outbound, so `rdr` never sees them. The `route-to` rule on the outbound path forces packets through `lo0`, where `rdr on lo0` can intercept them.

```
Without route-to:  app → en0 (outbound) → rdr doesn't fire → direct connection
With route-to:     app → en0 (outbound) → route-to lo0 → rdr on lo0 fires → pf2socks
```

### DIOCNATLOOK

After pf redirects a connection, the original destination is stored in pf's NAT state table. pf2socks queries it via `DIOCNATLOOK` ioctl:

- **ioctl number**: `0xc0544417` (`_IOWR('D', 23, struct pfioc_natlook)`, 84 bytes)
- **direction**: `PF_OUT` (2)
- **file**: `/dev/pf` opened with `O_RDWR`

### Key pf rule: `quick` matters

The `route-to` rule **must** have the `quick` keyword, otherwise a later `pass out quick keep state` rule takes precedence and bypasses the route-to.

```pf
# WRONG: route-to without quick, gets overridden
pass out on en0 route-to (lo0 127.0.0.1) proto tcp ...
pass out quick keep state  # ← this wins

# CORRECT: route-to with quick
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp ...
pass out quick keep state
```

## Known Limitations

- **TCP only** — UDP transparent proxy is not yet supported
- **IPv4 only** — IPv6 support is planned
- **Loop prevention** — If your SOCKS5 proxy has direct-connect rules, its outbound traffic will be caught by pf again. Solutions:
  - Run proxy + pf2socks as a dedicated user, exclude with `pass out quick proto tcp user _proxy keep state`
  - Or exclude the proxy server IP in pf rules (only works for the proxy upstream, not direct traffic)

## Compared to Alternatives

| Approach | macOS Support | Needs TUN | Loop-free |
|----------|:---:|:---:|:---:|
| TUN mode (clash, sing-box) | ✅ | Yes — conflicts with VPN | ✅ |
| iptables + ipt2socks | ❌ Linux only | No | ✅ (uid match) |
| **pf + pf2socks** | **✅** | **No** | Needs dedicated user |

## License

MIT
