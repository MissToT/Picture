#!/bin/sh
# =============================================================================
#  sing-box 一键安装脚本（NAT 机 / Alpine Linux / OpenRC）
#  仓库: https://github.com/reF1nd/sing-box-releases
#  说明: 自动获取最新 Latest 稳定版；端口可手动输入；PSK 随机生成
#        安装完成后自动输出 Clash / Sing-box 两种格式节点信息
#        [已集成]: 低内存 NAT 机防 OOM 与防断流专项优化
# =============================================================================

set -e

# ─────────────────────────────────────────────────────────────────────────────
#  可修改配置区
#  SB_VERSION_OVERRIDE: 留空 = 自动从 GitHub API 获取最新 Latest 版本
#                       填写 = 固定版本，例如 "1.13.13-reF1nd"
# ─────────────────────────────────────────────────────────────────────────────
SB_VERSION_OVERRIDE=""
SB_VERSION_FALLBACK="1.13.13-reF1nd"
SB_REPO="reF1nd/sing-box-releases"
INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LOG_FILE="${CONFIG_DIR}/sing-box.log"
SERVICE_FILE="/etc/init.d/sing-box"

# ─────────────────────────────────────────────────────────────────────────────
#  彩色输出函数
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'
MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; exit 1; }
step()  { printf "\n${BLUE}━━━━━━━━━━━━  %s  ━━━━━━━━━━━━${NC}\n" "$*"; }
ok()    { printf "${GREEN}  ✓${NC} %s\n" "$*"; }
ask()   { printf "${CYAN}[INPUT]${NC}  %s" "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
#  权限检查
# ─────────────────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || error "请以 root 用户运行此脚本"


# =============================================================================
#  第一步：检测系统版本和架构
# =============================================================================
step "第一步：检测系统信息"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-Unknown}"
    OS_VER="${VERSION_ID:-unknown}"
else
    error "无法读取 /etc/os-release，不支持的系统"
fi

RAW_ARCH=$(uname -m)
info "系统发行版 : ${OS_NAME} ${OS_VER}"
info "CPU 架构   : ${RAW_ARCH}"

case "${RAW_ARCH}" in
    x86_64)         ARCH_TAG="amd64-musl" ;;
    aarch64|arm64)  ARCH_TAG="arm64-musl" ;;
    armv7l|armv7)   ARCH_TAG="armv7-musl" ;;
    armv6l)         ARCH_TAG="armv6-musl"  ;;
    i386|i686)      ARCH_TAG="386-musl"   ;;
    s390x)          ARCH_TAG="s390x-musl" ;;
    *)              error "不支持的 CPU 架构: ${RAW_ARCH}，请手动修改 ARCH_TAG" ;;
esac

info "对应下载后缀: linux-${ARCH_TAG}"

if   command -v apk     >/dev/null 2>&1; then PKG="apk"
elif command -v apt-get >/dev/null 2>&1; then PKG="apt"
elif command -v yum     >/dev/null 2>&1; then PKG="yum"
else PKG=""
fi


# =============================================================================
#  第二步：安装工具 → 确定版本 → 询问端口 → 生成 PSK
#          → 获取公网 IP → 查询地理位置生成节点名
# =============================================================================
step "第二步：版本确认 & 参数配置"

# ── 确保 curl / tar 可用 ──────────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    info "安装 curl / tar ..."
    case "${PKG}" in
        apk) apk update -q && apk add -q curl tar ;;
        apt) apt-get update -qq && apt-get install -y -qq curl tar ;;
        yum) yum install -y -q curl tar ;;
        *)   error "请手动安装 curl 和 tar 后重新运行脚本" ;;
    esac
    ok "curl / tar 安装完成"
else
    ok "curl / tar 已存在，跳过安装"
fi

# ── 确定 sing-box 版本 ────────────────────────────────────────────────────────
if [ -n "${SB_VERSION_OVERRIDE}" ]; then
    SB_VERSION="${SB_VERSION_OVERRIDE}"
    info "使用手动指定版本: v${SB_VERSION}"
else
    info "从 GitHub API 获取最新 Latest 稳定版本..."
    LATEST_TAG=$(curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/${SB_REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -n "${LATEST_TAG}" ]; then
        SB_VERSION="${LATEST_TAG#v}"
        ok "自动获取最新稳定版本: v${SB_VERSION}"
    else
        SB_VERSION="${SB_VERSION_FALLBACK}"
        warn "API 获取失败，使用兜底版本: v${SB_VERSION}"
    fi
fi

# ── 询问端口 ──────────────────────────────────────────────────────────────────
printf "\n"
ask "请输入 Snell 监听端口（直接回车使用默认值 12349）: "
read -r INPUT_PORT
SNELL_PORT="${INPUT_PORT:-12349}"

if ! echo "${SNELL_PORT}" | grep -qE '^[0-9]+$' \
   || [ "${SNELL_PORT}" -lt 1 ] || [ "${SNELL_PORT}" -gt 65535 ]; then
    error "无效端口 \"${SNELL_PORT}\"，必须在 1–65535 之间"
fi
ok "将使用端口: ${SNELL_PORT}"

# ── 生成随机 PSK ──────────────────────────────────────────────────────────────
if [ -r /proc/sys/kernel/random/uuid ]; then
    SNELL_PSK=$(cat /proc/sys/kernel/random/uuid)
else
    SNELL_PSK=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null \
        | od -A n -t x1 | tr -d ' \n' \
        | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/')
fi
ok "已生成随机 PSK: ${SNELL_PSK}"

# ── 获取公网 IP（全脚本仅此一次）─────────────────────────────────────────────
info "正在自动获取本机公网 IP..."
SERVER_IP=""
for _API in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ip.sb" \
    "https://api4.my-ip.io/ip" \
    "https://ipv4.icanhazip.com" \
    "https://checkip.amazonaws.com"; do
    _IP=$(curl -fsSL -4 --connect-timeout 5 --max-time 8 "${_API}" 2>/dev/null \
          | tr -d '[:space:]')
    if echo "${_IP}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        SERVER_IP="${_IP}"
        ok "公网 IP 获取成功: ${SERVER_IP}（来源: ${_API}）"
        break
    fi
done
if [ -z "${SERVER_IP}" ]; then
    warn "所有 IP 查询接口均失败，请在下方节点信息中手动替换 <YOUR_SERVER_IP>"
    SERVER_IP="<YOUR_SERVER_IP>"
fi

# ── 根据 IP 地理位置生成节点名 ────────────────────────────────────────────────
NODE_NAME=""
if [ "${SERVER_IP}" != "<YOUR_SERVER_IP>" ]; then
    info "正在查询 IP 地理位置..."

    # 主接口：ip-api.com
    GEO_JSON=$(curl -fsSL --connect-timeout 8 \
        "http://ip-api.com/json/${SERVER_IP}?fields=status,countryCode" \
        2>/dev/null || echo "")
    GEO_STATUS=$(printf '%s' "${GEO_JSON}" \
        | grep -o '"status":"[^"]*"' | sed 's/"status":"//;s/"//g')

    if [ "${GEO_STATUS}" = "success" ]; then
        GEO_CODE=$(printf '%s' "${GEO_JSON}" \
            | grep -o '"countryCode":"[^"]*"' | sed 's/"countryCode":"//;s/"//g' | tr 'a-z' 'A-Z')
    else
        # 备用接口：ipinfo.io
        warn "ip-api.com 无响应，尝试备用接口 ipinfo.io..."
        GEO_JSON=$(curl -fsSL --connect-timeout 8 \
            "https://ipinfo.io/${SERVER_IP}/json" 2>/dev/null || echo "")
        GEO_CODE=$(printf '%s' "${GEO_JSON}" \
            | grep -o '"country":"[^"]*"' | sed 's/"country":"//;s/"//g' | tr 'a-z' 'A-Z')
    fi

    if [ -n "${GEO_CODE}" ]; then
        if command -v perl >/dev/null 2>&1; then
            FLAG_EMOJI=$(echo "${GEO_CODE}" | perl -CS -pe 's/([A-Z])/chr(ord($1)+127397)/ge' 2>/dev/null)
        elif command -v python3 >/dev/null 2>&1; then
            FLAG_EMOJI=$(python3 -c "print(''.join(chr(ord(c) + 127397) for c in '${GEO_CODE}'))" 2>/dev/null)
        else
            CHAR1=$(printf '%d' "'${GEO_CODE:0:1}")
            CHAR2=$(printf '%d' "'${GEO_CODE:1:1}")
            FLAG_EMOJI=$(printf "\U$(printf '%08x' $((CHAR1 + 127397)))\U$(printf '%08x' $((CHAR2 + 127397)))" 2>/dev/null)
        fi
        NODE_NAME="${FLAG_EMOJI} ${GEO_CODE} Snell"
    fi
fi

if [ -n "${NODE_NAME}" ]; then
    ok "地理位置: ${GEO_CODE} → 节点名: ${NODE_NAME}"
else
    NODE_NAME="Snell-${SERVER_IP}"
    warn "无法获取地理位置，使用 IP 作为节点名: ${NODE_NAME}"
fi


# =============================================================================
#  第三步：下载 → 解压 → 安装 → 清理 → 验证
# =============================================================================
step "第三步：下载安装 sing-box"

TARBALL="sing-box-${SB_VERSION}-linux-${ARCH_TAG}.tar.gz"
EXTRACT_DIR="sing-box-${SB_VERSION}-linux-${ARCH_TAG}"
DL_URL="https://github.com/${SB_REPO}/releases/download/v${SB_VERSION}/${TARBALL}"

info "版本    : v${SB_VERSION}"
info "文件名  : ${TARBALL}"
info "下载地址: ${DL_URL}"

if [ -f "${SERVICE_FILE}" ] && command -v rc-service >/dev/null 2>&1; then
    rc-service sing-box stop 2>/dev/null && info "已停止旧 sing-box 服务" || true
fi
killall sing-box 2>/dev/null && info "已终止残余进程" || true

cd /root

info "下载中，请稍候..."
curl -fSL --progress-bar -o "${TARBALL}" "${DL_URL}" || {
    printf "\n${RED}[ERROR]${NC} 下载失败！\n"
    exit 1
}
ok "下载完成: ${TARBALL}"

info "解压中..."
tar -xzf "${TARBALL}" || error "解压失败，归档文件可能已损坏"
ok "解压完成"

info "安装到 ${INSTALL_BIN} ..."
install -m 755 "${EXTRACT_DIR}/sing-box" "${INSTALL_BIN}" \
    || error "安装失败，请检查目标路径权限"
ok "二进制安装成功"

rm -rf "${TARBALL}" "${EXTRACT_DIR}"
ok "临时文件已清理"

INSTALLED_VER=$("${INSTALL_BIN}" version 2>&1 | head -1)
ok "版本验证: ${INSTALLED_VER}"


# =============================================================================
#  第四步：写入配置文件
# =============================================================================
step "第四步：部署配置文件"

mkdir -p "${CONFIG_DIR}"
ok "配置目录已创建: ${CONFIG_DIR}"

if [ -f "${CONFIG_FILE}" ]; then
    BAK="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${CONFIG_FILE}" "${BAK}"
    warn "旧配置文件已备份: ${BAK}"
fi

cat > "${CONFIG_FILE}" << CONFIG_EOF
{
  "log": {
    "disabled": true,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "snell",
      "tag": "snell-obfs-in",
      "listen": "::",
      "listen_port": ${SNELL_PORT},
      "psk": "${SNELL_PSK}",
      "version": 5,
      "obfs_mode": "http",
      "obfs_host": "live.bilibili.com",
      "tcp_fast_open": true
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "route-options",
        "udp_disable_domain_unmapping": true
      },
      {
        "action": "resolve"
      }
    ],
    "final": "direct"
  }
}
CONFIG_EOF

ok "配置文件已写入: ${CONFIG_FILE}"

info "检查配置语法..."
"${INSTALL_BIN}" check -c "${CONFIG_FILE}" \
    && ok "配置语法检查通过 ✓" \
    || error "配置文件语法错误！请检查: ${CONFIG_FILE}"


# =============================================================================
#  第五步：低内存与 NAT 网络防断流优化 (动态资源算法)
# =============================================================================
step "第五步：内存与 NAT 网络防断流优化"

# 获取系统总内存 (MB)
MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
[ -z "$MEM_MB" ] && MEM_MB=256
info "检测到系统内存: ${MEM_MB} MB"

# 基于单协议/单节点 (Single Mode) 策略动态计算 Go 运行限制
if [ "$MEM_MB" -le 128 ]; then
    GOMEM="72MiB"; GOGC="90"; GOMAX="1"
elif [ "$MEM_MB" -le 192 ]; then
    GOMEM="104MiB"; GOGC="100"; GOMAX="1"
elif [ "$MEM_MB" -le 256 ]; then
    GOMEM="144MiB"; GOGC="100"; GOMAX="1"
elif [ "$MEM_MB" -le 512 ]; then
    GOMEM="280MiB"; GOGC="100"; GOMAX="2"
else
    GOMEM="$((MEM_MB * 60 / 100))MiB"
    GOGC="100"
    GOMAX=$(nproc 2>/dev/null || echo 1)
    [ "$GOMAX" -gt 4 ] && GOMAX=4
fi

ok "动态调整 Go 内存回收参数: GOMEMLIMIT=${GOMEM}, GOGC=${GOGC}, GOMAXPROCS=${GOMAX}"

info "正在应用 NAT 机器 TCP 防断流内核参数..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-singbox-nat.conf << EOF
# 缩短 TCP 保活，防 NAT 强制回收空闲长连接造成的卡顿
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF

# 极低内存机型限制连接缓冲区增长，防止 OOM
if [ "$MEM_MB" -le 256 ]; then
    cat >> /etc/sysctl.d/99-singbox-nat.conf << EOF
net.core.rmem_max = 1048576
net.core.wmem_max = 1048576
net.ipv4.tcp_rmem = 4096 87380 1048576
net.ipv4.tcp_wmem = 4096 65536 1048576
EOF
elif [ "$MEM_MB" -le 512 ]; then
    cat >> /etc/sysctl.d/99-singbox-nat.conf << EOF
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
EOF
fi

# LXC/OpenVZ 架构由于权限原因可能会报错，这里容错处理
sysctl -p /etc/sysctl.d/99-singbox-nat.conf >/dev/null 2>&1 || warn "当前系统无权修改 sysctl（常见于 LXC），已安全跳过网络调优"
ok "系统网络参数优化完毕"


# =============================================================================
#  第六步：写入 OpenRC 服务脚本 (带内存限制注入)
# =============================================================================
step "第六步：写入 OpenRC 守护服务脚本"

cat > "${SERVICE_FILE}" << SERVICE_EOF
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Daemon (Optimized for NAT)"
command="/usr/local/bin/sing-box"
command_args="run -c ${CONFIG_FILE} -D ${CONFIG_DIR}"
command_background="true"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0

# 动态注入内存与 GC 限制 (防 OOM 核心参数)
export GOMEMLIMIT="${GOMEM}"
export GOGC="${GOGC}"
export GOMAXPROCS="${GOMAX}"

depend() {
    need net
    use dns logger
}

start_post() {
    sleep 1
    if [ -f "\$pidfile" ]; then
        local pid=\$(cat "\$pidfile")
        if [ -n "\$pid" ]; then
            echo -1000 > /proc/\$pid/oom_score_adj 2>/dev/null
        fi
    fi
}
SERVICE_EOF

ok "服务脚本已写入: ${SERVICE_FILE}"


# =============================================================================
#  第七步：赋权 → 清残进程 → 启动 → 设置开机自启
# =============================================================================
step "第七步：启动服务 & 设置开机自启"

chmod +x "${SERVICE_FILE}"
ok "已赋予执行权限: ${SERVICE_FILE}"

killall sing-box 2>/dev/null || pkill sing-box 2>/dev/null || true

info "启动 sing-box 服务..."
rc-service sing-box start \
    && ok "sing-box 服务已正常启动" \
    || warn "启动失败，请查看日志: tail -50 ${LOG_FILE}"

rc-update add sing-box default \
    && ok "已设置开机自启（runlevel: default）"

sleep 2
if rc-service sing-box status 2>&1 | grep -q "started"; then
    ok "服务运行状态正常 ✓"
else
    warn "服务状态异常，最新日志如下："
    tail -20 "${LOG_FILE}" 2>/dev/null || echo "（日志为空）"
fi


# =============================================================================
#  第八步：清理 crontab 中 sing-box 的残留条目
# =============================================================================
step "第八步：清理 crontab 残留"

CRON_ORIG=$(crontab -l 2>/dev/null || echo "")
if echo "${CRON_ORIG}" | grep -q "sing-box"; then
    echo "${CRON_ORIG}" | grep -v "sing-box" | crontab -
    ok "已从 crontab 中移除 sing-box 相关条目"
else
    ok "crontab 中无 sing-box 残留，无需清理"
fi


# =============================================================================
#  第九步：生成格式化节点信息
# =============================================================================
step "第九步：生成节点连接信息"

# ── 格式一：Clash / Mihomo 格式（YAML 代理块）────────────────────────────────
CLASH_PROXY="  - name: \"${NODE_NAME}\"
    type: snell
    server: ${SERVER_IP}
    port: ${SNELL_PORT}
    psk: ${SNELL_PSK}
    version: 5
    obfs-opts:
      mode: http
      host: live.bilibili.com
    tfo: true
    udp: true"

# ── 格式二：Sing-box 格式（outbound 节点块）──────────────────────────────────
SINGBOX_OUT="{
  \"type\": \"snell\",
  \"tag\": \"${NODE_NAME}\",
  \"server\": \"${SERVER_IP}\",
  \"server_port\": ${SNELL_PORT},
  \"psk\": \"${SNELL_PSK}\",
  \"version\": 5,
  \"obfs_mode\": \"http\",
  \"obfs_host\": \"live.bilibili.com\",
  \"tcp_fast_open\": true
}"

# =============================================================================
#  输出汇总
# =============================================================================
printf "\n"
printf "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}\n"
printf "${BOLD}${BLUE}║              sing-box 安装部署完成！                         ║${NC}\n"
printf "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}\n"
printf "${BOLD}${BLUE}║  内核版本 : %-47s║${NC}\n" "${INSTALLED_VER}"
printf "${BOLD}${BLUE}║  服务状态 : %-47s║${NC}\n" "$(rc-service sing-box status 2>&1 | grep -o 'started\|stopped' || echo 'unknown')"
printf "${BOLD}${BLUE}║  内存限制 : GOMEMLIMIT=%-36s║${NC}\n" "${GOMEM}"
printf "${BOLD}${BLUE}║  配置文件 : %-47s║${NC}\n" "${CONFIG_FILE}"
printf "${BOLD}${BLUE}║  日志文件 : %-47s║${NC}\n" "${LOG_FILE}"
printf "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}\n"
printf "${BOLD}${BLUE}║  常用命令                                                    ║${NC}\n"
printf "${BOLD}${BLUE}║    启动  rc-service sing-box start                           ║${NC}\n"
printf "${BOLD}${BLUE}║    停止  rc-service sing-box stop                            ║${NC}\n"
printf "${BOLD}${BLUE}║    重启  rc-service sing-box restart                         ║${NC}\n"
printf "${BOLD}${BLUE}║    日志  tail -f %-44s║${NC}\n" "${LOG_FILE}"
printf "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"

# ── 节点信息 ──────────────────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}${YELLOW}══════════════════  节点连接信息（请复制保存！）  ══════════════════${NC}\n"

printf "\n${BOLD}${MAGENTA}▌ 一、Clash / Mihomo 格式${NC}（添加到 proxies: 列表下）\n"
printf "${GREEN}%s${NC}\n" "${CLASH_PROXY}"

printf "\n${BOLD}${MAGENTA}▌ 二、Sing-box 格式${NC}（添加到客户端 outbounds: 数组中）\n"
printf "${GREEN}%s${NC}\n" "${SINGBOX_OUT}"

printf "\n${BOLD}${YELLOW}════════════════════════════════════════════════════════════════════${NC}\n\n"