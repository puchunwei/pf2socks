#!/bin/bash
# 一键完全卸载：pf2socks + xray 专用用户设置，恢复到安装前状态
#
# 会做：
#   1. 关闭 pf 防火墙
#   2. 卸载 pf2socks（daemon、二进制、sudoers、配置、日志可选）
#   3. 恢复 xray 到 brew services（如果之前用 setup-xray-dedicated-user.sh 切换过）
#   4. 删除 _xray 用户和组
#
# 用法:
#   sudo bash uninstall-all.sh              # 交互模式（问你是否删除配置/日志）
#   sudo bash uninstall-all.sh --force      # 全部删除，不询问

set -e

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请用 sudo 运行: sudo bash $0"
        exit 1
    fi
}

need_root

FORCE=""
if [ "$1" = "--force" ] || [ "$1" = "-y" ]; then
    FORCE=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 一键完全卸载 pf2socks + xray 专用用户 ==="
echo ""

if [ -z "$FORCE" ]; then
    read -rp "确认卸载？[y/N] " ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && { echo "已取消"; exit 0; }
fi

echo ""
echo "Step 1/4: 关闭 pf 防火墙"
pfctl -d 2>&1 | grep -v "^No ALTQ\|^ALTQ" || true

echo ""
echo "Step 2/4: 卸载 pf2socks"
bash "$SCRIPT_DIR/../install.sh" uninstall || true

echo ""
echo "Step 3/4: 恢复 xray 到 brew services（如果有专用用户设置）"
if [ -f /Library/LaunchDaemons/io.xray.xray.plist ] || id _xray >/dev/null 2>&1; then
    bash "$SCRIPT_DIR/setup-xray-dedicated-user.sh" undo || true
else
    echo "未检测到 xray 专用用户设置，跳过"
fi

echo ""
echo "Step 4/4: 清理可选残留"
if [ -n "$FORCE" ]; then
    rm -rf /usr/local/etc/pf2socks /var/log/pf2socks /var/log/xray
    echo "已删除配置和日志目录"
else
    echo "下面的目录默认保留（用 --force 可一起删除）："
    [ -d /usr/local/etc/pf2socks ] && echo "  - /usr/local/etc/pf2socks"
    [ -d /var/log/pf2socks ] && echo "  - /var/log/pf2socks"
    [ -d /var/log/xray ] && echo "  - /var/log/xray"
fi

echo ""
echo "=== 验证 ==="
echo "xray 进程："
ps aux | grep "xray run" | grep -v grep | head -1 || echo "  未运行"
echo ""
echo "pf 状态："
pfctl -s info 2>/dev/null | head -1 || true
echo ""
echo "_xray 用户："
id _xray 2>&1 | head -1
echo ""
echo "代理端口测试："
curl -s --max-time 5 -x socks5://127.0.0.1:28880 https://ipinfo.io/ip 2>/dev/null && echo "  ← 代理仍正常（brew services 管理的 xray）" || echo "  代理不通（如果你想用 xray，运行: brew services start xray）"

echo ""
echo "=============================================="
echo "  ✅ 卸载完成"
echo "=============================================="
echo ""
echo "想重新安装？"
echo "  cd $(dirname "$SCRIPT_DIR")"
echo "  sudo bash install.sh 127.0.0.1:26662 127.0.0.1:28880"
