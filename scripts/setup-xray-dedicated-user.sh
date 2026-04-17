#!/bin/bash
# Set up a dedicated _xray user for running xray, to prevent proxy loops
# when using pf2socks transparent proxy with xray.
#
# Usage:
#   sudo bash setup-xray-dedicated-user.sh        # Install
#   sudo bash setup-xray-dedicated-user.sh undo   # Revert

set -e

USER_NAME="_xray"
USER_UID=399
GROUP_GID=420
XRAY_CONFIG="/opt/homebrew/etc/xray/config.json"
XRAY_BIN="/opt/homebrew/bin/xray"
LAUNCHD_PLIST="/Library/LaunchDaemons/io.xray.xray.plist"
LAUNCHD_LABEL="io.xray.xray"
LOG_DIR="/var/log/xray"

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run with sudo: sudo bash $0 $*"
        exit 1
    fi
}

install_user() {
    # Check if user exists
    if id "$USER_NAME" >/dev/null 2>&1; then
        echo "User $USER_NAME already exists"
        return
    fi

    # Find available UID/GID if default is taken
    if dscl . -list /Users UniqueID | awk -v uid="$USER_UID" '$2 == uid { exit 1 }'; then
        echo "UID $USER_UID is available"
    else
        echo "UID $USER_UID is taken, please adjust the script"
        exit 1
    fi

    if dscl . -list /Groups PrimaryGroupID | awk -v gid="$GROUP_GID" '$2 == gid { exit 1 }'; then
        echo "GID $GROUP_GID is available"
    else
        echo "GID $GROUP_GID is taken, please adjust the script"
        exit 1
    fi

    echo "Creating $USER_NAME user (UID $USER_UID) and group (GID $GROUP_GID)..."
    dscl . -create /Users/$USER_NAME
    dscl . -create /Users/$USER_NAME UserShell /usr/bin/false
    dscl . -create /Users/$USER_NAME RealName "Xray Service User"
    dscl . -create /Users/$USER_NAME UniqueID $USER_UID
    dscl . -create /Users/$USER_NAME PrimaryGroupID $GROUP_GID
    dscl . -create /Users/$USER_NAME NFSHomeDirectory /var/empty
    dscl . -create /Users/$USER_NAME IsHidden 1

    dscl . -create /Groups/$USER_NAME
    dscl . -create /Groups/$USER_NAME PrimaryGroupID $GROUP_GID
    dscl . -create /Groups/$USER_NAME RealName "Xray Service Group"

    dscacheutil -flushcache
    killall -HUP DirectoryService 2>/dev/null || true
    sleep 1
    echo "Created: $(id $USER_NAME)"
}

install_daemon() {
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo "Error: xray config not found at $XRAY_CONFIG"
        exit 1
    fi

    echo "Setting xray config permissions..."
    chown root:$USER_NAME "$XRAY_CONFIG"
    chmod 640 "$XRAY_CONFIG"

    echo "Preparing log directory..."
    mkdir -p "$LOG_DIR"
    chown $USER_NAME:$USER_NAME "$LOG_DIR"

    echo "Stopping brew-managed xray..."
    sudo -u "${SUDO_USER:-$(whoami)}" brew services stop xray 2>/dev/null || true
    sleep 1

    echo "Installing LaunchDaemon..."
    cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHD_LABEL}</string>
    <key>UserName</key>
    <string>${USER_NAME}</string>
    <key>GroupName</key>
    <string>${USER_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${XRAY_BIN}</string>
        <string>run</string>
        <string>-config</string>
        <string>${XRAY_CONFIG}</string>
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

    launchctl load "$LAUNCHD_PLIST"
    sleep 2

    echo ""
    echo "Verification:"
    ps aux | grep "$USER_NAME" | grep xray | grep -v grep | head -1
    echo ""
    echo "✅ xray now running as $USER_NAME"
}

uninstall() {
    echo "Reverting xray to brew service..."

    # Stop LaunchDaemon
    if [ -f "$LAUNCHD_PLIST" ]; then
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
        rm -f "$LAUNCHD_PLIST"
        echo "Removed: $LAUNCHD_PLIST"
    fi

    # Restore config permissions
    if [ -f "$XRAY_CONFIG" ]; then
        original_owner="${SUDO_USER:-$(whoami)}"
        chown "$original_owner:staff" "$XRAY_CONFIG"
        chmod 644 "$XRAY_CONFIG"
        echo "Restored $XRAY_CONFIG permissions"
    fi

    # Remove user and group
    if id "$USER_NAME" >/dev/null 2>&1; then
        dscl . -delete /Users/$USER_NAME 2>/dev/null || true
        dscl . -delete /Groups/$USER_NAME 2>/dev/null || true
        dscacheutil -flushcache
        echo "Removed user and group $USER_NAME"
    fi

    # Remove logs (keep them if you want)
    # rm -rf "$LOG_DIR"

    # Restart brew service
    if command -v brew >/dev/null 2>&1; then
        sudo -u "${SUDO_USER:-$(whoami)}" brew services start xray 2>/dev/null || echo "Warning: could not start brew xray service"
    fi

    echo "✅ Revert complete"
}

need_root

case "${1:-install}" in
    install)
        install_user
        install_daemon
        ;;
    undo|uninstall|remove)
        uninstall
        ;;
    *)
        echo "Usage: sudo bash $0 [install|undo]"
        exit 1
        ;;
esac
