#!/bin/bash

# 颜色定义
RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

clear
echo -e "${GREEN}==================================================================${PLAIN}"
echo -e "${GREEN}   VPS 多合一环境搭建脚本 (自动测速最优域名 + BBR + 自动输出链接)   ${PLAIN}"
echo -e "${GREEN}==================================================================${PLAIN}"
read -p "请输入你的域名 (例如: proxy.example.com): " DOMAIN
read -p "请输入你的邮箱 (用于申请证书): " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}错误：域名和邮箱不能为空！${PLAIN}"
    exit 1
fi

# ==================== 🚀 1. 自动开启 BBR 加加速逻辑 ====================
echo -e "\n${YELLOW}[1/6] 正在检查并自动开启 BBR 系统加速...${PLAIN}"
if lsmod | grep -q bbr; then
    echo -e "${GREEN}【BBR状态】检测到 BBR 加速早已处于开启状态，保持现状。${PLAIN}"
else
    echo -e "${YELLOW}正在为您的 Linux 内核配置 BBR 拥塞控制算法...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}【BBR状态】成功：BBR 拥塞控制算法已成功启动！${PLAIN}"
    else
        echo -e "${RED}【BBR状态】警告：BBR 自动开启失败，可能由于虚拟化架构不支持。${PLAIN}"
    fi
fi

# ==================== ⚡ 2. 自动测速寻找最优伪装域名 ====================
echo -e "\n${YELLOW}[2/6] 正在对各大厂域名进行 TLS 握手测速，寻找最优 Reality 伪装目标...${PLAIN}"
echo -e "${YELLOW}请稍候，这可能需要 5-10 秒钟...${PLAIN}"

# 你的测速核心代码，提取出延迟最低的那一个域名
BEST_DOMAINS=($(
(for d in \
  www.cloudflare.com www.apple.com www.microsoft.com www.bing.com www.google.com \
  developer.apple.com www.gstatic.com fonts.gstatic.com fonts.googleapis.com \
  res-1.cdn.office.net res.public.onecdn.static.microsoft static.cloud.coveo.com \
  aws.amazon.com www.aws.com cloudfront.net d1.awsstatic.com \
  cdn.jsdelivr.net cdn.jsdelivr.org polyfill-fastly.io \
  beacon.gtv-pub.com s7mbrstream.scene7.com cdn.bizibly.com \
  www.sony.com www.nytimes.com www.w3.org www.wikipedia.org \
  ajax.cloudflare.com www.mozilla.org www.intel.com \
  api.snapchat.com images.unsplash.com \
  edge-mqtt.facebook.com video.xx.fbcdn.net \
  gstatic.cn \
; do \
  t1=$(date +%s%3N); \
  timeout 1 openssl s_client -connect $d:443 -servername $d </dev/null &>/dev/null && \
  t2=$(date +%s%3N) && echo "$((t2 - t1)) $d"; \
done) | sort -n | head -n 1
))

# 提取测速结果
LOWEST_PING=${BEST_DOMAINS[0]}
REALITY_DEST_DOMAIN=${BEST_DOMAINS[1]}

# 如果由于 VPS 网络原因没测出结果，则赋予一个安全默认值
if [ -z "$REALITY_DEST_DOMAIN" ]; then
    REALITY_DEST_DOMAIN="www.microsoft.com"
    LOWEST_PING="默认"
    echo -e "${YELLOW}测速未完全成功，已自动选择默认防探测域名: $REALITY_DEST_DOMAIN${PLAIN}"
else
    echo -e "${GREEN}✔️ 已成功找到当前 VPS 连接延迟最低的域名: ${YELLOW}$REALITY_DEST_DOMAIN${GREEN} (延迟: ${LOWEST_PING} ms)${PLAIN}"
fi

# 生成各种随机参数
UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
UUID_VMESS=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
WS_PATH="/vmessws"

# ==================== 📦 3. 安装基础依赖与 Nginx ====================
echo -e "\n${YELLOW}[3/6] 正在安装基础依赖、Nginx及二维码工具...${PLAIN}"
apt update -y || true 
apt install -y curl socat wget unzip nginx jq iptables psmisc git qrencode openssl

systemctl stop nginx
fuser -k 80/tcp >/dev/null 2>&1

# ==================== 🔒 4. 使用 acme.sh 申请 TLS 证书 ====================
echo -e "\n${YELLOW}[4/6] 正在通过 acme.sh 申请域名的 TLS 真实证书...${PLAIN}"
rm -rf ~/.acme.sh
curl -sSL https://get.acme.sh | sh -s email=$EMAIL

if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
    git clone https://github.com/acmesh-official/acme.sh.git
    cd acme.sh && ./acme.sh --install -m $EMAIL && cd ..
fi

ACME_BIN="${HOME}/.acme.sh/acme.sh"
$ACME_BIN --upgrade --auto-upgrade
$ACME_BIN --set-default-ca --server letsencrypt

echo -e "${YELLOW}正在向 Let's Encrypt 验证域名并颁发证书...${PLAIN}"
$ACME_BIN --issue -d $DOMAIN --standalone --keylength ec-256 --force

if [ $? -ne 0 ]; then
    echo -e "${RED}错误：证书申请失败！请确认域名解析和80端口放行。${PLAIN}"
    exit 1
fi

mkdir -p /etc/vps-cert
$ACME_BIN --install-cert -d $DOMAIN --ecc \
    --key-file       /etc/vps-cert/private.key \
    --fullchain-file /etc/vps-cert/cert.crt

chmod 644 /etc/vps-cert/private.key
chmod 644 /etc/vps-cert/cert.crt

# ==================== 🛠️ 5. 安装并配置 Xray (动态注入最优域名) ====================
echo -e "\n${YELLOW}[5/6] 安装并配置 Xray-core 内核...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

REALITY_KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(head /dev/urandom | tr -dc a-f0-9 | head -c 16)

# 将自动挑选出的最优域名配置进 dest 和 serverNames
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
                    "dest": "$REALITY_DEST_DOMAIN:443",
                    "xver": 0,
                    "serverNames": [ "$REALITY_DEST_DOMAIN" ],
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

# ==================== 🌐 6. 配置 Nginx 网站伪装与反代 ====================
echo -e "\n${YELLOW}[6/6] 配置 Nginx 分流与网站防探测伪装...${PLAIN}"
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

# 安装并配置 Hysteria 2
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

# 防火墙
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT

# ==================== 🛠️ 自动拼接并生成节点链接 ====================

# VLESS 链接中的 sni 和 客户端配置里的 sni 应对应自动选择出的最优伪装域名
VLESS_LINK="vless://${UUID_VLESS}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS_Reality_AutoDomain"

VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "VMess_WS_TLS",
  "add": "${DOMAIN}",
  "port": "443",
  "id": "${UUID_VMESS}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${DOMAIN}",
  "path": "${WS_PATH}",
  "tlst": "tls",
  "sni": "${DOMAIN}",
  "alpn": ""
}
EOF
)
VMESS_BASE64=$(echo -n "$VMESS_JSON" | base64 | tr -d '\n')
VMESS_LINK="vmess://${VMESS_BASE64}"

HY2_LINK="hysteria2://${HY2_PASS}@${DOMAIN}:443?sni=${DOMAIN}&alpn=h3&insecure=0#Hysteria2_UDP"

# ==================== 🖨️ 打印结果 ====================
clear
echo -e "${GREEN}==================================================================${PLAIN}"
echo -e "  🎉 恭喜！多协议环境已成功搭建完成！BBR系统加速已全面加载生效！"
echo -e "  🔥 Reality 伪装域名已自动切换为最速配置: ${YELLOW}$REALITY_DEST_DOMAIN${PLAIN}"
echo -e "${GREEN}==================================================================${PLAIN}"

echo -e "\n${YELLOW}👉 节点【1】: VLESS - Reality (已优化：自动绑定延迟最低的 ${REALITY_DEST_DOMAIN})${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${VLESS_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$VLESS_LINK"

echo -e "\n${GREEN}------------------------------------------------------------------${PLAIN}"

echo -e "\n${YELLOW}👉 节点【2】: VMess - WS - TLS (Nginx 反向代理方案)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${VMESS_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$VMESS_LINK"

echo -e "\n${GREEN}------------------------------------------------------------------${PLAIN}"

echo -e "\n${YELLOW}👉 节点【3】: Hysteria 2 (UDP 协议强力加速方案)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${HY2_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$HY2_LINK"

echo -e "${GREEN}==================================================================${PLAIN}"
