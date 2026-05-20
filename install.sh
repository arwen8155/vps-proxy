#!/bin/bash

# 颜色定义
RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

echo -e "${GREEN}========== VPS 多合一翻墙环境搭建脚本 (终极稳定版) ==========${PLAIN}"
read -p "请输入你的域名 (例如: proxy.example.com): " DOMAIN
read -p "请输入你的邮箱 (用于申请证书): " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}域名和邮箱不能为空！${PLAIN}"
    exit 1
fi

# 生成各种随机 UUID 和密码
UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
UUID_VMESS=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
WS_PATH="/vmessws"

# 1. 安装基础依赖与 Nginx
echo -e "${YELLOW}[1/5] 安装基础依赖与 Nginx...${PLAIN}"
# 加上 || true 防止 apt update 报错时直接退出脚本
apt update -y || true 
apt install -y curl socat wget unzip nginx jq iptables psmisc git

# 强制释放 80 端口，防止抢占
echo -e "${YELLOW}正在清理 80 端口占用...${PLAIN}"
systemctl stop nginx
fuser -k 80/tcp >/dev/null 2>&1

# 2. 使用 acme.sh 申请证书 (改用最稳妥的绝对路径安装)
echo -e "${YELLOW}[2/5] 正在安装 acme.sh 并申请 TLS 证书...${PLAIN}"
rm -rf ~/.acme.sh

# 下载并安装 acme.sh
curl -sSL https://get.acme.sh | sh -s email=$EMAIL

# 检查 acme.sh 是否成功下载
if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
    echo -e "${RED}错误：acme.sh 下载失败！可能是您的 VPS 连接 Let's Encrypt 网络不畅。${PLAIN}"
    echo -e "${YELLOW}尝试使用 GitHub 备用源安装...${PLAIN}"
    git clone https://github.com/acmesh-official/acme.sh.git
    cd acme.sh && ./acme.sh --install -m $EMAIL && cd ..
fi

# 绝对路径调用 acme.sh，避免使用 source 导致终端退出
ACME_BIN="${HOME}/.acme.sh/acme.sh"

$ACME_BIN --upgrade --auto-upgrade
$ACME_BIN --set-default-ca --server letsencrypt

echo -e "${YELLOW}开始向 Let's Encrypt 申请证书，请稍候...${PLAIN}"
$ACME_BIN --issue -d $DOMAIN --standalone --keylength ec-256 --force

if [ $? -ne 0 ]; then
    echo -e "${RED}证书申请失败！${PLAIN}"
    echo -e "${YELLOW}原因排查提示：${PLAIN}"
    echo -e "1. 您的域名 [${RED}$DOMAIN${PLAIN}] 是否已经成功解析到这台 VPS 的 IP？"
    echo -e "2. 云厂商后台（安全组）的 ${RED}80 端口${PLAIN} 是否放行？"
    exit 1
fi

mkdir -p /etc/vps-cert
$ACME_BIN --install-cert -d $DOMAIN --ecc \
    --key-file       /etc/vps-cert/private.key \
    --fullchain-file /etc/vps-cert/cert.crt

chmod 644 /etc/vps-cert/private.key
chmod 644 /etc/vps-cert/cert.crt
echo -e "${GREEN}证书申请成功！继续下一步...${PLAIN}"

# 3. 安装并配置 Xray (负责 Vless, Vmess, AnyTLS 分流)
echo -e "${YELLOW}[3/5] 安装并配置 Xray-core...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

REALITY_KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(head /dev/urandom | tr -dc a-f0-9 | head -c 16)

cat <<EOF > /usr/local/etc/xray/config.json
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [ { "id": "$UUID_VLESS", "flow": "xtls-rprx-vision" } ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "127.0.0.1:80",
                    "xver": 0,
                    "serverNames": [ "$DOMAIN", "www.microsoft.com" ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [ "$SHORT_ID" ]
                }
            }
        },
        {
            "port": 8080,
            "listen": "127.0.0.1",
            "protocol": "vmess",
            "settings": {
                "clients": [ { "id": "$UUID_VMESS", "alterId": 0 } ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": { "path": "$WS_PATH" }
            }
        }
    ],
    "outbounds": [ { "protocol": "freedom" } ]
}
EOF

systemctl restart xray

# 4. 配置 Nginx 实现回国伪装与 Vmess-WS 反代
echo -e "${YELLOW}[4/5] 配置 Nginx 网站伪装与反向代理...${PLAIN}"
cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/html;
    index index.html;

    location $WS_PATH {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
systemctl restart nginx

# 5. 安装并配置 Hysteria 2
echo -e "${YELLOW}[5/5] 安装并配置 Hysteria 2...${PLAIN}"
bash <(curl -fsSL https://get.hy2.sh)

cat <<EOF > /etc/hysteria/config.yaml
listen: :443

tls:
  cert: /etc/vps-cert/cert.crt
  key: /etc/vps-cert/private.key

auth:
  type: password
  password: $HY2_PASS

masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:80
    rewriteHost: true

advanced:
  udp_gso: true
EOF

systemctl restart hysteria-server

# 开放防火墙端口
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT

clear
echo -e "${GREEN}=================================================="
echo -e "       恭喜！所有协议节点已成功搭建完成！          "
echo -e "==================================================${PLAIN}"
echo -e "${YELLOW}[1] VLESS - Reality (AnyTLS 架构/无证书防探测)${PLAIN}"
echo -e "    - 服务器地址: ${GREEN}$DOMAIN${PLAIN}"
echo -e "    - 端口: ${GREEN}443${PLAIN}"
echo -e "    - 用户ID (UUID): ${GREEN}$UUID_VLESS${PLAIN}"
echo -e "    - 流控 (Flow): ${GREEN}xtls-rprx-vision${PLAIN}"
echo -e "    - 安全传输 (TLS): ${GREEN}reality${PLAIN}"
echo -e "    - SNI (Server Name): ${GREEN}$DOMAIN${PLAIN}"
echo -e "    - Master Key (PrivateKey): ${GREEN}$PRIVATE_KEY${PLAIN}"
echo -e "    - Public Key (PublicKey): ${GREEN}$PUBLIC_KEY${PLAIN}"
echo -e "    - Short ID: ${GREEN}$SHORT_ID${PLAIN}"
echo ""
echo -e "${YELLOW}[2] VMess - WS - TLS (传统兼容性最好的方案)${PLAIN}"
echo -e "    - 服务器地址: ${GREEN}$DOMAIN${PLAIN}"
echo -e "    - 端口: ${GREEN}443${PLAIN}"
echo -e "    - 用户ID (UUID): ${GREEN}$UUID_VMESS${PLAIN}"
echo -e "    - 传输协议: ${GREEN}ws (WebSocket)${PLAIN}"
echo -e "    - 伪装路径 (Path): ${GREEN}$WS_PATH${PLAIN}"
echo -e "    - 安全传输 (TLS): ${GREEN}tls${PLAIN}"
echo -e "    - SNI: ${GREEN}$DOMAIN${PLAIN}"
echo ""
echo -e "${YELLOW}[3] Hysteria 2 (UDP 暴风加速)${PLAIN}"
echo -e "    - 服务器地址: ${GREEN}$DOMAIN${PLAIN}"
echo -e "    - 端口: ${GREEN}443 (UDP)${PLAIN}"
echo -e "    - 认证密码: ${GREEN}$HY2_PASS${PLAIN}"
echo -e "    - 伪装 SNI: ${GREEN}$DOMAIN${PLAIN}"
echo -e "=================================================="
