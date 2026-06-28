#!/bin/sh
# =============================================================================
#  sing-box 一键安装脚本（NAT 机 / Alpine Linux / OpenRC）
#  融合版本：支持 Snell / AnyTLS / VLESS+REALITY 自由组合安装
#  仓库: https://github.com/reF1nd/sing-box-releases
#  说明: 自动获取最新 Latest 稳定版；支持多协议选择与参数自定义；
#        [已集成]: 低内存 NAT 机防 OOM 与防断流专项优化、自签名证书生成
# =============================================================================

set -e

# ─────────────────────────────────────────────────────────────────────────────
#  可修改配置区
# ─────────────────────────────────────────────────────────────────────────────
SB_VERSION_OVERRIDE=""
SB_VERSION_FALLBACK="1.13.13-reF1nd"
SB_REPO="reF1nd/sing-box-releases"
INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LOG_FILE="${CONFIG_DIR}/sing-box.log"
SERVICE_FILE="/etc/init.d/sing-box"
DEFAULT_SNI="live.bilibili.com"

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
#  自签名证书生成 (供 AnyTLS 使用)
# ─────────────────────────────────────────────────────────────────────────────
generate_self_signed_cert() {
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"
    info "正在为 ${domain} 生成自签名证书..."
    local openssl_config=$(mktemp)
    cat > "$openssl_config" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${domain}
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
EOF
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$key_path" -out "$cert_path" \
        -config "$openssl_config" >/dev/null 2>&1
    rm -f "$openssl_config"
    ok "证书已生成: ${cert_path}"
}

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
#  第二步：安装基础工具 (新增 jq, openssl 依赖)
# =============================================================================
step "第二步：安装基础依赖工具"

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    info "正在安装 curl / tar / jq / openssl ..."
    case "${PKG}" in
        apk) apk update -q && apk add -q curl tar jq openssl ;;
        apt) apt-get update -qq && apt-get install -y -qq curl tar jq openssl ;;
        yum) yum install -y -q curl tar jq openssl ;;
        *)   error "请手动安装 curl, tar, jq 和 openssl 后重新运行脚本" ;;
    esac
    ok "依赖工具安装完成"
else
    ok "核心依赖已存在，跳过安装"
fi

# =============================================================================
#  第三步：确认版本与公网 IP
# =============================================================================
step "第三步：版本确认 & 获取公网 IP"

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

info "正在自动获取本机公网 IP..."
SERVER_IP=""
for _API in \
    "https://api.ipify.org" "https://ifconfig.me/ip" "https://ip.sb" "https://api4.my-ip.io/ip" \
    "https://ipv4.icanhazip.com" "https://checkip.amazonaws.com"; do
    _IP=$(curl -fsSL -4 --connect-timeout 5 --max-time 8 "${_API}" 2>/dev/null | tr -d '[:space:]')
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

# 根据 IP 查询地理位置以生成前缀节点名
GEO_CODE=""
if [ "${SERVER_IP}" != "<YOUR_SERVER_IP>" ]; then
    GEO_JSON=$(curl -fsSL --connect-timeout 8 "http://ip-api.com/json/${SERVER_IP}?fields=status,countryCode" 2>/dev/null || echo "")
    GEO_STATUS=$(printf '%s' "${GEO_JSON}" | grep -o '"status":"[^"]*"' | sed 's/"status":"//;s/"//g')
    if [ "${GEO_STATUS}" = "success" ]; then
        GEO_CODE=$(printf '%s' "${GEO_JSON}" | grep -o '"countryCode":"[^"]*"' | sed 's/"countryCode":"//;s/"//g' | tr 'a-z' 'A-Z')
    fi
fi
[ -n "${GEO_CODE}" ] || GEO_CODE="Unknown"

# =============================================================================
#  第四步：协议选择与参数配置
# =============================================================================
step "第四步：协议选择与参数配置"

printf "${CYAN}请选择需要安装的协议 (支持多选如 1 2 3，或选 4 全选):${NC}\n"
printf "  1) Snell\n"
printf "  2) AnyTLS\n"
printf "  3) VLESS+REALITY\n"
printf "  4) 全选\n"
ask "请输入选项 [默认: 1]: "
read -r PROTO_CHOICE
PROTO_CHOICE="${PROTO_CHOICE:-1}"

INSTALL_SNELL=0; INSTALL_ANYTLS=0; INSTALL_VLESS=0

if echo "$PROTO_CHOICE" | grep -q "4"; then
    INSTALL_SNELL=1; INSTALL_ANYTLS=1; INSTALL_VLESS=1
else
    echo "$PROTO_CHOICE" | grep -q "1" && INSTALL_SNELL=1
    echo "$PROTO_CHOICE" | grep -q "2" && INSTALL_ANYTLS=1
    echo "$PROTO_CHOICE" | grep -q "3" && INSTALL_VLESS=1
fi

[ $INSTALL_SNELL -eq 0 ] && [ $INSTALL_ANYTLS -eq 0 ] && [ $INSTALL_VLESS -eq 0 ] && error "未选择任何协议！"

if [ $INSTALL_SNELL -eq 1 ]; then
    printf "\n${BOLD}${MAGENTA}--- Snell 设置 ---${NC}\n"
    ask "请输入 Snell 监听端口 [默认 12349]: "
    read -r SNELL_PORT; SNELL_PORT="${SNELL_PORT:-12349}"
    ask "请输入 Snell obfs_host [默认 ${DEFAULT_SNI}]: "
    read -r SNELL_OBFS; SNELL_OBFS="${SNELL_OBFS:-${DEFAULT_SNI}}"
    
    if [ -r /proc/sys/kernel/random/uuid ]; then SNELL_PSK=$(cat /proc/sys/kernel/random/uuid); else SNELL_PSK=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n' | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/'); fi
    ok "Snell 端口: $SNELL_PORT | OBFS: $SNELL_OBFS | PSK: $SNELL_PSK"
fi

if [ $INSTALL_ANYTLS -eq 1 ]; then
    printf "\n${BOLD}${MAGENTA}--- AnyTLS 设置 ---${NC}\n"
    ask "请输入 AnyTLS 监听端口 [默认 12350]: "
    read -r ANYTLS_PORT; ANYTLS_PORT="${ANYTLS_PORT:-12350}"
    ask "请输入 AnyTLS 伪装域名(SNI) [默认 ${DEFAULT_SNI}]: "
    read -r ANYTLS_SNI; ANYTLS_SNI="${ANYTLS_SNI:-${DEFAULT_SNI}}"
    ok "AnyTLS 端口: $ANYTLS_PORT | SNI: $ANYTLS_SNI"
fi

if [ $INSTALL_VLESS -eq 1 ]; then
    printf "\n${BOLD}${MAGENTA}--- VLESS+REALITY 设置 ---${NC}\n"
    ask "请输入 VLESS 监听端口 [默认 12351]: "
    read -r VLESS_PORT; VLESS_PORT="${VLESS_PORT:-12351}"
    ask "请输入 VLESS 伪装域名(SNI) [默认 ${DEFAULT_SNI}]: "
    read -r VLESS_SNI; VLESS_SNI="${VLESS_SNI:-${DEFAULT_SNI}}"
    ok "VLESS 端口: $VLESS_PORT | SNI: $VLESS_SNI"
fi


# =============================================================================
#  第五步：下载 → 解压 → 安装 sing-box
# =============================================================================
step "第五步：下载安装 sing-box"

TARBALL="sing-box-${SB_VERSION}-linux-${ARCH_TAG}.tar.gz"
EXTRACT_DIR="sing-box-${SB_VERSION}-linux-${ARCH_TAG}"
DL_URL="https://github.com/${SB_REPO}/releases/download/v${SB_VERSION}/${TARBALL}"

if [ -f "${SERVICE_FILE}" ] && command -v rc-service >/dev/null 2>&1; then
    rc-service sing-box stop 2>/dev/null && info "已停止旧 sing-box 服务" || true
fi
killall sing-box 2>/dev/null && info "已终止残余进程" || true

cd /root
info "下载中，请稍候..."
curl -fSL --progress-bar -o "${TARBALL}" "${DL_URL}" || error "下载失败！"
tar -xzf "${TARBALL}" || error "解压失败，归档文件可能已损坏"
install -m 755 "${EXTRACT_DIR}/sing-box" "${INSTALL_BIN}" || error "二进制安装失败"
rm -rf "${TARBALL}" "${EXTRACT_DIR}"
ok "临时文件已清理"

INSTALLED_VER=$("${INSTALL_BIN}" version 2>&1 | head -1)
ok "版本验证: ${INSTALLED_VER}"


# =============================================================================
#  第六步：动态生成配置文件
# =============================================================================
step "第六步：生成部署配置文件"

mkdir -p "${CONFIG_DIR}"
if [ -f "${CONFIG_FILE}" ]; then
    cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

INBOUNDS_JSON="[]"

# 生成 Snell 节点
if [ $INSTALL_SNELL -eq 1 ]; then
    SNELL_IN=$(cat <<EOF
{
  "type": "snell",
  "tag": "snell-in",
  "listen": "::",
  "listen_port": ${SNELL_PORT},
  "psk": "${SNELL_PSK}",
  "version": 5,
  "obfs_mode": "http",
  "obfs_host": "${SNELL_OBFS}",
  "tcp_fast_open": true
}
EOF
)
    INBOUNDS_JSON=$(echo "$INBOUNDS_JSON" | jq --argjson obj "$SNELL_IN" '. += [$obj]')
fi

# 生成 AnyTLS 节点
if [ $INSTALL_ANYTLS -eq 1 ]; then
    ANYTLS_PW=$("${INSTALL_BIN}" generate uuid)
    ANYTLS_CERT="${CONFIG_DIR}/anytls.pem"
    ANYTLS_KEY="${CONFIG_DIR}/anytls.key"
    generate_self_signed_cert "${ANYTLS_SNI}" "${ANYTLS_CERT}" "${ANYTLS_KEY}"
    
    ANYTLS_IN=$(cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-in",
  "listen": "::",
  "listen_port": ${ANYTLS_PORT},
  "users": [{"name": "default", "password": "${ANYTLS_PW}"}],
  "padding_scheme": ["stop=2", "0=100-200", "1=100-200"],
  "tls": {
    "enabled": true,
    "alpn": ["http/1.1"],
    "certificate_path": "${ANYTLS_CERT}",
    "key_path": "${ANYTLS_KEY}"
  }
}
EOF
)
    INBOUNDS_JSON=$(echo "$INBOUNDS_JSON" | jq --argjson obj "$ANYTLS_IN" '. += [$obj]')
fi

# 生成 VLESS+Reality 节点
if [ $INSTALL_VLESS -eq 1 ]; then
    VLESS_UUID=$("${INSTALL_BIN}" generate uuid)
    VLESS_KEYS=$("${INSTALL_BIN}" generate reality-keypair)
    VLESS_PRV=$(echo "$VLESS_KEYS" | awk '/PrivateKey/ {print $2}')
    VLESS_PUB=$(echo "$VLESS_KEYS" | awk '/PublicKey/ {print $2}')
    VLESS_SID=$("${INSTALL_BIN}" generate rand --hex 8)

    VLESS_IN=$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-reality-in",
  "listen": "::",
  "listen_port": ${VLESS_PORT},
  "users": [{"uuid": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}],
  "tls": {
    "enabled": true,
    "server_name": "${VLESS_SNI}",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "${VLESS_SNI}",
        "server_port": 443
      },
      "private_key": "${VLESS_PRV}",
      "short_id": ["${VLESS_SID}"]
    }
  }
}
EOF
)
    INBOUNDS_JSON=$(echo "$INBOUNDS_JSON" | jq --argjson obj "$VLESS_IN" '. += [$obj]')
fi

# 组装最终 Config
jq -n \
  --argjson inbounds "$INBOUNDS_JSON" \
  '{
    "log": { "disabled": true, "level": "info", "timestamp": true },
    "inbounds": $inbounds,
    "outbounds": [{"tag": "direct", "type": "direct"}],
    "route": {
      "rules": [
        {"action": "route-options", "udp_disable_domain_unmapping": true},
        {"action": "resolve"}
      ],
      "final": "direct"
    }
  }' > "${CONFIG_FILE}"

ok "配置文件已写入: ${CONFIG_FILE}"
"${INSTALL_BIN}" check -c "${CONFIG_FILE}" && ok "配置语法检查通过 ✓" || error "配置文件语法错误！请检查: ${CONFIG_FILE}"


# =============================================================================
#  第七步：低内存与 NAT 网络防断流优化 (动态资源算法)
# =============================================================================
step "第七步：内存与 NAT 网络防断流优化"

get_real_mem() {
    local mem_limit
    if [ -f /sys/fs/cgroup/memory.max ]; then
        mem_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        [ "$mem_limit" != "max" ] && echo $((mem_limit / 1024 / 1024)) && return
    fi
    if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        [ -n "$mem_limit" ] && [ "$mem_limit" -lt 1099511627776 ] && echo $((mem_limit / 1024 / 1024)) && return
    fi
    echo 256 
}

MEM_MB=$(get_real_mem)
[ "$MEM_MB" -gt 2048 ] && MEM_MB=256
info "NAT 容器真实内存识别为: ${MEM_MB} MB"

if [ "$MEM_MB" -le 128 ]; then
    GOMEM="72MiB"; GOGC="90"; GOMAX="1"
elif [ "$MEM_MB" -le 192 ]; then
    GOMEM="104MiB"; GOGC="100"; GOMAX="1"
elif [ "$MEM_MB" -le 256 ]; then
    GOMEM="144MiB"; GOGC="100"; GOMAX="1"
elif [ "$MEM_MB" -le 512 ]; then
    GOMEM="280MiB"; GOGC="100"; GOMAX="2"
else
    GOMEM="$((MEM_MB * 60 / 100))MiB"; GOGC="100"; GOMAX=$(nproc 2>/dev/null || echo 1)
    [ "$GOMAX" -gt 4 ] && GOMAX=4
fi

ok "动态调整 Go 参数: GOMEMLIMIT=${GOMEM}, GOGC=${GOGC}, GOMAXPROCS=${GOMAX}"

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-singbox-nat.conf << EOF
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF

if [ "$MEM_MB" -le 256 ]; then
    cat >> /etc/sysctl.d/99-singbox-nat.conf << EOF
net.core.rmem_max = 1048576
net.core.wmem_max = 1048576
net.ipv4.tcp_rmem = 4096 87380 1048576
net.ipv4.tcp_wmem = 4096 65536 1048576
EOF
fi
sysctl -p /etc/sysctl.d/99-singbox-nat.conf >/dev/null 2>&1 || warn "系统无权修改 sysctl，已跳过网络调优"
ok "网络参数优化完毕"


# =============================================================================
#  第八步：写入 OpenRC 服务脚本并启动
# =============================================================================
step "第八步：启动服务 & 设置开机自启"

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

export GOMEMLIMIT="${GOMEM}"
export GOGC="${GOGC}"
export GOMAXPROCS="${GOMAX}"

depend() {
    need net
    use dns logger
}
SERVICE_EOF

chmod +x "${SERVICE_FILE}"
killall sing-box 2>/dev/null || pkill sing-box 2>/dev/null || true

rc-service sing-box start && ok "sing-box 服务已正常启动" || warn "启动失败，请查看日志"
rc-update add sing-box default >/dev/null 2>&1 && ok "已设置开机自启"

CRON_ORIG=$(crontab -l 2>/dev/null || echo "")
if echo "${CRON_ORIG}" | grep -q "sing-box"; then
    echo "${CRON_ORIG}" | grep -v "sing-box" | crontab -
fi

# =============================================================================
#  输出汇总
# =============================================================================
printf "\n"
printf "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}\n"
printf "${BOLD}${BLUE}║              sing-box 融合版安装部署完成！                   ║${NC}\n"
printf "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}\n"
printf "${BOLD}${BLUE}║  内核版本 : %-47s║${NC}\n" "${INSTALLED_VER}"
printf "${BOLD}${BLUE}║  服务状态 : %-47s║${NC}\n" "$(rc-service sing-box status 2>&1 | grep -o 'started\|stopped' || echo 'unknown')"
printf "${BOLD}${BLUE}║  内存限制 : GOMEMLIMIT=%-36s║${NC}\n" "${GOMEM}"
printf "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"

printf "\n${BOLD}${YELLOW}══════════════════  节点连接信息（请复制保存）  ══════════════════${NC}\n"

# Snell 输出
if [ $INSTALL_SNELL -eq 1 ]; then
    printf "\n${BOLD}${MAGENTA}▌ [Snell 节点]${NC} - ${GEO_CODE}\n"
    printf "${GREEN}%s${NC}\n" "  - name: \"${GEO_CODE} Snell\"
    type: snell
    server: ${SERVER_IP}
    port: ${SNELL_PORT}
    psk: ${SNELL_PSK}
    version: 5
    obfs-opts:
      mode: http
      host: ${SNELL_OBFS}
    tfo: true
    udp: true"
fi

# AnyTLS 输出
if [ $INSTALL_ANYTLS -eq 1 ]; then
    printf "\n${BOLD}${MAGENTA}▌ [AnyTLS 节点]${NC} - 分享链接\n"
    ANYTLS_LINK="anytls://${ANYTLS_PW}@${SERVER_IP}:${ANYTLS_PORT}?security=tls&sni=${ANYTLS_SNI}&insecure=1&allowInsecure=1&type=tcp#${GEO_CODE}_AnyTLS"
    printf "${GREEN}%s${NC}\n" "${ANYTLS_LINK}"
fi

# VLESS+REALITY 输出
if [ $INSTALL_VLESS -eq 1 ]; then
    printf "\n${BOLD}${MAGENTA}▌ [VLESS-REALITY 节点]${NC} - 分享链接\n"
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?security=reality&encryption=none&pbk=${VLESS_PUB}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${VLESS_SNI}&sid=${VLESS_SID}#${GEO_CODE}_VLESS_Reality"
    printf "${GREEN}%s${NC}\n" "${VLESS_LINK}"
fi

printf "\n${BOLD}${YELLOW}════════════════════════════════════════════════════════════════════${NC}\n\n"