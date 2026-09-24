#!/usr/bin/env bash
###############################################################################
# sing-box 服务器端一键安装脚本
# 功能: 一键安装 VLESS+Reality(TCP443) + VLESS+WS+TLS + Hysteria2
# 系统: Debian / Ubuntu / CentOS / Rocky / Alma / Fedora
# 作者: 自用托管脚本, 可放在自己 GitHub 仓库 raw 直链一键调用
#
# 托管后的一键命令 (把 USER/REPO 换成你自己的):
#   bash <(curl -Ls https://raw.githubusercontent.com/USER/REPO/main/install.sh)
# 管理命令:
#   bash <(curl -Ls https://raw.githubusercontent.com/USER/REPO/main/install.sh) info
#   bash install.sh --uninstall
###############################################################################

set -u
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*"; }
step()  { echo -e "\n${BLUE}==== $* ====${PLAIN}"; }

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_DIR="${CONFIG_DIR}/cert"
INFO_FILE="/root/sing-box-info.txt"
SCRIPT_COPY="${CONFIG_DIR}/install.sh"

# 默认端口 (443 给 Reality, 避免和 TLS 抢443)
REALITY_PORT="${REALITY_PORT:-443}"
WS_PORT="${WS_PORT:-8443}"
HY2_PORT="${HY2_PORT:-8444}"
REALITY_SERVER="${REALITY_SERVER:-www.microsoft.com}"
DOMAIN=""
EMAIL=""
WS_PATH=""

pause_exit() { echo -e "${RED}$*${PLAIN}"; exit 1; }

check_root() {
  [[ $EUID -ne 0 ]] && pause_exit "请用 root 用户运行: sudo -i 后再执行"
}

check_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    OS_ID="unknown"
  fi
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) pause_exit "不支持的架构: $ARCH_RAW, 仅支持 amd64/arm64" ;;
  esac
  info "系统: ${OS_ID} / 架构: ${ARCH}"
}

install_deps() {
  step "安装依赖"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget socat openssl cron iptables systemd ca-certificates lsof iproute2 qrencode 2>/dev/null || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget socat openssl cron iptables systemd ca-certificates lsof iproute2
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release 2>/dev/null || true
    yum install -y curl wget socat openssl cronie iptables systemd ca-certificates lsof iproute qrencode 2>/dev/null || \
    yum install -y curl wget socat openssl cronie iptables systemd ca-certificates lsof iproute
    systemctl enable --now crond 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget socat openssl cronie iptables systemd ca-certificates lsof iproute qrencode 2>/dev/null || \
    dnf install -y curl wget socat openssl cronie iptables systemd ca-certificates lsof iproute
    systemctl enable --now crond 2>/dev/null || true
  else
    warn "未知包管理器, 假设 curl/openssl/socat 已安装"
  fi
  command -v curl >/dev/null || pause_exit "curl 安装失败"
  command -v openssl >/dev/null || pause_exit "openssl 安装失败"
  systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
}

get_server_ip() {
  SERVER_IP="$(curl -s4m 8 https://ip.sb || curl -s4m 8 https://ifconfig.me || curl -s4m 8 https://api.ipify.org || true)"
  [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="你的服务器IP"
}

get_latest_version() {
  # 从 GitHub API 取最新版, 失败则用已知稳定版兜底
  LATEST="$(curl -sL --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  # tag 形如 v1.12.1, 去掉 v
  LATEST="${LATEST#v}"
  if [[ ! "$LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    LATEST="1.12.1"
    warn "获取最新版失败, 使用兜底版本 v${LATEST}"
  else
    info "最新版本: v${LATEST}"
  fi
}

install_singbox() {
  step "安装 sing-box"
  if command -v sing-box >/dev/null 2>&1; then
    CUR="$(sing-box version 2>/dev/null | head -1 | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1 || true)"
    info "已安装 sing-box ${CUR:-unknown}, 正在升级到最新版..."
  fi
  get_latest_version
  local pkg="sing-box-${LATEST}-linux-${ARCH}.tar.gz"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/${pkg}"
  local tmp="/tmp/sing-box-${LATEST}"
  rm -rf "$tmp" "/tmp/${pkg}"
  mkdir -p "$tmp"
  info "下载: $url"
  curl -fSL --retry 3 --max-time 120 -o "/tmp/${pkg}" "$url" || pause_exit "下载 sing-box 失败, 请检查网络/代理"
  tar -xzf "/tmp/${pkg}" -C "$tmp"
  # 解压目录结构: sing-box-版本-linux-架构/sing-box
  BIN_SRC="$(find "$tmp" -name "sing-box" -type f | head -1)"
  [[ -z "$BIN_SRC" ]] && pause_exit "解压后找不到 sing-box 二进制"
  install -m 755 "$BIN_SRC" /usr/local/bin/sing-box
  rm -rf "$tmp" "/tmp/${pkg}"
  /usr/local/bin/sing-box version
  mkdir -p "$CONFIG_DIR" "$CERT_DIR"
  info "sing-box 安装完成: $(command -v sing-box)"
}

rand_hex()  { openssl rand -hex "$1"; }
rand_uuid() {
  if command -v sing-box >/dev/null 2>&1 && sing-box generate uuid >/dev/null 2>&1; then
    sing-box generate uuid
  elif [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

gen_reality_keypair() {
  local out priv pub
  out="$(sing-box generate reality-keypair)"
  priv="$(echo "$out" | grep -i "PrivateKey" | awk '{print $2}')"
  pub="$(echo "$out" | grep -i "PublicKey" | awk '{print $2}')"
  if [[ -z "$priv" || -z "$pub" ]]; then
    pause_exit "生成 Reality 密钥失败"
  fi
  REALITY_PRIV="$priv"
  REALITY_PUB="$pub"
}

gen_shortid() {
  if sing-box generate rand 8 --hex >/dev/null 2>&1; then
    sing-box generate rand 8 --hex
  else
    openssl rand -hex 8
  fi
}

ask_params() {
  step "参数输入 (回车用默认值)"
  get_server_ip

  # 如果环境变量/命令行已传入则不再问
  if [[ -z "$DOMAIN" ]]; then
    echo -e "${CYAN}请输入域名 (用于 VLESS+WS+TLS 和 Hysteria2 的 TLS 证书, 需已解析到本机 ${SERVER_IP})${PLAIN}"
    echo -e "${YELLOW}留空 = 只安装 Reality + 自签 HY2(不推荐, 请尽量填域名)${PLAIN}"
    read -rp "域名 (例如 example.com): " DOMAIN || true
    DOMAIN="$(echo "$DOMAIN" | xargs)"
  fi

  if [[ -n "$DOMAIN" && -z "$EMAIL" ]]; then
    read -rp "ACME 邮箱 (用于 Let's Encrypt 通知, 可回车跳过, 默认随机): " EMAIL || true
    EMAIL="$(echo "$EMAIL" | xargs)"
    [[ -z "$EMAIL" ]] && EMAIL="admin@${DOMAIN}"
  fi

  read -rp "Reality 端口 [默认 ${REALITY_PORT}]: " _p1 || true
  [[ -n "${_p1:-}" ]] && REALITY_PORT="$_p1"
  read -rp "WS+TLS 端口 [默认 ${WS_PORT}]: " _p2 || true
  [[ -n "${_p2:-}" ]] && WS_PORT="$_p2"
  read -rp "Hysteria2 端口(UDP) [默认 ${HY2_PORT}]: " _p3 || true
  [[ -n "${_p3:-}" ]] && HY2_PORT="$_p3"

  if [[ -z "$WS_PATH" ]]; then
    WS_PATH="/$(rand_hex 4)-ws"
    read -rp "WS 路径 [默认 ${WS_PATH}]: " _w || true
    [[ -n "${_w:-}" ]] && WS_PATH="$_w"
    [[ "$WS_PATH" != /* ]] && WS_PATH="/${WS_PATH}"
  fi

  # 端口冲突检查
  if [[ "$REALITY_PORT" == "$WS_PORT" || "$REALITY_PORT" == "$HY2_PORT" ]]; then
    pause_exit "Reality/WS/HY2 端口不能相同"
  fi

  echo
  info "域名       : ${DOMAIN:-<空,仅Reality>}"
  info "Reality端口: $REALITY_PORT"
  info "WS+TLS端口 : $WS_PORT"
  info "HY2端口    : $HY2_PORT (UDP)"
  info "WS路径     : $WS_PATH"
  echo
  read -rp "确认开始安装? [Y/n]: " _c || true
  [[ "${_c:-Y}" =~ ^[Nn]$ ]] && { echo "已取消"; exit 0; }
}

check_port_free() {
  local port=$1
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
    warn "端口 ${port} 疑似被占用:"
    ss -tlnp 2>/dev/null | grep ":${port} " || true
    ss -ulnp 2>/dev/null | grep ":${port} " || true
    read -rp "是否继续 (可能安装失败)? [y/N]: " _k || true
    [[ ! "${_k:-N}" =~ ^[Yy]$ ]] && pause_exit "已取消, 请释放端口后重试"
  fi
}

issue_cert_le() {
  step "申请 Let's Encrypt 证书: $DOMAIN"

  # 已有有效证书 (>30天) 直接复用, 避免重复签发触发 LE 限流
  if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/private.key" ]] && \
     openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1 && \
     openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
    info "检测到现有有效证书, 跳过签发直接复用"
    if [[ -f ~/.acme.sh/acme.sh ]]; then
      ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --key-file "${CERT_DIR}/private.key" \
        --reloadcmd "systemctl restart sing-box 2>/dev/null || service sing-box restart 2>/dev/null || true" 2>/dev/null || true
    fi
    return 0
  fi

  check_port_free 80

  # 解析检查
  local rip dip
  rip="$SERVER_IP"
  dip="$(curl -sL --max-time 10 "https://dns.google/resolve?name=${DOMAIN}&type=A" | grep -o '"data":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  if [[ -n "$dip" && "$dip" != "$rip" ]]; then
    warn "域名解析 $dip 与本机公网 $rip 不一致, HTTP-01 签发可能失败, 请确认 DNS 已生效"
    read -rp "仍继续? [y/N]: " _d || true
    [[ ! "${_d:-N}" =~ ^[Yy]$ ]] && pause_exit "已取消"
  fi

  # 安装 acme.sh
  if [[ ! -f ~/.acme.sh/acme.sh ]]; then
    info "安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s "email=${EMAIL}" || pause_exit "acme.sh 安装失败"
  fi
  # shellcheck disable=SC1090
  . ~/.acme.sh/acme.sh.env 2>/dev/null || export PATH="$HOME/.acme.sh:$PATH"

  # 默认 CA 切到 Let's Encrypt
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>/dev/null || true
  ~/.acme.sh/acme.sh --upgrade 2>/dev/null || true

  info "开始签发 (standalone, ECC-256)..."
  # 80 端口必须空闲, 尝试停掉可能占用的 nginx/apache 仅用于签发瞬间? 这里只提示, 不强杀
  if ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --server letsencrypt; then
    info "签发成功"
  else
    error "签发失败, 常见原因: 80端口被占 / DNS未生效 / 防火墙拦截"
    error "可手动重试: ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256"
    exit 1
  fi

  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --key-file "${CERT_DIR}/private.key" \
    --reloadcmd "systemctl restart sing-box 2>/dev/null || service sing-box restart 2>/dev/null || true"

  chmod 644 "${CERT_DIR}/fullchain.pem" 2>/dev/null || true
  chmod 600 "${CERT_DIR}/private.key" 2>/dev/null || true

  # acme.sh 自动续签 cron 已由安装程序写入, 额外确认
  (~/.acme.sh/acme.sh --install-cronjob 2>/dev/null || true)
  info "证书已安装到 ${CERT_DIR}, acme.sh 会自动续签并 reload sing-box"
}

gen_selfsigned() {
  step "生成自签证书 (无域名模式, HY2 需 insecure=1)"
  local sni="${SERVER_IP}"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "${CERT_DIR}/private.key" \
    -out "${CERT_DIR}/fullchain.pem" \
    -subj "/CN=${sni}" \
    -addext "subjectAltName=IP:${sni},DNS:${sni}" 2>/dev/null || \
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "${CERT_DIR}/private.key" \
    -out "${CERT_DIR}/fullchain.pem" \
    -subj "/CN=${sni}"
  chmod 644 "${CERT_DIR}/fullchain.pem"; chmod 600 "${CERT_DIR}/private.key"
  DOMAIN_FOR_CERT="$sni"
}

write_config() {
  step "生成 sing-box 配置"
  UUID="$(rand_uuid)"
  gen_reality_keypair
  SHORT_ID="$(gen_shortid)"
  HY2_PASS="$(rand_hex 12)"

  if [[ -n "$DOMAIN" ]]; then
    issue_cert_le
    CERT_FULL="${CERT_DIR}/fullchain.pem"
    CERT_KEY="${CERT_DIR}/private.key"
    SNI_DOMAIN="$DOMAIN"
    HY2_INSECURE="0"
  else
    gen_selfsigned
    CERT_FULL="${CERT_DIR}/fullchain.pem"
    CERT_KEY="${CERT_DIR}/private.key"
    SNI_DOMAIN="$SERVER_IP"
    HY2_INSECURE="1"
  fi

  # 写 config.json
  if [[ -n "$DOMAIN" ]]; then
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_SERVER}", "server_port": 443 },
          "private_key": "${REALITY_PRIV}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws-tls",
      "listen": "::",
      "listen_port": ${WS_PORT},
      "users": [{ "uuid": "${UUID}" }],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["http/1.1"],
        "certificate_path": "${CERT_FULL}",
        "key_path": "${CERT_KEY}"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${HY2_PASS}" }],
      "ignore_client_bandwidth": false,
      "masquerade": "https://www.bing.com",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"],
        "certificate_path": "${CERT_FULL}",
        "key_path": "${CERT_KEY}"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" }]
}
EOF
  else
    # 无域名: 只有 reality + 自签 hy2
    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_SERVER}", "server_port": 443 },
          "private_key": "${REALITY_PRIV}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${HY2_PASS}" }],
      "ignore_client_bandwidth": false,
      "masquerade": "https://www.bing.com",
      "tls": {
        "enabled": true,
        "server_name": "${SNI_DOMAIN}",
        "alpn": ["h3"],
        "certificate_path": "${CERT_FULL}",
        "key_path": "${CERT_KEY}"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" }]
}
EOF
  fi

  chmod 600 "$CONFIG_FILE"
  info "校验配置..."
  sing-box check -c "$CONFIG_FILE" || pause_exit "配置校验失败"

  # 保存变量供展示
  cat > "${CONFIG_DIR}/meta.env" <<EOF
UUID=${UUID}
REALITY_PRIV=${REALITY_PRIV}
REALITY_PUB=${REALITY_PUB}
SHORT_ID=${SHORT_ID}
HY2_PASS=${HY2_PASS}
DOMAIN=${DOMAIN}
SNI_DOMAIN=${SNI_DOMAIN}
REALITY_PORT=${REALITY_PORT}
WS_PORT=${WS_PORT}
HY2_PORT=${HY2_PORT}
WS_PATH=${WS_PATH}
REALITY_SERVER=${REALITY_SERVER}
SERVER_IP=${SERVER_IP}
HY2_INSECURE=${HY2_INSECURE:-0}
EOF
  chmod 600 "${CONFIG_DIR}/meta.env"
}

setup_systemd() {
  step "配置 systemd 自启"
  cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box
  sleep 2
  systemctl --no-pager status sing-box --lines=15 || true
  systemctl is-active --quiet sing-box || { journalctl -u sing-box --no-pager -n 50; pause_exit "sing-box 启动失败, 见上方日志"; }
  info "sing-box 运行正常"
}

open_firewall() {
  step "放行防火墙 / 开启 BBR"
  # ufw
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow "${REALITY_PORT}/tcp" 2>/dev/null || true
    ufw allow "${WS_PORT}/tcp" 2>/dev/null || true
    ufw allow "${HY2_PORT}/udp" 2>/dev/null || true
  fi
  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=80/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --permanent --add-port="${WS_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi
  # iptables 兜底 (仅追加允许, 不改默认策略)
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$REALITY_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$REALITY_PORT" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p tcp --dport "$WS_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$WS_PORT" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p udp --dport "$HY2_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$HY2_PORT" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
  fi
  # BBR
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    modprobe tcp_bbr 2>/dev/null || true
    grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null || echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
    cat > /etc/sysctl.d/99-singbox-bbr.conf <<'SYS'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYS
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-singbox-bbr.conf >/dev/null 2>&1 || true
  fi
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
}

urlencode() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"; }

show_info() {
  # shellcheck disable=SC1091
  [[ -f "${CONFIG_DIR}/meta.env" ]] && . "${CONFIG_DIR}/meta.env"
  [[ -z "${UUID:-}" ]] && pause_exit "未找到安装信息, 请先安装"
  get_server_ip
  # meta 里的 SERVER_IP 更准? 用新探测的覆盖仅当 meta 为空
  SERVER_IP="${SERVER_IP:-$SERVER_IP}"

  local reality_link="" ws_link="" hy2_link=""
  local host_for_reality="${SERVER_IP}"

  reality_link="vless://${UUID}@${host_for_reality}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp#VLESS-Reality-${host_for_reality}"

  if [[ -n "${DOMAIN:-}" ]]; then
    local enc_path
    enc_path="$(urlencode "$WS_PATH")"
    ws_link="vless://${UUID}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${enc_path}#VLESS-WS-TLS-${DOMAIN}"
    hy2_link="hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0#Hysteria2-${DOMAIN}"
  else
    hy2_link="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}/?sni=${SNI_DOMAIN}&insecure=1#Hysteria2-${SERVER_IP}"
  fi

  {
    echo "========== sing-box 节点信息 $(date '+%F %T') =========="
    echo "服务器IP: ${SERVER_IP}"
    echo "UUID: ${UUID}"
    echo ""
    echo "--- VLESS + Reality ---"
    echo "地址: ${SERVER_IP}  端口: ${REALITY_PORT}"
    echo "SNI: ${REALITY_SERVER}  指纹: chrome"
    echo "公钥(pbk): ${REALITY_PUB}"
    echo "shortId(sid): ${SHORT_ID}  流控: xtls-rprx-vision"
    echo "链接:"
    echo "${reality_link}"
    echo ""
    if [[ -n "${DOMAIN:-}" ]]; then
      echo "--- VLESS + WS + TLS ---"
      echo "地址: ${DOMAIN}  端口: ${WS_PORT}  路径: ${WS_PATH}"
      echo "SNI: ${DOMAIN}"
      echo "链接:"
      echo "${ws_link}"
      echo ""
      echo "--- Hysteria2 ---"
      echo "地址: ${DOMAIN}  端口: ${HY2_PORT} (UDP)  密码: ${HY2_PASS}"
      echo "SNI: ${DOMAIN}  ALPN: h3"
      echo "链接:"
      echo "${hy2_link}"
      echo ""
      echo "证书: ${CERT_DIR}/fullchain.pem (acme.sh 自动续签)"
    else
      echo "(无域名, 未安装 WS+TLS 节点)"
      echo ""
      echo "--- Hysteria2 (自签, 客户端需 insecure=1) ---"
      echo "地址: ${SERVER_IP}  端口: ${HY2_PORT} (UDP)  密码: ${HY2_PASS}"
      echo "链接:"
      echo "${hy2_link}"
    fi
    echo ""
    echo "管理: systemctl status|restart sing-box ; sing-box check -c ${CONFIG_FILE}"
    echo "证书续签: ~/.acme.sh/acme.sh --renew -d ${DOMAIN:-你的域名} --force (有域名时)"
  } | tee "$INFO_FILE"

  echo
  if command -v qrencode >/dev/null 2>&1; then
    echo -e "${CYAN}Reality 二维码:${PLAIN}"
    echo "$reality_link" | qrencode -t ANSIUTF8 2>/dev/null || true
  fi
  echo -e "${GREEN}节点信息已保存到: ${INFO_FILE}${PLAIN}"
}

do_install() {
  check_root
  check_os
  install_deps
  ask_params
  check_port_free "$REALITY_PORT"
  check_port_free "$WS_PORT"
  install_singbox
  write_config
  setup_systemd
  open_firewall
  # 备份脚本自身方便日后 info/uninstall
  cp -f "$0" "$SCRIPT_COPY" 2>/dev/null || true
  step "安装完成"
  show_info
}

do_uninstall() {
  check_root
  step "卸载 sing-box"
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  rm -rf "$CONFIG_DIR" /usr/local/bin/sing-box "$INFO_FILE"
  echo -e "${GREEN}已卸载 (证书/acme.sh 保留, 如需删除 acme.sh 请手动 rm -rf ~/.acme.sh)${PLAIN}"
}

usage() {
  cat <<'EOF'
用法:
  install.sh                        交互式一键安装
  install.sh --domain example.com   非交互安装 (配合其它参数)
  install.sh info                   显示节点信息
  install.sh --uninstall            卸载
  install.sh -h                     帮助

非交互参数:
  --domain DOMAIN          域名 (空则仅 Reality+自签HY2)
  --email EMAIL            ACME 邮箱
  --reality-port PORT      默认 443
  --ws-port PORT           默认 8443
  --hy2-port PORT          默认 8444
  --ws-path /xxx           默认随机
  --reality-server NAME    默认 www.microsoft.com
  --yes                    跳过确认
EOF
}

AUTO_YES=0
ACTION="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    info|show) ACTION="info"; shift ;;
    --uninstall|uninstall) ACTION="uninstall"; shift ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --domain=*) DOMAIN="${1#*=}"; shift ;;
    --email) EMAIL="$2"; shift 2 ;;
    --email=*) EMAIL="${1#*=}"; shift ;;
    --reality-port) REALITY_PORT="$2"; shift 2 ;;
    --reality-port=*) REALITY_PORT="${1#*=}"; shift ;;
    --ws-port) WS_PORT="$2"; shift 2 ;;
    --ws-port=*) WS_PORT="${1#*=}"; shift ;;
    --hy2-port) HY2_PORT="$2"; shift 2 ;;
    --hy2-port=*) HY2_PORT="${1#*=}"; shift ;;
    --ws-path) WS_PATH="$2"; shift 2 ;;
    --ws-path=*) WS_PATH="${1#*=}"; shift ;;
    --reality-server) REALITY_SERVER="$2"; shift 2 ;;
    --reality-server=*) REALITY_SERVER="${1#*=}"; shift ;;
    --yes|-y) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

case "$ACTION" in
  info) show_info ;;
  uninstall) do_uninstall ;;
  install)
    if [[ $AUTO_YES -eq 1 || -n "$DOMAIN" ]]; then
      # 非交互: 补默认值后直接装
      check_root; check_os; install_deps; get_server_ip
      [[ -z "$WS_PATH" ]] && WS_PATH="/$(rand_hex 4)-ws"
      [[ -z "$EMAIL" && -n "$DOMAIN" ]] && EMAIL="admin@${DOMAIN}"
      install_singbox; write_config; setup_systemd; open_firewall
      cp -f "$0" "$SCRIPT_COPY" 2>/dev/null || true
      show_info
    else
      do_install
    fi
    ;;
esac
