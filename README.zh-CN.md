# pf2socks

**macOS 透明代理中转工具** — 把 pf 的流量重定向翻译成 SOCKS5，是 macOS 上缺失的 [ipt2socks](https://github.com/zfl9/ipt2socks) 对应物。

可配合任何 SOCKS5 代理使用：xray、v2ray、sing-box、shadowsocks、clash 等。

**语言**: [English](README.md) | 中文

## 为什么需要它

在 macOS 上搭透明代理一直很麻烦：

1. **pf `rdr` 不拦截本机发出的流量** — 和 Linux iptables 不同，macOS 的 pf 重定向规则只对转发流量生效，本机的出站包根本不经过 `rdr`
2. **代理工具拿不到 pf 重定向前的原始目标地址** — 它们依赖 Linux 独有的 `SO_ORIGINAL_DST`，在 macOS 上要用 `DIOCNATLOOK` ioctl 查 `/dev/pf`，但主流代理工具都没实现

pf2socks 同时解决这两个问题：

- 用 **`route-to` + `rdr on lo0`** 的 pf 规则组合来拦截本机出站
- 通过 **`DIOCNATLOOK`** ioctl 查原始目标地址
- 通过 **SOCKS5** 转发给上游代理

```
应用 → pf route-to lo0 → rdr on lo0 → pf2socks → SOCKS5 代理 → 目标
```

技术原理详见 [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md)。

## 快速开始

### 安装

```bash
git clone https://github.com/puchunwei/pf2socks.git
cd pf2socks
sudo bash install.sh 127.0.0.1:26662 127.0.0.1:1080   # 监听地址 上游SOCKS5
```

安装脚本会创建：

- `/usr/local/bin/pf2socks`（主程序）
- `/usr/local/bin/tproxy`（控制脚本）
- `/Library/LaunchDaemons/io.pf2socks.pf2socks.plist`（开机自启）
- `/usr/local/etc/pf2socks/pf.conf.example`（pf 规则模板）

### 配置 pf 规则

```bash
sudo cp /usr/local/etc/pf2socks/pf.conf.example /usr/local/etc/pf2socks/pf.conf
sudo vim /usr/local/etc/pf2socks/pf.conf
```

需要修改：

- `proxy_server` — 你的上游代理服务器 IP（防止回环）
- 网络接口名 — 把 `en0` 换成你实际的接口

### 开启

```bash
sudo tproxy on
```

### 验证

```bash
curl https://ipinfo.io/ip    # 应返回代理出口 IP，不是本地 IP
tproxy status
```

### 紧急恢复

```bash
sudo pfctl -d    # 关闭 pf，立即恢复所有网络
```

## 日常使用

安装脚本会配置 `sudoers`，让 `admin` 组成员免密使用 `tproxy`（脚本内部自动用 `sudo` 提权）：

```bash
tproxy on       # 开启透明代理
tproxy off      # 关闭 pf（pf2socks 仍运行）
tproxy status   # 查看状态
tproxy log      # 实时看 pf2socks 日志
tproxy restart  # 重启 pf2socks
```

**不需要 `sudo` 前缀**。如果以后想取消免密：

```bash
sudo rm /etc/sudoers.d/pf2socks
```

## 进阶：用专用用户解决回环问题

如果你的 SOCKS5 代理配了**直连规则**（比如 xray 的 `geoip:cn → direct`），它的出站流量会再被 pf 抓回来 → 死循环。

解决方案：用专用用户运行代理，pf 用 `user` 字段过滤：

```bash
sudo bash scripts/setup-xray-dedicated-user.sh    # xray 专用用户
# 然后改用 pf/pf-transparent-user.conf.example
```

完整指南：[docs/full-setup-guide.zh-CN.md](docs/full-setup-guide.zh-CN.md)。

## 工作原理

### 为什么必须用 `route-to`

macOS 的 pf `rdr` 只处理**进入接口的包**（inbound）。本机发出的包是出站方向，`rdr` 完全抓不到。加 `route-to` 把包强制绕到 `lo0`，`rdr on lo0` 才能捕获。

```
不加 route-to：  应用 → en0 出站 → rdr 不触发 → 直连出去
加了 route-to：  应用 → en0 出站 → route-to lo0 → rdr on lo0 触发 → pf2socks
```

### DIOCNATLOOK

pf 重定向后，原始目标地址存在内核的 NAT 状态表里。pf2socks 通过 ioctl 查出来：

- **ioctl 编号**：`0xc0544417`（`_IOWR('D', 23, struct pfioc_natlook)`）
- **方向参数**：`PF_OUT` (2)  ← 关键！不是直觉上的 `PF_IN`
- **打开方式**：`/dev/pf` 用 `O_RDWR`

### `quick` 关键字不能省

`route-to` 规则**必须**带 `quick`，不然后面的 `pass out quick keep state` 会把它覆盖掉：

```pf
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp from any to any keep state
```

## 已知限制

- **只支持 TCP** — UDP 透明代理暂不支持（DNS 查询会走系统解析器）
- **只支持 IPv4** — IPv6 支持计划中
- **代理有直连规则时需要专用用户** 才能防回环

## 和其他方案对比

| 方案 | 支持 macOS | 需要 TUN | 无回环 |
|------|:---:|:---:|:---:|
| TUN 模式（clash、sing-box） | ✅ | 是 — 和 VPN 的 utun 冲突 | ✅ |
| iptables + ipt2socks | ❌ 仅 Linux | 否 | ✅（靠 uid 匹配） |
| **pf + pf2socks** | **✅** | **否** | 是（配合 `user` 过滤） |

## 项目结构

```
pf2socks/
├── main.go                                       # 核心：DIOCNATLOOK + SOCKS5
├── sniff.go                                      # TLS SNI / HTTP Host 嗅探
├── install.sh                                    # 一键安装
├── pf/
│   ├── pf-transparent.conf.example               # 基础 pf 规则
│   └── pf-transparent-user.conf.example          # 带 user 过滤的版本
├── scripts/
│   └── setup-xray-dedicated-user.sh              # xray 专用用户脚本
├── docs/
│   ├── full-setup-guide.md                       # 完整指南
│   ├── full-setup-guide.zh-CN.md                 # 完整指南（中文）
│   ├── architecture.md                           # 技术原理
│   └── architecture.zh-CN.md                     # 技术原理（中文）
├── CHANGELOG.md
└── LICENSE（MIT）
```

## 许可证

MIT
