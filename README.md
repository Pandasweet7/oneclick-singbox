# sing-box 一键安装 (VLESS+Reality / VLESS+WS+TLS / Hysteria2)

服务器端一键脚本, 自动安装最新版 `sing-box`, 生成 3 个节点, 输入域名自动签发 Let's Encrypt 证书并自动续签。

## 一键安装

把 `USER/REPO` 换成你自己的 GitHub 用户名和仓库名, 在 VPS 上执行:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Pandasweet7/oneclick-singbox/main/install.sh)
```

 domestic 机器 GitHub raw 连不通时可用代理镜像:

```bash
bash <(curl -Ls https://gh-proxy.com/https://raw.githubusercontent.com/USER/REPO/main/install.sh)
# 或
bash <(curl -Ls https://cdn.jsdelivr.net/gh/USER/REPO@main/install.sh)
```

## 托管到自己的 GitHub 仓库

```bash
# 1. 在 GitHub 新建公开仓库, 例如 sing-box-install
# 2. 本地推送
git init
git add install.sh README.md
git commit -m "feat: sing-box 一键安装脚本"
git branch -M main
git remote add origin git@github.com:USER/REPO.git
git push -u origin main

# 3. 确认 raw 链接可访问:
# https://raw.githubusercontent.com/USER/REPO/main/install.sh
```

仓库设为 Public, 否则 raw 链接需要 Token, 一键命令会 404。

## 安装内容

| 节点 | 默认端口 | 说明 |
|---|---|---|
| VLESS + Reality + Vision | 443/tcp | 无需证书; 客户端地址默认用域名 (隐藏真实 IP, 需域名解析到本机), 可用 `--reality-addr` 覆盖 |
| VLESS + WS + TLS | 8443/tcp | 需要域名 + LE 证书 |
| Hysteria2 + salamander 混淆 | 8444/udp | 需要域名 + LE 证书, 混淆密码自动随机生成; 客户端需填 `obfs=salamander` + 混淆密码 |

安装过程自动完成:

- 安装依赖 + 最新版 sing-box (amd64/arm64)
- 生成 UUID / Reality keypair / shortId / HY2 密码 / 随机 WS 路径
- 有域名: `acme.sh --issue --standalone` 签发 ECC 证书到 `/etc/sing-box/cert/`, `--install-cert --reloadcmd "systemctl restart sing-box"` 实现自动续签
- 无域名: 生成自签证书, 只装 Reality + HY2(客户端开 insecure)
- 写 `/etc/sing-box/config.json` 并 `sing-box check` 校验
- 注册 `systemd` 开机自启, 放行防火墙, 开 BBR
- 输出 3 个节点链接并保存到 `/root/sing-box-info.txt`, 有 `qrencode` 时打印 Reality 二维码

## 前置条件

1. VPS: Debian/Ubuntu/CentOS, root 用户, amd64/arm64
2. 域名已 `A 记录` 解析到 VPS 公网 IP (Reality 用域名时同样要求; 若有 AAAA 记录, 须确认指向本机, 否则删掉, 免得客户端优先走不可达的 IPv6)
3. `80` 端口空闲 (签发证书用, 签完可关), `443/8443/tcp + 8444/udp` 未被占用

## 非交互安装 (写脚本/批量用)

```bash
curl -LO https://raw.githubusercontent.com/USER/REPO/main/install.sh
chmod +x install.sh
sudo ./install.sh --domain example.com --email admin@example.com \
  --reality-port 443 --ws-port 8443 --hy2-port 8444 --yes
# Reality 默认用 --domain 当客户端地址; 换另一个域名:
# sudo ./install.sh --domain example.com --reality-addr reality.example.com --yes
```

## 常用管理

```bash
# 查看节点信息
bash install.sh info

# 校验配置
sing-box check -c /etc/sing-box/config.json

# 重启 / 状态
systemctl restart sing-box
systemctl status sing-box
journalctl -u sing-box -n 50 --no-pager

# 手动强制续签 (一般不需要, acme.sh 的 cron 会自动续)
~/.acme.sh/acme.sh --renew -d example.com --force
ls -l /etc/sing-box/cert/

# 卸载
bash install.sh --uninstall
```

## 目录结构

```
/usr/local/bin/sing-box          # 二进制
/etc/sing-box/config.json        # 主配置 (600 权限)
/etc/sing-box/cert/fullchain.pem # 证书
/etc/sing-box/cert/private.key   # 私钥
/etc/sing-box/meta.env           # UUID/密钥/端口等元数据
/etc/sing-box/install.sh         # 脚本备份
/root/sing-box-info.txt          # 节点链接备份
```

## 常见问题

- **80 端口被占签发失败**: `lsof -i:80`, 停掉 nginx/apache 后重试。
- **DNS 未生效**: `curl "https://dns.google/resolve?name=你的域名&type=A"`, 等 5~30 分钟。
- **HY2 连不上**: 服务商安全组/防火墙放行 UDP, 本地运营商 UDP QoS 可换端口重试。
- **Reality 只能用 443?** 脚本默认 443, 被占可改其他端口, 但 SNI 建议保持 `www.microsoft.com`。
