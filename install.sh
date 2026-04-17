#!/bin/bash
# pf2socks 一键安装脚本
# - 编译 pf2socks 到 /usr/local/bin
# - 安装 LaunchDaemon，开机自启
# - 安装 tproxy 控制脚本（admin 组免密）
# - 生成示例 pf 规则
# - 配置 sudoers 使 admin 组免密使用 tproxy
#
# 使用:
#   sudo bash install.sh               # 默认参数安装
#   sudo bash install.sh <listen> <socks5>  # 自定义
#   sudo bash install.sh uninstall     # 卸载

set -e

# 默认配置
DEFAULT_LISTEN="127.0.0.1:26662"
DEFAULT_SOCKS5="127.0.0.1:1080"

INSTALL_BIN="/usr/local/bin/pf2socks"
INSTALL_CTL="/usr/local/bin/tproxy"
INSTALL_CONF_DIR="/usr/local/etc/pf2socks"
LAUNCHD_PLIST="/Library/LaunchDaemons/io.pf2socks.pf2socks.plist"
LAUNCHD_LABEL="io.pf2socks.pf2socks"
LOG_DIR="/var/log/pf2socks"
SUDOERS_FILE="/etc/sudoers.d/pf2socks"

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请用 sudo 运行: sudo bash $0 $*"
        exit 1
    fi
}

check_deps() {
    command -v go >/dev/null 2>&1 || { echo "❌ 需要 Go (brew install go)"; exit 1; }
    command -v pfctl >/dev/null 2>&1 || { echo "❌ 需要 pfctl (macOS 自带)"; exit 1; }
}

build_binary() {
    echo "=== 编译 pf2socks ==="
    local src_dir="$(cd "$(dirname "$0")" && pwd)"
    cd "$src_dir"
    go build -o "$INSTALL_BIN" .
    chmod 755 "$INSTALL_BIN"
    echo "已安装: $INSTALL_BIN"
}

install_plist() {
    local listen="$1"
    local socks5="$2"
    echo ""
    echo "=== 安装 LaunchDaemon ==="

    mkdir -p "$LOG_DIR"

    cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHD_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_BIN}</string>
        <string>${listen}</string>
        <string>${socks5}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$LAUNCHD_PLIST"
    chmod 644 "$LAUNCHD_PLIST"
    echo "已安装: $LAUNCHD_PLIST"
}

install_conf_example() {
    echo ""
    echo "=== 生成示例 pf 规则 ==="
    mkdir -p "$INSTALL_CONF_DIR"
    local tproxy_port="${LISTEN##*:}"

    cat > "${INSTALL_CONF_DIR}/pf.conf.example" <<EOF
# pf2socks 示例 pf 规则
# 使用前复制为 pf.conf，按你的环境修改变量

# --- 变量 ---
proxy_server = "YOUR_PROXY_SERVER_IP"  # 必填：你的 SOCKS5 代理上游服务器 IP
tproxy_port = "${tproxy_port}"

# 不代理的网段（本地、私网、组播）
skip_nets = "{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, \
              100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255/32 }"

# --- rdr 规则（lo0 上重定向）---
no rdr on lo0 proto tcp from any to 127.0.0.1
no rdr on lo0 proto tcp from any to \$proxy_server
no rdr on lo0 proto tcp from any to \$skip_nets
rdr pass on lo0 proto tcp from any to any -> 127.0.0.1 port \$tproxy_port

# --- filter 规则 ---
# 可选：如果 SOCKS5 代理以专用用户运行，加一行：
#   pass out quick proto tcp user _xray keep state
pass out quick proto tcp from any to \$proxy_server keep state
pass out quick proto tcp from any to \$skip_nets keep state
pass out quick on lo0 keep state
# 替换 en0 为你的实际网络接口（可多个：en0、en18 等）
pass out quick on en0 route-to (lo0 127.0.0.1) proto tcp from any to any keep state
pass out quick keep state
EOF
    echo "示例: ${INSTALL_CONF_DIR}/pf.conf.example"
}

install_tproxy_ctl() {
    echo ""
    echo "=== 安装 tproxy 控制脚本 ==="
    cat > "$INSTALL_CTL" <<'CTL'
#!/bin/bash
# tproxy - pf2socks 透明代理开关控制
# 自动检测权限，必要时通过 sudo 提权（配合 /etc/sudoers.d/pf2socks 免密）

PF_CONF="/usr/local/etc/pf2socks/pf.conf"
DAEMON_LABEL="io.pf2socks.pf2socks"

# 自动提权：如果不是 root，重新用 sudo 执行自己
# 配合 sudoers NOPASSWD，admin 用户无需输入密码
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

case "$1" in
    on)
        if [ ! -f "$PF_CONF" ]; then
            echo "❌ $PF_CONF 不存在，请先根据示例创建"
            echo "   示例：/usr/local/etc/pf2socks/pf.conf.example"
            exit 1
        fi
        if ! launchctl list | grep -q "$DAEMON_LABEL"; then
            launchctl load "/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
            sleep 1
        fi
        pfctl -nf "$PF_CONF" > /dev/null 2>&1 || { echo "❌ pf 规则语法错误"; exit 1; }
        pfctl -f "$PF_CONF" 2>&1 | grep -v "^No ALTQ\|^ALTQ"
        pfctl -e 2>&1 | grep -v "^No ALTQ\|^ALTQ"
        echo "✅ 透明代理已开启"
        ;;
    off)
        pfctl -d 2>&1 | grep -v "^No ALTQ\|^ALTQ"
        echo "✅ pf 已关闭（pf2socks 仍运行）"
        ;;
    status)
        echo "=== pf ==="
        pfctl -s info 2>/dev/null | head -3
        echo ""
        echo "=== pf2socks ==="
        if launchctl list | grep -q "$DAEMON_LABEL"; then
            pgrep -l pf2socks || echo "未运行"
        else
            echo "Daemon 未加载"
        fi
        echo ""
        echo "=== 出口 IP ==="
        curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null || echo "请求失败"
        ;;
    restart)
        launchctl kickstart -k "system/$DAEMON_LABEL"
        echo "✅ pf2socks 已重启"
        ;;
    log)
        tail -f /var/log/pf2socks/stderr.log
        ;;
    *)
        echo "用法: tproxy {on|off|status|restart|log}"
        echo ""
        echo "  on       - 启用透明代理（加载 pf 规则）"
        echo "  off      - 关闭 pf（保持 pf2socks 运行）"
        echo "  status   - 查看状态"
        echo "  restart  - 重启 pf2socks"
        echo "  log      - 查看 pf2socks 实时日志"
        exit 1
        ;;
esac
CTL
    chmod 755 "$INSTALL_CTL"
    echo "已安装: $INSTALL_CTL"
}

install_sudoers() {
    echo ""
    echo "=== 配置 sudoers（admin 组免密）==="

    # 写到临时文件先 visudo -c 校验，通过后再移动
    local tmp_file="$(mktemp)"
    cat > "$tmp_file" <<'SUDOERS'
# pf2socks - 允许 admin 组免密使用 tproxy 控制脚本
# macOS 的所有"管理员用户"默认都在 admin 组
%admin ALL = (root) NOPASSWD: /usr/local/bin/tproxy
SUDOERS

    # 校验语法
    if ! visudo -cf "$tmp_file" >/dev/null 2>&1; then
        echo "❌ sudoers 语法校验失败，跳过安装"
        rm -f "$tmp_file"
        return 1
    fi

    # 移到目标位置（权限必须 440）
    install -m 440 -o root -g wheel "$tmp_file" "$SUDOERS_FILE"
    rm -f "$tmp_file"
    echo "已安装: $SUDOERS_FILE"
    echo "(admin 组用户执行 tproxy 时无需输入密码)"
}

start_daemon() {
    echo ""
    echo "=== 启动 pf2socks Daemon ==="
    if launchctl list | grep -q "$LAUNCHD_LABEL"; then
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    fi
    launchctl load "$LAUNCHD_PLIST"
    sleep 1

    if launchctl list | grep -q "$LAUNCHD_LABEL"; then
        echo "✅ pf2socks 已启动"
    else
        echo "❌ pf2socks 启动失败，检查日志: $LOG_DIR/stderr.log"
        exit 1
    fi
}

uninstall() {
    echo "=== 卸载 pf2socks ==="

    # 1. 关闭 pf（如果是开启状态）
    pfctl -d 2>/dev/null || true

    # 2. 停止 LaunchDaemon
    if [ -f "$LAUNCHD_PLIST" ]; then
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    fi

    # 3. 删除文件
    rm -f "$LAUNCHD_PLIST" "$INSTALL_BIN" "$INSTALL_CTL" "$SUDOERS_FILE"

    echo "已删除:"
    echo "  - $INSTALL_BIN"
    echo "  - $INSTALL_CTL"
    echo "  - $LAUNCHD_PLIST"
    echo "  - $SUDOERS_FILE"
    echo ""
    echo "保留（可手动删除）:"
    echo "  - $INSTALL_CONF_DIR (配置)"
    echo "  - $LOG_DIR (日志)"
    echo ""
    echo "✅ pf2socks 卸载完成"
    echo ""
    echo "=== 其他清理（如之前配置了 xray 专用用户）==="
    echo "  sudo bash scripts/setup-xray-dedicated-user.sh undo"
    echo "  这会恢复 xray 到 brew services 管理"
    echo ""
    echo "=== 完全卸载（一键）==="
    echo "  sudo bash scripts/uninstall-all.sh"
    echo "  会同时卸载 pf2socks 和恢复 xray"
}

# ========== main ==========

if [ "$1" = "uninstall" ] || [ "$1" = "remove" ]; then
    need_root
    uninstall
    exit 0
fi

LISTEN="${1:-$DEFAULT_LISTEN}"
SOCKS5="${2:-$DEFAULT_SOCKS5}"

need_root
check_deps
build_binary
install_plist "$LISTEN" "$SOCKS5"
install_conf_example
install_tproxy_ctl
install_sudoers
start_daemon

echo ""
echo "=============================================="
echo "  pf2socks 安装完成"
echo "=============================================="
echo ""
echo "监听: $LISTEN"
echo "SOCKS5 上游: $SOCKS5"
echo ""
echo "下一步:"
echo "  1. 编辑 pf 规则: sudo cp ${INSTALL_CONF_DIR}/pf.conf.example ${INSTALL_CONF_DIR}/pf.conf"
echo "     并根据你的环境修改 proxy_server 等变量"
echo ""
echo "  2. 开启透明代理: tproxy on    (admin 用户免密)"
echo ""
echo "  3. 其他命令:"
echo "     tproxy off      - 关闭 pf"
echo "     tproxy status   - 查看状态"
echo "     tproxy restart  - 重启 pf2socks"
echo "     tproxy log      - 实时日志"
echo ""
echo "卸载: sudo bash install.sh uninstall"
