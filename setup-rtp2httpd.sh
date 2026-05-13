#!/bin/bash
# ============================================================
# Mac mini IPTV 一键配置脚本（rtp2httpd 版）
#
# 功能：
#   - 从源码编译安装 rtp2httpd（含 Web UI）
#   - 配置 IPTV 网络接口（DHCP）
#   - 生成 rtp2httpd.conf 配置文件
#   - 下载北京联通 M3U 频道列表
#   - 安装 launchd 开机自启动服务
#
# 网络架构:
#   光猫 LAN1 → Mac mini USB网卡 (en10, PPPoE上网)
#   光猫 LAN4 → Mac mini 自带网卡 (en0, IPTV组播源)
#   Mac mini 通过 rtp2httpd 将组播转单播，供全屋设备播放
#
# 使用方法:
#   chmod +x setup-iptv.sh
#   sudo ./setup-iptv.sh
# ============================================================

set -e

# ======================== 配置区 ========================
# IPTV 接口名称（连接光猫 IPTV 口的网卡）
IPTV_INTERFACE="en0"

# rtp2httpd 监听端口（msd_lite 占用 8686，测试期间用 5140）
PROXY_PORT=5140

# Mac mini 局域网 IP（供 Apple TV 等设备访问）
LAN_IP="192.168.31.1"
DOMAIN="your-mac-mini-domain"

# 北京联通 IPTV M3U 源
M3U_URL="https://raw.githubusercontent.com/qwerttvv/Beijing-IPTV/master/IPTV-Unicom-Multicast.m3u"

# rtp2httpd 版本
RTP2HTTPD_VERSION="3.12.1"

# 安装路径
RTP2HTTPD_BIN="/usr/local/bin/rtp2httpd"
RTP2HTTPD_CONF="/usr/local/etc/rtp2httpd.conf"
RTP2HTTPD_SRC="$HOME/.iptv/rtp2httpd_src"
PLIST_LABEL="com.local.rtp2httpd"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_LABEL}.plist"
M3U_DIR="$HOME/iptv"
LOG_DIR="/usr/local/var/log"
# ========================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 运行此脚本："
    echo "  sudo $0"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Mac mini IPTV 一键配置 (rtp2httpd) ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ============================================================
# 第一步：检查并安装编译依赖
# ============================================================
echo "━━━ [1/6] 检查编译依赖 ━━━"

# Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    warn "正在安装 Xcode Command Line Tools..."
    xcode-select --install
    error "请等待安装完成后重新运行此脚本"
fi
info "Xcode CLI Tools"

# Homebrew
if ! command -v brew &>/dev/null; then
    error "未找到 Homebrew，请先安装: https://brew.sh"
fi
info "Homebrew"

# cmake
if ! command -v cmake &>/dev/null; then
    warn "正在安装 cmake..."
    sudo -u "$SUDO_USER" brew install cmake
fi
info "cmake $(cmake --version | head -1 | awk '{print $3}')"

# Node.js (Web UI 构建需要)
if ! command -v node &>/dev/null; then
    warn "正在安装 Node.js..."
    sudo -u "$SUDO_USER" brew install node
fi
info "Node.js $(node --version)"

# pnpm (Web UI 包管理器)
if ! command -v pnpm &>/dev/null; then
    warn "正在启用 pnpm..."
    corepack enable 2>/dev/null || npm install -g pnpm
fi
info "pnpm $(pnpm --version 2>/dev/null || echo 'installed')"

echo ""

# ============================================================
# 第二步：编译安装 rtp2httpd
# ============================================================
echo "━━━ [2/6] 编译安装 rtp2httpd ━━━"

SKIP_BUILD=0
if [ -f "$RTP2HTTPD_BIN" ]; then
    CURRENT_VER=$("$RTP2HTTPD_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    info "已安装 rtp2httpd v${CURRENT_VER}"
    if [ "$CURRENT_VER" = "$RTP2HTTPD_VERSION" ]; then
        read -p "  已是最新版，是否重新编译？(y/N): " rebuild
        [ "$rebuild" != "y" ] && [ "$rebuild" != "Y" ] && SKIP_BUILD=1
    else
        warn "将从 v${CURRENT_VER} 升级到 v${RTP2HTTPD_VERSION}"
    fi
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "  从源码编译 rtp2httpd v${RTP2HTTPD_VERSION}..."
    mkdir -p "$RTP2HTTPD_SRC"

    # 克隆或更新源码
    if [ -d "$RTP2HTTPD_SRC/rtp2httpd/.git" ]; then
        cd "$RTP2HTTPD_SRC/rtp2httpd"
        git fetch --tags
    else
        rm -rf "$RTP2HTTPD_SRC/rtp2httpd"
        git clone https://github.com/stackia/rtp2httpd.git "$RTP2HTTPD_SRC/rtp2httpd"
        cd "$RTP2HTTPD_SRC/rtp2httpd"
    fi

    # 切换到指定版本
    git checkout "v${RTP2HTTPD_VERSION}" 2>/dev/null || git checkout main

    # 修复源码目录权限（sudo 环境下可能混乱）
    chown -R "$SUDO_USER" "$RTP2HTTPD_SRC/rtp2httpd"

    # 构建 Web UI（内置播放器 + 状态页面）
    echo "  构建 Web UI..."
    sudo -u "$SUDO_USER" bash -c "cd '$RTP2HTTPD_SRC/rtp2httpd' && pnpm install --frozen-lockfile 2>/dev/null || pnpm install"
    sudo -u "$SUDO_USER" bash -c "cd '$RTP2HTTPD_SRC/rtp2httpd' && pnpm run web-ui:build"

    # CMake 编译
    echo "  编译 C 源码..."
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_AGGRESSIVE_OPT=ON
    cmake --build build -j$(sysctl -n hw.ncpu)

    # 安装二进制
    if [ -f build/rtp2httpd ]; then
        cp build/rtp2httpd "$RTP2HTTPD_BIN"
    elif [ -f build/src/rtp2httpd ]; then
        cp build/src/rtp2httpd "$RTP2HTTPD_BIN"
    else
        BUILT=$(find build -name "rtp2httpd" -type f -perm +111 | head -1)
        [ -n "$BUILT" ] && cp "$BUILT" "$RTP2HTTPD_BIN" || error "编译产物未找到"
    fi
    chmod +x "$RTP2HTTPD_BIN"
    info "rtp2httpd v${RTP2HTTPD_VERSION} 编译安装完成"
fi

echo ""

# ============================================================
# 第三步：检查网络接口
# ============================================================
echo "━━━ [3/6] 检查网络接口 ━━━"

if ! ifconfig "$IPTV_INTERFACE" &>/dev/null; then
    warn "未找到接口 $IPTV_INTERFACE"
    echo ""
    echo "  当前可用接口:"
    ifconfig -l | tr ' ' '\n' | while read iface; do
        IP=$(ipconfig getifaddr "$iface" 2>/dev/null || echo "")
        [ -n "$IP" ] && echo "    $iface  ($IP)"
    done
    echo ""
    read -p "  请输入 IPTV 网卡接口名: " user_iface
    [ -n "$user_iface" ] && IPTV_INTERFACE="$user_iface" || error "必须指定 IPTV 接口"
fi
info "IPTV 接口: $IPTV_INTERFACE"

echo ""

# ============================================================
# 第四步：配置 IPTV 接口 DHCP
# ============================================================
echo "━━━ [4/6] 配置 IPTV 接口 ━━━"

ipconfig set "$IPTV_INTERFACE" DHCP
sleep 3

IPTV_IP=$(ipconfig getifaddr "$IPTV_INTERFACE" 2>/dev/null || echo "")
if [ -n "$IPTV_IP" ]; then
    info "IPTV 接口 IP: $IPTV_IP"
else
    warn "IPTV 接口暂未获取到 IP（请确认网线已连接光猫 IPTV 口）"
fi

echo ""

# ============================================================
# 第五步：生成配置文件并启动
# ============================================================
echo "━━━ [5/6] 生成配置并启动 ━━━"

mkdir -p "$(dirname "$RTP2HTTPD_CONF")"
mkdir -p "$M3U_DIR"
mkdir -p "$LOG_DIR"

# 下载 M3U
echo "  下载北京联通组播频道列表..."
if curl -sL --connect-timeout 10 "$M3U_URL" -o "$M3U_DIR/original.m3u"; then
    CHANNEL_COUNT=$(grep -c "^#EXTINF" "$M3U_DIR/original.m3u" 2>/dev/null || echo "0")
    info "频道列表: $CHANNEL_COUNT 个频道"
else
    warn "M3U 下载失败，请稍后手动下载到 $M3U_DIR/original.m3u"
fi

# 生成配置文件
cat > "$RTP2HTTPD_CONF" << EOF
# rtp2httpd 配置文件
# 文档: https://rtp2httpd.com/reference/configuration

[global]
# 日志级别: 0=quiet 1=error 2=warn 3=info 4=debug
verbosity = 3

# 最大并发客户端数
maxclients = 100

# 工作进程数（默认 1，设为 0 则等于 CPU 核数）
workers = 0

# 兼容 udpxy URL 格式
udpxy = yes

# 组播流上游接口（IPTV 网卡）
upstream-interface-multicast = $IPTV_INTERFACE

# 外部 M3U 播放列表（通过 /playlist.m3u 访问转换后的列表）
external-m3u = file://$M3U_DIR/original.m3u

# M3U 自动更新间隔（秒），0=禁用
external-m3u-update-interval = 0

# 启用 CORS（允许 Web 播放器跨域访问）
cors-allow-origin = *

[bind]
# 监听地址和端口
$LAN_IP $PROXY_PORT

[services]
# 也可以在这里直接写入 M3U 内容（已通过 external-m3u 配置，此处留空）
EOF

info "配置文件: $RTP2HTTPD_CONF"

# 停止已有的 rtp2httpd 进程（保留 msd_lite 不动）
killall rtp2httpd 2>/dev/null || true
sleep 1

# 启动测试
echo "  启动 rtp2httpd..."
"$RTP2HTTPD_BIN" --config "$RTP2HTTPD_CONF" &
RTP2HTTPD_PID=$!
sleep 2

if kill -0 "$RTP2HTTPD_PID" 2>/dev/null; then
    kill "$RTP2HTTPD_PID" 2>/dev/null
    wait "$RTP2HTTPD_PID" 2>/dev/null || true
    info "rtp2httpd 启动测试通过"
else
    error "rtp2httpd 启动失败，请检查配置: $RTP2HTTPD_BIN --config $RTP2HTTPD_CONF --verbose 4"
fi

echo ""

# ============================================================
# 第六步：安装 launchd 开机自启动
# ============================================================
echo "━━━ [6/6] 安装开机自启动 ━━━"

# 注意：保留 msd_lite 服务不动，测试通过后可手动移除：
#   sudo launchctl bootout system/com.local.msd-lite
#   sudo rm /Library/LaunchDaemons/com.local.msd-lite.plist

# 卸载旧版 rtp2httpd（如果已存在）
if launchctl print "system/$PLIST_LABEL" &>/dev/null; then
    launchctl bootout "system/$PLIST_LABEL" 2>/dev/null || true
fi

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RTP2HTTPD_BIN</string>
        <string>--config</string>
        <string>$RTP2HTTPD_CONF</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/rtp2httpd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/rtp2httpd.log</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

# 加载并启动
launchctl bootstrap system "$PLIST_PATH" 2>/dev/null || launchctl load "$PLIST_PATH"
sleep 2

if pgrep -x rtp2httpd >/dev/null; then
    info "rtp2httpd 服务已启动"
else
    warn "服务可能未启动成功，请查看日志: cat $LOG_DIR/rtp2httpd.log"
fi

echo ""

# ============================================================
# 完成
# ============================================================
echo "╔══════════════════════════════════════╗"
echo "║         配置完成！                    ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "  访问地址（局域网设备均可使用）："
echo ""
echo "    内置播放器:  http://$DOMAIN:$PROXY_PORT/player"
echo "    频道列表:    http://$DOMAIN:$PROXY_PORT/playlist.m3u"
echo "    状态监控:    http://$DOMAIN:$PROXY_PORT/status"
echo "    单频道测试:  http://$DOMAIN:$PROXY_PORT/rtp/239.3.1.1:8000"
echo ""
echo "  Apple TV / APTV / VLC 添加订阅源："
echo "    http://$DOMAIN:$PROXY_PORT/playlist.m3u"
echo "    （rtp2httpd 自动将组播地址转为 HTTP 代理地址）"
echo ""
echo "  管理命令："
echo "    查看状态:  launchctl print system/$PLIST_LABEL"
echo "    重启服务:  sudo launchctl kickstart -k system/$PLIST_LABEL"
echo "    停止服务:  sudo launchctl kill SIGTERM system/$PLIST_LABEL"
echo "    卸载服务:  sudo launchctl bootout system/$PLIST_PATH"
echo "    查看日志:  tail -f $LOG_DIR/rtp2httpd.log"
echo "    编辑配置:  nano $RTP2HTTPD_CONF"
echo ""
