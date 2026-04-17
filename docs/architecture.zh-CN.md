# 技术原理

**语言**: [English](architecture.md) | 中文

## 为什么 macOS 透明代理这么难

### 难点 1：pf rdr 不拦截本机出站

Linux 上 iptables 的 `nat OUTPUT` 链能在本机生成的包离开主机前就捕获它们。macOS 的 pf `rdr` 设计上**只处理转发流量**——本机出站包永远不会触发 `rdr`。

实验证据：加载规则 `rdr pass proto tcp from any to 34.117.59.81 -> 127.0.0.1 port 26662`，然后 curl 请求。看 `pfctl -s state` 发现这是一个直连，没有重定向记录。

### 难点 2：代理工具拿不到原始目标地址

pf 重定向成功后，原始目标地址保存在内核的 NAT 状态表里。Linux 的代理工具用 `SO_ORIGINAL_DST` getsockopt 获取——macOS 上没这个。macOS 需要用 `DIOCNATLOOK` ioctl 查 `/dev/pf`，但 xray、v2ray 等都没实现。

```
macOS 上 xray 的 dokodemo-door 错误日志：
"proxy/dokodemo: unable to get destination"
```

## pf2socks 同时解决这两个问题

### 解法 1：`route-to` + `rdr on lo0`

用 `route-to` 把出站包强制绕到回环接口，然后 `lo0` 上的 `rdr` 就能捕获：

```pf
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp from any to any keep state
rdr pass on lo0 proto tcp from any to any -> 127.0.0.1 port 26662
```

**关键细节**：`route-to` 规则**必须**加 `quick`，否则会被后面的 `pass out quick keep state` 覆盖掉。

### 解法 2：Go 实现 DIOCNATLOOK

pf2socks 直接调用 `DIOCNATLOOK` ioctl：

```go
const DIOCNATLOOK = 0xc0544417  // _IOWR('D', 23, struct pfioc_natlook)，84 字节

type pfiocNatlook struct {
    saddr, daddr, rsaddr, rdaddr [16]byte
    sxport, dxport, rsxport, rdxport [4]byte  // union pf_state_xport
    af, proto, protoVar, direction uint8
}

// direction = PF_OUT (2) — 这里很关键！不是 PF_IN
```

`PF_OUT` 方向是 mitmproxy 在 macOS 上用的值，而不是直觉里以为的 `PF_IN`。

## 用 `user` 过滤防回环

如果代理工具（xray）里配了 direct 规则，它的 direct 出站流量会被 pf 再抓一次 → 死循环。

macOS pf 的**过滤规则**（不是 rdr 规则）支持 `user <用户名>`。让 xray 以专用 `_xray` 用户运行：

```pf
# xray 的出站不走 route-to
pass out quick proto tcp user _xray keep state

# 其他流量走透明代理
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp from any to any keep state
```

## DNS 行为

### 透明代理路径（应用 → pf → pf2socks → xray）

```
① 应用本地查 DNS（UDP 53）    ← 泄漏：pf 不拦截 UDP
② 应用拿到 IP（可能被污染）
③ 应用用 TCP 连这个 IP
④ pf 拦截 TCP → pf2socks
⑤ pf2socks 嗅探 TLS SNI → 域名
⑥ pf2socks SOCKS5 → xray（带 IP）
⑦ xray 嗅探 TLS SNI → 域名
⑧ xray 按域名分流 → proxy
⑨ 代理服务器解析域名 → 真实 IP
```

### 显式 HTTP 代理路径（应用配了 http_proxy）

```
① 应用发送：CONNECT google.com:443 HTTP/1.1   ← 没有本地 DNS
② xray 直接拿到域名
③ xray 按域名分流 → proxy
④ 代理服务器解析域名
```

**显式 HTTP 代理（xray 的 28881）零 DNS 泄漏。** 透明代理经 pf2socks 会在步骤 ① 泄漏 DNS。xray 的 SNI 嗅探能纠正路由决策，但 DNS 查询本身还是本地可观察的。

## 已验证的技术细节

来自实际实现和测试：

| 问题 | 结论 |
|------|------|
| `DIOCNATLOOK` 的 ioctl 编号 | `0xc0544417` |
| `pfioc_natlook` 结构体大小 | 84 字节 |
| 查 rdr 状态用哪个 direction？ | `PF_OUT` (2)，不是 `PF_IN` (1) |
| `/dev/pf` 打开模式 | `O_RDWR`（`O_RDONLY` 会 permission denied） |
| pf rdr 能否抓本机出站？ | **不能**，必须配合 `route-to` |
| rdr 是否必须加 `on lo0`？ | 必须，否则捕获不到 route-to 过来的包 |
| xray dokodemo-door 在 macOS 能用吗？ | **不能**，报 `unable to get destination` |
| xray 能用 `user` 做流量匹配吗？ | pf 支持（xray 不支持），用在 filter 规则中 |
| SOCKS5 有多少开销？ | 握手 25 字节，无加密 |
| xray sniffing 能保留域名级分流吗？ | 能，通过 TLS SNI / HTTP Host |

## pf rdr 流程与内核状态

一次完整的流量流转（以 `curl https://ipinfo.io/ip` 为例）：

```
① curl → TCP connect(34.117.59.81:443)
       │
       ▼
② pf 在 en18 出站方向看到：
   • 不是 YOUR_PROXY_IP（上游代理）
   • 不在 skip_nets
   → 匹配 pass out quick on en18 route-to (lo0 127.0.0.1)
       │
       ▼
③ 包被路由到 lo0
       │
       ▼
④ pf 在 lo0 入站方向看到：
   • 匹配 rdr pass on lo0 → 127.0.0.1:26662
   • 内核 NAT 表记录：src=30.158.136.69:xxx, orig_dst=34.117.59.81:443, new_dst=127.0.0.1:26662
       │
       ▼
⑤ pf2socks accept 到连接
   • conn.LocalAddr() = 127.0.0.1:26662
   • conn.RemoteAddr() = 30.158.136.69:xxx
       │
       ▼
⑥ pf2socks 打开 /dev/pf（O_RDWR）
   • 构造 pfioc_natlook：direction=PF_OUT, proto=TCP
   • saddr=30.158.136.69, sport=xxx
   • daddr=127.0.0.1, dport=26662
   • 调用 ioctl(DIOCNATLOOK)
       │
       ▼
⑦ 内核返回：
   • rdaddr=34.117.59.81, rdport=443  ← 这就是原始目标
       │
       ▼
⑧ pf2socks 用 SOCKS5 连 xray(28880)
   • CONNECT 34.117.59.81:443
       │
       ▼
⑨ xray 收到连接，sniff TLS SNI → "ipinfo.io"
   • 域名路由不匹配具体规则
   • IP 34.117.59.81 也不是 geoip:cn 或 geoip:private
   → 走 proxy（VLESS 到上游）
       │
       ▼
⑩ 上游代理出口 → 返回给 curl
```

## 延伸阅读

- [pf.conf(5) 手册](https://www.freebsd.org/cgi/man.cgi?query=pf.conf) — pf 规则语法
- [xray routing 文档](https://xtls.github.io/config/routing.html) — xray 路由规则
- [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928) — SOCKS5 协议
- [XNU pfvar.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pfvar.h) — 内核结构体定义
