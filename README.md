# pf2socks

**Transparent proxy helper for macOS** — translates pf rdr to SOCKS5, the macOS equivalent of [ipt2socks](https://github.com/zfl9/ipt2socks).

Works with any SOCKS5 proxy: xray, v2ray, sing-box, shadowsocks, clash, etc.

**Language**: English | [中文](README.zh-CN.md)

## Why

Setting up transparent proxy on macOS is hard because:

1. **pf `rdr` doesn't intercept locally-originated traffic** — unlike Linux iptables, macOS pf redirect rules only apply to forwarded packets, not outbound packets from the host itself.
2. **Proxy tools can't get the original destination after pf rdr on macOS** — they rely on `SO_ORIGINAL_DST` (Linux-only). macOS requires `DIOCNATLOOK` ioctl on `/dev/pf`, which most proxy tools don't implement.

pf2socks solves both:
- Uses **`route-to` + `rdr on lo0`** pf rules to catch local outbound
- Queries the **original destination** via `DIOCNATLOOK` ioctl
- Forwards via **SOCKS5** to any upstream proxy

```
App → pf route-to lo0 → rdr on lo0 → pf2socks → SOCKS5 proxy → target
```

See [docs/architecture.md](docs/architecture.md) for the full technical story.

## Quick Start

### Install

```bash
git clone https://github.com/puchunwei/pf2socks.git
cd pf2socks
sudo bash install.sh 127.0.0.1:26662 127.0.0.1:1080   # listen, upstream socks5
```

The installer creates:
- `/usr/local/bin/pf2socks` (the daemon binary)
- `/usr/local/bin/tproxy` (control script)
- `/Library/LaunchDaemons/io.pf2socks.pf2socks.plist` (auto-start on boot)
- `/usr/local/etc/pf2socks/pf.conf.example` (template pf rules)

### Configure pf rules

```bash
sudo cp /usr/local/etc/pf2socks/pf.conf.example /usr/local/etc/pf2socks/pf.conf
sudo vim /usr/local/etc/pf2socks/pf.conf
```

Edit:
- `proxy_server` — your upstream proxy server IP (to prevent loops)
- Network interfaces — replace `en0` with your actual one(s)

### Enable

```bash
sudo tproxy on
```

### Verify

```bash
curl https://ipinfo.io/ip    # should return your proxy IP
tproxy status
```

### Emergency recovery

```bash
sudo pfctl -d    # disable pf, restore all networking
```

## Daily Usage

The installer configures `sudoers` so members of the `admin` group can use `tproxy` without entering a password (auto-elevation via `sudo` happens internally):

```bash
tproxy on       # enable transparent proxy
tproxy off      # disable pf (pf2socks keeps running)
tproxy status   # current state
tproxy log      # tail pf2socks logs
tproxy restart  # restart pf2socks
```

No `sudo` prefix needed. To remove the no-password privilege later:

```bash
sudo rm /etc/sudoers.d/pf2socks
```

## Uninstall / Restore

### Uninstall pf2socks only

```bash
sudo bash install.sh uninstall
```

Removes:
- `/usr/local/bin/pf2socks`
- `/usr/local/bin/tproxy`
- `/Library/LaunchDaemons/io.pf2socks.pf2socks.plist`
- `/etc/sudoers.d/pf2socks`

Preserved:
- `/usr/local/etc/pf2socks/` (configs — delete manually if you want)
- `/var/log/pf2socks/` (logs — delete manually if you want)

### Full uninstall (pf2socks + xray dedicated user)

```bash
sudo bash scripts/uninstall-all.sh
# or to also delete configs/logs:
sudo bash scripts/uninstall-all.sh --force
```

Does everything:
1. Turns off pf
2. Uninstalls pf2socks
3. Reverts xray to `brew services` (if you had used the dedicated-user setup)
4. Removes the `_xray` user and group

### Revert only the xray dedicated user setup

```bash
sudo bash scripts/setup-xray-dedicated-user.sh undo
```

Keeps pf2socks running, only restores xray to brew-managed.

## Advanced: Loop-free setup with dedicated user

If your SOCKS5 proxy has **direct-connect rules** (e.g. xray with `geoip:cn → direct`), its outbound traffic will be caught by pf again → loop.

Run the proxy as a dedicated user and add a `user` filter in pf:

```bash
sudo bash scripts/setup-xray-dedicated-user.sh    # for xray
# then use pf/pf-transparent-user.conf.example
```

Full guide: [docs/full-setup-guide.md](docs/full-setup-guide.md).

## How It Works

### Why `route-to` is needed

macOS pf `rdr` only processes packets arriving on an interface (inbound). Locally-originated packets go outbound, so `rdr` never sees them. `route-to` forces packets through `lo0`, where `rdr on lo0` catches them.

```
Without route-to:  app → en0 (outbound) → rdr doesn't fire → direct connection
With route-to:     app → en0 (outbound) → route-to lo0 → rdr on lo0 fires → pf2socks
```

### DIOCNATLOOK

After pf redirects a connection, the original destination is stored in pf's NAT state table. pf2socks queries it:

- **ioctl number**: `0xc0544417` (`_IOWR('D', 23, struct pfioc_natlook)`)
- **direction**: `PF_OUT` (2)  ← crucial, not `PF_IN`
- **file**: `/dev/pf` opened `O_RDWR`

### `quick` matters

The `route-to` rule **must** have `quick`, else a later `pass out quick keep state` overrides it:

```pf
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp from any to any keep state
```

## Known Limitations

- **TCP only** — UDP transparent proxy not yet supported (DNS queries leak to system resolver)
- **IPv4 only** — IPv6 support planned
- **Loop prevention requires dedicated user** when proxy has direct-outbound rules

## Compared to Alternatives

| Approach | macOS Support | Needs TUN | Loop-free |
|----------|:---:|:---:|:---:|
| TUN mode (clash, sing-box) | ✅ | Yes — conflicts with VPN | ✅ |
| iptables + ipt2socks | ❌ Linux only | No | ✅ (uid match) |
| **pf + pf2socks** | **✅** | **No** | Yes (with `user` filter) |

## Project Structure

```
pf2socks/
├── main.go                                       # core: DIOCNATLOOK + SOCKS5
├── sniff.go                                      # TLS SNI / HTTP Host sniffing
├── install.sh                                    # one-line installer
├── pf/
│   ├── pf-transparent.conf.example               # basic pf rules
│   └── pf-transparent-user.conf.example          # with user filter
├── scripts/
│   └── setup-xray-dedicated-user.sh              # dedicated user for xray
├── docs/
│   ├── full-setup-guide.md                       # full guide
│   └── architecture.md                           # technical deep dive
├── CHANGELOG.md
└── LICENSE (MIT)
```

## License

MIT
