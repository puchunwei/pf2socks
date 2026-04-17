# Architecture

## Why macOS transparent proxy is hard

### Problem 1: pf rdr doesn't intercept local outbound

On Linux, iptables `nat OUTPUT` chain catches locally-originated packets before they leave the host. On macOS, pf `rdr` is designed for **forwarded traffic only** — local outbound packets never trigger `rdr`.

Experimental proof: load `rdr pass proto tcp from any to 34.117.59.81 -> 127.0.0.1 port 26662` and make a curl request. `pfctl -s state` shows a direct connection to 34.117.59.81, no redirect.

### Problem 2: Proxy tools can't get the original destination

After pf rdr succeeds, the original destination is stored in pf's NAT state table. Linux proxy tools use `SO_ORIGINAL_DST` getsockopt, which doesn't exist on macOS. macOS requires `DIOCNATLOOK` ioctl on `/dev/pf`, which xray/v2ray don't implement.

```
xray dokodemo-door on macOS: "proxy/dokodemo: unable to get destination"
```

## pf2socks solves both

### Solution to Problem 1: `route-to` + `rdr on lo0`

Force outbound packets through the loopback interface using `route-to`, then catch them on `lo0` where rdr works:

```pf
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp from any to any keep state
rdr pass on lo0 proto tcp from any to any -> 127.0.0.1 port 26662
```

Critical: `route-to` rule **must** use `quick`, otherwise a later catch-all `pass out quick keep state` overrides it.

### Solution to Problem 2: DIOCNATLOOK in Go

pf2socks implements `DIOCNATLOOK` directly:

```go
const DIOCNATLOOK = 0xc0544417  // _IOWR('D', 23, struct pfioc_natlook), 84 bytes

type pfiocNatlook struct {
    saddr, daddr, rsaddr, rdaddr [16]byte
    sxport, dxport, rsxport, rdxport [4]byte  // union pf_state_xport
    af, proto, protoVar, direction uint8
}

// direction = PF_OUT (2) — crucial! Not PF_IN.
```

The `PF_OUT` direction is the one that matches mitmproxy's implementation on macOS, not the intuitive `PF_IN`.

## Loop prevention via `user` filter

When xray routes some traffic as `direct`, its outbound is caught by pf again → infinite loop.

macOS pf supports `user <name>` in **filter rules** (not rdr rules). Run xray as dedicated `_xray` user:

```pf
# xray's outbound bypasses route-to
pass out quick proto tcp user _xray keep state

# normal traffic goes through transparent proxy
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp from any to any keep state
```

## DNS behavior

### Transparent proxy path (app → pf → pf2socks → xray)

```
① App does local DNS query (UDP 53)   ← LEAKS: pf doesn't intercept UDP
② App gets IP (possibly polluted)
③ App connects to IP via TCP
④ pf redirects TCP → pf2socks
⑤ pf2socks sniffs TLS SNI → domain
⑥ pf2socks SOCKS5 → xray (carries IP)
⑦ xray sniffs TLS SNI → domain
⑧ xray routes by domain → proxy
⑨ Proxy server resolves domain → real IP
```

### Explicit HTTP proxy path (app with http_proxy env var)

```
① App sends: CONNECT google.com:443 HTTP/1.1   ← No local DNS
② xray receives domain directly
③ xray routes by domain → proxy
④ Proxy server resolves domain
```

**Explicit HTTP proxy (via xray's 28881) has zero DNS leakage.** Transparent proxy via pf2socks does leak DNS at step ①. xray's SNI sniffing corrects the routing decision but the DNS query itself is still observable locally.

## Verified technical facts

From implementation and testing:

| Fact | Value |
|------|-------|
| `DIOCNATLOOK` ioctl number | `0xc0544417` |
| `pfioc_natlook` struct size | 84 bytes |
| Correct direction for rdr state lookup | `PF_OUT` (2), not `PF_IN` (1) |
| `/dev/pf` open mode | `O_RDWR` (not `O_RDONLY`) |
| Does pf rdr catch local outbound? | **No**, needs `route-to` first |
| Does rdr need `on lo0` interface? | Yes, to catch route-to'd packets |
| Can xray dokodemo-door work on macOS? | **No**, `unable to get destination` |
| Does xray support `user` match for pf? | pf supports it (not xray), used in filter rules |
| SOCKS5 overhead | ~25 bytes handshake, no encryption |
| xray sniffing preserves domain-based routing? | Yes, via TLS SNI / HTTP Host |

## Further reading

- [pf.conf(5) man page](https://www.freebsd.org/cgi/man.cgi?query=pf.conf) — pf rule syntax
- [xray routing docs](https://xtls.github.io/config/routing.html) — xray routing rules
- [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928) — SOCKS5 protocol
- [XNU pfvar.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pfvar.h) — kernel struct definitions
