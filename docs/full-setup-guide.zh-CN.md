# 完整部署指南 — pf2socks + xray 专用用户方案

在 macOS 上搭一套完整、无回环的透明代理：pf2socks 做 pf 到 SOCKS5 的桥接，xray 做代理引擎和分流。

**语言**: [English](full-setup-guide.md) | 中文

## 架构图

```
┌──────────────┐
│   应用程序    │  （任意进程，无需配置代理）
└──────┬───────┘
       │ TCP 到任意目标
       ▼
┌──────────────────────────────┐
│ pf（macOS 防火墙）            │
│  • route-to lo0              │
│  • rdr on lo0 到 :26662      │
│  • user _xray → 直接放行     │  ← 防回环关键
└──────┬───────────────────────┘
       │
       ▼
┌──────────────┐
│ pf2socks     │  （root，LaunchDaemon）
│  • DIOCNATLOOK 查原始目标
│  • TLS SNI 嗅探
│  • SOCKS5 连到 xray
└──────┬───────┘
       │ SOCKS5 on 127.0.0.1:28880
       ▼
┌──────────────┐
│ xray         │  （用户：_xray，LaunchDaemon）
│  • sniffing  → 域名
│  • routing   → proxy/direct/blocked
└──────┬───────┘
       │
       ├──→ proxy（VLESS 到上游代理）→ 目标
       └──→ direct（freedom）→ 目标 ← 被 user _xray 过滤，不会被 pf 抓回
```

## 为什么需要专用用户

不用专用用户时，xray 的 `direct` 出站会被 pf 再抓回来：

```
应用 → pf → pf2socks → xray → direct → 目标 IP
                                    ↓
                               pf 看到出站 → route-to lo0 → 死循环！
```

macOS 的 pf 过滤规则支持 `user` 关键字。让 xray 以 `_xray` 用户运行，就能在过滤层跳过它的流量：

```pf
pass out quick proto tcp user _xray keep state  # xray 的出站不走 route-to
```

## 前置条件

- macOS（Darwin），Apple Silicon 或 Intel
- Go 1.18+（用来编译 pf2socks）
- 通过 Homebrew 安装的 xray（`brew install xray`）

## 部署步骤

### 1. 配置 xray

编辑 `/opt/homebrew/etc/xray/config.json`，配置 SOCKS5/HTTP 入站、VLESS 出站和路由规则。最小示例：

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
      "settings": { /* 你的 VLESS 配置 */ }
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

### 2. 让 xray 以专用 `_xray` 用户运行

用脚本一键搞定：

```bash
sudo bash scripts/setup-xray-dedicated-user.sh
```

脚本会：

- 创建 `_xray` 用户（UID 399）和用户组（GID 420）
- 修改 xray 配置文件权限（`root:_xray 640`）
- 停掉 brew 管理的 xray 服务
- 安装 `/Library/LaunchDaemons/io.xray.xray.plist`，用 `_xray` 用户启动 xray
- 启动新服务

### 3. 安装 pf2socks

```bash
sudo bash install.sh 127.0.0.1:26662 127.0.0.1:28880
```

会安装：

- `/usr/local/bin/pf2socks`
- `/usr/local/bin/tproxy`（控制脚本）
- `/Library/LaunchDaemons/io.pf2socks.pf2socks.plist`
- `/usr/local/etc/pf2socks/pf.conf.example`

### 4. 配置 pf 规则

拷贝示例文件，根据实际环境修改：

```bash
sudo cp /usr/local/etc/pf2socks/pf.conf.example /usr/local/etc/pf2socks/pf.conf
sudo vim /usr/local/etc/pf2socks/pf.conf
```

需要修改：

- `proxy_server` — 你的 VLESS 上游服务器 IP
- `skip_nets` — 本地网段、VPN 网段
- 网络接口名 — 把 `en0` 换成你机器上的实际接口（可以多个）

如果配了专用用户，用 `pf-transparent-user.conf.example`（带 `user _xray` 过滤）。

### 5. 启用

```bash
sudo tproxy on
```

### 6. 验证

```bash
# 应返回代理出口 IP
curl https://ipinfo.io/ip

# 国内直连也能走
curl https://www.baidu.com

# 看状态
tproxy status
```

## 日常使用

```bash
sudo tproxy on       # 开启透明代理
sudo tproxy off      # 关闭 pf（pf2socks 继续运行）
tproxy status        # 当前状态
tproxy log           # 实时 pf2socks 日志
sudo tproxy restart  # 重启 pf2socks
```

## 回滚

```bash
sudo tproxy off                                       # 关 pf
sudo bash install.sh uninstall                        # 卸载 pf2socks
sudo bash scripts/setup-xray-dedicated-user.sh undo   # xray 恢复到 brew 管理
```

## 常见问题

### Q：透明代理开了以后访问不了某些国内网站？

A：检查 `skip_nets` 是否包含了你的 VPN/内网网段。如果有企业 VPN（如阿里郎），可能需要加 `11.0.0.0/8`、`30.0.0.0/8`、`203.119.0.0/16` 等特殊网段。

### Q：浏览器能访问国外网站但命令行工具（如 curl）不行？

A：这种情况通常是 macOS curl 用了 SecureTransport，对 TLS 的处理比较特殊。确认 pf 规则对**所有** TCP 都生效（不只是 443）。

### Q：xray 重启后代理失效？

A：重启后 pf 规则不会自动加载（故意如此，安全起见）。用 `sudo tproxy on` 重新启用。如果要开机自动开启，可以自己加个 LaunchDaemon 调用 `tproxy on`。

### Q：延迟变高了？

A：透明代理路径多了 pf → pf2socks → xray 三跳，但都是本地处理，额外延迟小于 1ms。实际延迟主要来自上游代理服务器。如果感觉慢，检查是不是 DNS 查询变慢了（透明代理模式下 DNS 还是系统解析）。

### Q：HTTP/3 / QUIC 网站不走代理？

A：对，pf2socks 只代理 TCP。HTTP/3 走 UDP 443，目前会直连。临时解决：浏览器禁用 QUIC/HTTP/3（Chrome `chrome://flags`）。
