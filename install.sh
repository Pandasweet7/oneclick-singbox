#!/usr/bin/env bash
###############################################################################
# sing-box 服务器端一键安装脚本
# 功能: 一键安装 VLESS+Reality(域名地址/TCP443) + VLESS+WS+TLS + Hysteria2(salamander混淆)
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
REALITY_ADDR=""   # Reality 客户端连接地址, 为空则默认等于 DOMAIN(有域名时), 否则用服务器IP
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

  if [[ -z "$REALITY_ADDR" ]]; then
    _def_addr="${DOMAIN:-$SERVER_IP}"
    echo -e "${CYAN}Reality 节点地址用域名可隐藏真实 IP (该域名必须已解析到本机 ${SERVER_IP})${PLAIN}"
    read -rp "Reality 地址 [默认 ${_def_addr}]: " _ra || true
    _ra="$(echo "${_ra:-}" | xargs)"
    REALITY_ADDR="${_ra:-$_def_addr}"
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
  info "Reality地址: $REALITY_ADDR"
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
  HY2_OBFS="$(rand_hex 8)"   # salamander 混淆密码 (16位hex)
  # Reality 地址默认等于域名(隐藏真实IP), 无域名时用IP; 命令行 --reality-addr 可覆盖
  [[ -z "${REALITY_ADDR:-}" ]] && REALITY_ADDR="${DOMAIN:-$SERVER_IP}"

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
      "obfs": { "type": "salamander", "password": "${HY2_OBFS}" },
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
      "obfs": { "type": "salamander", "password": "${HY2_OBFS}" },
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
HY2_OBFS=${HY2_OBFS}
REALITY_ADDR=${REALITY_ADDR}
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
  # 兼容老版本 meta.env (没有 REALITY_ADDR/HY2_OBFS 字段)
  local reality_host="${REALITY_ADDR:-${DOMAIN:-$SERVER_IP}}"

  reality_link="vless://${UUID}@${reality_host}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp#VLESS-Reality-${reality_host}"

  if [[ -n "${DOMAIN:-}" ]]; then
    local enc_path hy2_extra=""
    enc_path="$(urlencode "$WS_PATH")"
    ws_link="vless://${UUID}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${enc_path}#VLESS-WS-TLS-${DOMAIN}"
    [[ -n "${HY2_OBFS:-}" ]] && hy2_extra="&obfs=salamander&obfs-password=${HY2_OBFS}"
    hy2_link="hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0${hy2_extra}#Hysteria2-${DOMAIN}"
  else
    [[ -n "${HY2_OBFS:-}" ]] && hy2_extra="&obfs=salamander&obfs-password=${HY2_OBFS}"
    hy2_link="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}/?sni=${SNI_DOMAIN}&insecure=1${hy2_extra}#Hysteria2-${SERVER_IP}"
  fi

  {
    echo "========== sing-box 节点信息 $(date '+%F %T') =========="
    echo "服务器IP: ${SERVER_IP}"
    echo "UUID: ${UUID}"
    echo ""
    echo "--- VLESS + Reality ---"
    echo "地址: ${reality_host}  端口: ${REALITY_PORT}"
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
      echo "--- Hysteria2 (salamander 混淆) ---"
      echo "地址: ${DOMAIN}  端口: ${HY2_PORT} (UDP)  密码: ${HY2_PASS}"
      echo "混淆: salamander  混淆密码: ${HY2_OBFS:-<老配置无混淆, 重装后生效>}"
      echo "SNI: ${DOMAIN}  ALPN: h3"
      echo "链接:"
      echo "${hy2_link}"
      echo ""
      echo "证书: ${CERT_DIR}/fullchain.pem (acme.sh 自动续签)"
    else
      echo "(无域名, 未安装 WS+TLS 节点)"
      echo ""
      echo "--- Hysteria2 (自签+salamander, 客户端需 insecure=1) ---"
      echo "地址: ${SERVER_IP}  端口: ${HY2_PORT} (UDP)  密码: ${HY2_PASS}"
      echo "混淆: salamander  混淆密码: ${HY2_OBFS:-<老配置无混淆, 重装后生效>}"
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
  # 备份脚本自身方便日后 info/uninstall, 并创建 sb 快捷命令
  cp -f "$0" "$SCRIPT_COPY" 2>/dev/null || true
  ln -sf "$SCRIPT_COPY" /usr/local/bin/sb 2>/dev/null || true
  step "安装完成"
  show_info
}

do_edit_config() {
  check_root
  [[ -f "$CONFIG_FILE" ]] || pause_exit "未找到 $CONFIG_FILE, 请先安装"
  # shellcheck disable=SC1091
  [[ -f "${CONFIG_DIR}/meta.env" ]] && . "${CONFIG_DIR}/meta.env"
  cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak-$(date +%F_%H%M)"
  echo "配置已备份: ${CONFIG_FILE}.bak-*"
  echo
  echo "  1) 更换 UUID (Reality/WS 共用, 旧客户端立即失效)"
  echo "  2) 更换端口 (Reality/WS/HY2)"
  echo "  3) 更换 Reality 地址 (只改客户端显示, 需域名已解析到本机)"
  echo "  4) 更换 HY2 密码 + 混淆密码"
  echo "  0) 返回"
  read -rp "请选择 [0-4]: " _e || return 0
  case "$_e" in
    1)
      NEW_UUID="$(rand_uuid)"
      UUID="$NEW_UUID" REALITY_ADDR="${REALITY_ADDR:-}" python3 - <<'PYEOF'
import json, os
p = os.environ.get("CONFIG_FILE", "/etc/sing-box/config.json")
d = json.load(open(p))
for ib in d.get("inbounds", []):
    if ib.get("type") == "vless":
        for u in ib.get("users", []):
            u["uuid"] = os.environ["UUID"]
json.dump(d, open(p, "w"), indent=2)
PYEOF
      info "新 UUID: $NEW_UUID"
      ;;
    2)
      _has_ws=0; grep -q '"tag": "vless-ws-tls"' "$CONFIG_FILE" && _has_ws=1
      read -rp "Reality 端口 [当前 ${REALITY_PORT:-443}]: " _np1 || true
      if [[ "$_has_ws" -eq 1 ]]; then read -rp "WS+TLS 端口 [当前 ${WS_PORT:-8443}]: " _np2 || true; else _np2=""; fi
      read -rp "HY2 端口(UDP) [当前 ${HY2_PORT:-8444}]: " _np3 || true
      for _pp in "${_np1:-}" "${_np2:-}" "${_np3:-}"; do
        [[ -z "$_pp" ]] && continue
        [[ "$_pp" =~ ^[0-9]+$ ]] && (( _pp >= 1 && _pp <= 65535 )) || pause_exit "端口不合法: $_pp"
      done
      [[ -n "${_np1:-}" ]] && REALITY_PORT="$_np1"
      [[ -n "${_np2:-}" ]] && WS_PORT="$_np2"
      [[ -n "${_np3:-}" ]] && HY2_PORT="$_np3"
      if [[ "$REALITY_PORT" == "$WS_PORT" || "$REALITY_PORT" == "$HY2_PORT" ]]; then
        pause_exit "Reality/WS/HY2 端口不能相同, 已中止 (备份在 ${CONFIG_FILE}.bak-*)"
      fi
      REALITY_PORT="$REALITY_PORT" WS_PORT="${WS_PORT:-}" HY2_PORT="$HY2_PORT" python3 - <<'PYEOF'
import json, os
p = os.environ.get("CONFIG_FILE", "/etc/sing-box/config.json")
d = json.load(open(p))
for ib in d.get("inbounds", []):
    if ib.get("tag") == "vless-reality":
        ib["listen_port"] = int(os.environ["REALITY_PORT"])
    elif ib.get("tag") == "vless-ws-tls" and os.environ.get("WS_PORT"):
        ib["listen_port"] = int(os.environ["WS_PORT"])
    elif ib.get("tag") == "hy2":
        ib["listen_port"] = int(os.environ["HY2_PORT"])
json.dump(d, open(p, "w"), indent=2)
PYEOF
      open_firewall
      ;;
    3)
      read -rp "Reality 地址 [当前 ${REALITY_ADDR:-${DOMAIN:-$SERVER_IP}}]: " _na || true
      _na="$(echo "${_na:-}" | xargs)"
      [[ -n "$_na" ]] && REALITY_ADDR="$_na"
      info "Reality 地址: $REALITY_ADDR (仅客户端链接变化, 服务端无需改动)"
      ;;
    4)
      HY2_PASS="$(rand_hex 12)"; HY2_OBFS="$(rand_hex 8)"
      HY2_PASS="$HY2_PASS" HY2_OBFS="$HY2_OBFS" python3 - <<'PYEOF'
import json, os
p = os.environ.get("CONFIG_FILE", "/etc/sing-box/config.json")
d = json.load(open(p))
for ib in d.get("inbounds", []):
    if ib.get("type") == "hysteria2":
        ib["users"][0]["password"] = os.environ["HY2_PASS"]
        ib["obfs"] = {"type": "salamander", "password": os.environ["HY2_OBFS"]}
json.dump(d, open(p, "w"), indent=2)
PYEOF
      info "新 HY2 密码: $HY2_PASS  混淆密码: $HY2_OBFS"
      ;;
    *) info "已取消"; return 0 ;;
  esac

  chmod 600 "$CONFIG_FILE"
  sing-box check -c "$CONFIG_FILE" || pause_exit "配置校验失败, 请从 ${CONFIG_FILE}.bak-* 恢复"
  # 回写 meta.env
  UUID="${UUID:-}" HY2_PASS="${HY2_PASS:-}" HY2_OBFS="${HY2_OBFS:-}" REALITY_ADDR="${REALITY_ADDR:-}" \
  REALITY_PORT="${REALITY_PORT:-}" WS_PORT="${WS_PORT:-}" HY2_PORT="${HY2_PORT:-}" python3 - <<'PYEOF'
import os
p = os.environ.get("CONFIG_DIR", "/etc/sing-box") + "/meta.env"
meta = {}
try:
    for line in open(p):
        line = line.strip()
        if line and "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            meta[k.strip()] = v.strip()
except FileNotFoundError:
    pass
for k in ["UUID", "HY2_PASS", "HY2_OBFS", "REALITY_ADDR", "REALITY_PORT", "WS_PORT", "HY2_PORT"]:
    v = os.environ.get(k, "")
    if v:
        meta[k] = v
open(p, "w").write("".join(f"{k}={v}\n" for k, v in meta.items()))
PYEOF
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || pause_exit "重启失败, 备份在 ${CONFIG_FILE}.bak-*"
  info "修改生效, 新节点信息:"
  show_info
}

show_menu() {
  check_root
  while true; do
    echo
    echo "========== sing-box 管理菜单 =========="
    echo "  1) 更新内核 (保留现有节点配置)"
    echo "  2) 查看节点信息"
    echo "  3) 修改配置 (UUID/端口/Reality地址/HY2密码)"
    echo "  4) 完全卸载 (删除配置)"
    echo "  0) 退出"
    read -rp "请选择 [0-4]: " _m || { echo; exit 0; }
    case "$_m" in
      1) do_update ;;
      2) show_info ;;
      3) do_edit_config ;;
      4) do_uninstall; exit 0 ;;
      0) exit 0 ;;
      *) warn "无效选项: ${_m:-空}, 请重选" ;;
    esac
    read -rp "按回车返回菜单..." _pause || exit 0
  done
}

do_update() {
  check_root
  check_os
  step "更新 sing-box 内核 (保留现有节点配置)"
  [[ -f "$CONFIG_FILE" ]] || pause_exit "未找到 $CONFIG_FILE, 请先安装"
  cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak-$(date +%F_%H%M)"
  cp -f /usr/local/bin/sing-box /tmp/sing-box.old 2>/dev/null || true
  info "当前: $(sing-box version 2>/dev/null | head -1 || echo unknown)"
  info "配置已备份: ${CONFIG_FILE}.bak-*"
  install_singbox   # 仅替换二进制, 不碰配置
  if ! sing-box check -c "$CONFIG_FILE"; then
    error "新内核校验旧配置失败, 正在回滚..."
    [[ -f /tmp/sing-box.old ]] && install -m 755 /tmp/sing-box.old /usr/local/bin/sing-box
    systemctl restart sing-box 2>/dev/null || true
    pause_exit "已回滚到旧内核, 请先查看 sing-box changelog 是否有 breaking change"
  fi
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box || pause_exit "重启失败, 备份在 ${CONFIG_FILE}.bak-*"
  info "内核更新完成: $(sing-box version 2>/dev/null | head -1)"
  info "节点配置未变, 可用 'sb' -> 2 查看"
}

do_uninstall() {
  check_root
  step "卸载 sing-box"
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  rm -rf "$CONFIG_DIR" /usr/local/bin/sing-box /usr/local/bin/sb "$INFO_FILE"
  echo -e "${GREEN}已卸载 (证书/acme.sh 保留, 如需删除 acme.sh 请手动 rm -rf ~/.acme.sh)${PLAIN}"
}

usage() {
  cat <<'EOF'
用法:
  install.sh                        交互式一键安装 (已安装时进管理菜单)
  sb                                管理菜单 (安装后可用: 更新内核/查看/修改/卸载)
  install.sh --domain example.com   非交互安装 (配合其它参数)
  install.sh info                   显示节点信息
  install.sh update                 只更新内核 (保留配置)
  install.sh menu                   打开管理菜单
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
  --reality-addr ADDR      Reality 客户端连接地址, 默认等于 --domain(无域名时用IP)
  --yes                    跳过确认
EOF
}

AUTO_YES=0
ACTION="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    info|show) ACTION="info"; shift ;;
    update) ACTION="update"; shift ;;
    menu) ACTION="menu"; shift ;;
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
    --reality-addr) REALITY_ADDR="$2"; shift 2 ;;
    --reality-addr=*) REALITY_ADDR="${1#*=}"; shift ;;
    --yes|-y) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

case "$ACTION" in
  info) show_info ;;
  update) do_update ;;
  menu) show_menu ;;
  uninstall) do_uninstall ;;
  install)
    if [[ $AUTO_YES -eq 1 || -n "$DOMAIN" ]]; then
      # 非交互: 补默认值后直接装
      check_root; check_os; install_deps; get_server_ip
      [[ -z "$WS_PATH" ]] && WS_PATH="/$(rand_hex 4)-ws"
      [[ -z "${REALITY_ADDR:-}" ]] && REALITY_ADDR="${DOMAIN:-$SERVER_IP}"
      [[ -z "$EMAIL" && -n "$DOMAIN" ]] && EMAIL="admin@${DOMAIN}"
      install_singbox; write_config; setup_systemd; open_firewall
      cp -f "$0" "$SCRIPT_COPY" 2>/dev/null || true
      ln -sf "$SCRIPT_COPY" /usr/local/bin/sb 2>/dev/null || true
      info "管理命令: 直接输入 sb 打开管理菜单"
      show_info
    elif [[ -f "$CONFIG_FILE" ]]; then
      # 已安装且无参数: 进管理菜单 (sb 快捷命令即走此分支)
      show_menu
    else
      do_install
    fi
    ;;
esac
