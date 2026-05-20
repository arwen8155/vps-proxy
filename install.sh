#!/bin/bash

# 颜色定义
RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

clear
echo -e "${GREEN}==================================================================${PLAIN}"
echo -e "${GREEN}   VPS 多合一环境一键脚本 (无痕日志清理 + 纯净证书重置 + 最速BBR)   ${PLAIN}"
echo -e "${GREEN}==================================================================${PLAIN}"

# ==================== 🧹 0. 自动无痕清理旧节点、端口、证书与日志 🧹 ====================
echo -e "${YELLOW}[0/7] 正在执行全盘无痕深度清理（清理进程/端口/旧证书/所有日志）...${PLAIN}"

# 1. 强行停止并注销可能存在的旧服务进程
systemctl stop xray hysteria-server nginx >/dev/null 2>&1
systemctl disable xray hysteria-server nginx >/dev/null 2>&1

# 2. 安装 psmisc (确保端口释放工具可用)
apt update -y && apt install -y psmisc >/dev/null 2>&1

# 3. 强行粉碎并释放残留端口：80, 443, 8080
echo -e "${YELLOW}👉 正在强行释放端口占用: 80, 443, 8080...${PLAIN}"
fuser -k 80/tcp >/dev/null 2>&1
fuser -k 443/tcp >/dev/null 2>&1
fuser -k 443/udp >/dev/null 2>&1
fuser -k 8080/tcp >/dev/null 2>&1

# 4. 【核心新增】彻底摧毁并清空旧证书及 acme.sh 运行环境
echo -e "${YELLOW}👉 正在彻底清除并重置旧 TLS 证书环境...${PLAIN}"
rm -rf ~/.acme.sh >/dev/null 2>&1
rm -rf /etc/vps-cert >/dev/null 2>&1

# 5. 摧毁旧的节点配置文件及网页伪装目录
rm -rf /usr/local/etc/xray >/dev/null 2>&1
rm -rf /etc/hysteria >/dev/null 2>&1
rm -rf /etc/nginx/sites-available/default >/dev/null 2>&1
rm -rf /etc/nginx/sites-enabled/default >/dev/null 2>&1
rm -rf /var/www/html/* >/dev/null 2>&1

# 6. 【核心新增】全盘抹除旧服务的运行日志与系统审计日志（实现隐私保护）
echo -e "${YELLOW}👉 正在强制粉碎并清空所有残留运行日志与系统审计日志...${PLAIN}"
# 清空 Nginx、Xray、Hysteria 的物理日志文件
rm -rf /var/log/nginx/* >/dev/null 2>&1
rm -rf /var/log/xray/* >/dev/null 2>&1
# 截断（清空）Linux系统全局核心日志文件内容，但不删除文件本身（防止系统报错）
[ -f /var/log/syslog ] && cat /dev/null > /var/log/syslog
[ -f /var/log/auth.log ] && cat /dev/null > /var/log/auth.log
[ -f /var/log/daemon.log ] && cat /dev/null > /var/log/daemon.log
[ -f /var/log/messages ] && cat /dev/null > /var/log/messages
# 强制清空 systemd journald 内存及磁盘上的所有历史归档日志
journalctl --rotate >/dev/null 2>&1
journalctl --vacuum-time=1s >/dev/null 2>&1

echo -e "${GREEN}✔️ 旧节点已完全移除，旧证书与所有历史日志已成功全盘抹除！${PLAIN}\n"

# ==================== 📥 用户输入阶段 ====================
read -p "请输入你的新域名 (例如: proxy.example.com): " DOMAIN
read -p "请输入你的新邮箱 (用于重新申请证书): " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}错误：域名和邮箱不能为空！${PLAIN}"
    exit 1
fi

# ==================== 🚀 1. 自动开启 BBR 加速逻辑 ====================
echo -e "\n${YELLOW}[1/7] 正在检查并自动开启 BBR 系统加速...${PLAIN}"
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
        echo -e "${GREEN}【BBR状态】成功：BBR 拥塞控制算法已成功启动，TCP网络已全面加速！${PLAIN}"
    else
        echo -e "${RED}【BBR状态】警告：BBR 自动开启失败，可能由于虚拟化架构不支持。${PLAIN}"
    fi
fi

# ==================== ⚡ 2. 自动测速寻找最优伪装域名 ====================
echo -e "\n${YELLOW}[2/7] 正在对各大厂域名进行 TLS 握手测速，寻找最优 Reality 伪装目标...${PLAIN}"
echo -e "${YELLOW}请稍候，这可能需要 5-10 秒钟...${PLAIN}"

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

LOWEST_PING=${BEST_DOMAINS[0]}
REALITY_DEST_DOMAIN=${BEST_DOMAINS[1]}

if [ -z "$REALITY_DEST_DOMAIN" ]; then
    REALITY_DEST_DOMAIN="www.microsoft.com"
    LOWEST_PING="默认"
    echo -e "${YELLOW}测速未完全成功，已自动选择默认防探测域名: $REALITY_DEST_DOMAIN${PLAIN}"
else
    echo -e "${GREEN}✔️ 已成功找到当前 VPS 连接延迟最低的域名: ${YELLOW}$REALITY_DEST_DOMAIN${GREEN} (延迟: ${LOWEST_PING} ms)${PLAIN}"
fi

# 生成各种全新的随机参数
UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
UUID_VMESS=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
WS_PATH="/vmessws"

# ==================== 📦 3. 安装基础依赖与 Nginx ====================
echo -e "\n${YELLOW}[3/7] 正在全新安装基础依赖、Nginx及二维码工具...${PLAIN}"
apt install -y curl socat wget unzip nginx jq iptables git qrencode openssl

# ==================== 🔒 4. 重新从零申请 TLS 证书 ====================
echo -e "\n${YELLOW}[4/7] 正在全新安装 acme.sh 并申请纯净的 TLS 真实证书...${PLAIN}"
curl -sSL https://get.acme.sh | sh -s email=$EMAIL
if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
    git clone https://github.com/acmesh-official/acme.sh.git
    cd acme.sh && ./acme.sh --install -m $EMAIL && cd ..
fi

ACME_BIN="${HOME}/.acme.sh/acme.sh"
$ACME_BIN --upgrade --auto-upgrade
$ACME_BIN --set-default-ca --server letsencrypt

echo -e "${YELLOW}正在向 Let's Encrypt 验证新域名并发放全新证书...${PLAIN}"
$ACME_BIN --issue -d $DOMAIN --standalone --keylength ec-256 --force

if [ $? -ne 0 ]; then
    echo -e "${RED}错误：证书申请失败！请确认您的新域名 [${RED}$DOMAIN${PLAIN}] 是否已正确解析到此 VPS 且外部防火墙已放行 80 端口。${PLAIN}"
    exit 1
fi

mkdir -p /etc/vps-cert
$ACME_BIN --install-cert -d $DOMAIN --ecc \
    --key-file       /etc/vps-cert/private.key \
    --fullchain-file /etc/vps-cert/cert.crt

chmod 644 /etc/vps-cert/private.key
chmod 644 /etc/vps-cert/cert.crt

# ==================== 🛠️ 5. 配置全新 Xray (注入精准过滤密钥) ====================
echo -e "\n${YELLOW}[5/7] 配置全新的 Xray-core 内核...${PLAIN}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

xray x25519 > /tmp/xkeys
PRIVATE_KEY=$(grep "Private key:" /tmp/xkeys | awk -F': ' '{print $2}' | tr -d '[:space:]')
PUBLIC_KEY=$(grep "Public key:" /tmp/xkeys | awk -F': ' '{print $2}' | tr -d '[:space:]')
SHORT_ID=$(head /dev/urandom | tr -dc a-f0-9 | head -c 16)
rm -f /tmp/xkeys

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

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ==================== 🌐 6. 配置全新 Nginx 网站伪装与反代 ====================
echo -e "\n${YELLOW}[6/7] 配置 Nginx 网页分流与伪装...${PLAIN}"
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

# ==================== ⚡ 7. 配置全新 Hysteria 2 ====================
echo -e "\n${YELLOW}[7/7] 全新配置 Hysteria 2 核心...${PLAIN}"
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

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 放行系统防火墙端口
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT

# ==================== 🛠️ 全新拼接节点链接 ====================
VLESS_LINK="vless://${UUID_VLESS}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS_Reality_Fresh"

VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "VMess_WS_Fresh",
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

HY2_LINK="hysteria2://${HY2_PASS}@${DOMAIN}:443?sni=${DOMAIN}&alpn=h3&insecure=0#Hysteria2_UDP_Fresh"

# ==================== 🖨️ 打印结果 ====================
clear
echo -e "${GREEN}==================================================================${PLAIN}"
echo -e "  🎉 深度洗净！历史日志及证书已全盘清空，全新环境已成功搭建完成！"
echo -e "  🔥 经测速，已自动为您选用当前最速 Reality 伪装域名: ${YELLOW}$REALITY_DEST_DOMAIN${PLAIN}"
echo -e "${GREEN}==================================================================${PLAIN}"

echo -e "\n${YELLOW}👉 节点【1】: VLESS - Reality (AnyTLS 纯净全新配置)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${VLESS_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$VLESS_LINK"

echo -e "\n${GREEN}------------------------------------------------------------------${PLAIN}"

echo -e "\n${YELLOW}👉 节点【2】: VMess - WS - TLS (纯净全新反代配置)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${VMESS_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$VMESS_LINK"

echo -e "\n${GREEN}------------------------------------------------------------------${PLAIN}"

echo -e "\n${YELLOW}👉 节点【3】: Hysteria 2 (纯净全新 UDP 暴风加速配置)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${HY2_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$HY2_LINK"

echo -e "${GREEN}==================================================================${PLAIN}"
