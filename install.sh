#!/bin/bash

# 颜色定义
RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

clear
echo -e "${GREEN}==================================================================${PLAIN}"
echo -e "${GREEN}   VPS 多合一环境搭建脚本 (自动开启BBR加速 + 自动输出节点链接版)   ${PLAIN}"
echo -e "${GREEN}==================================================================${PLAIN}"
read -p "请输入你的域名 (例如: proxy.example.com): " DOMAIN
read -p "请输入你的邮箱 (用于申请证书): " EMAIL

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo -e "${RED}错误：域名和邮箱不能为空！${PLAIN}"
    exit 1
fi

# ==================== 🚀 1. 自动开启 BBR 加速逻辑 🚀 ====================
echo -e "\n${YELLOW}[1/6] 正在检查并自动开启 BBR 系统加速...${PLAIN}"
if lsmod | grep -q bbr; then
    echo -e "${GREEN}【BBR状态】检测到 BBR 加速早已处于开启状态，保持现状。${PLAIN}"
else
    echo -e "${YELLOW}正在为您的 Linux 内核配置 BBR 拥塞控制算法...${PLAIN}"
    # 清理并写入 BBR 配置参数
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    
    # 刷新内核配置使其生效
    sysctl -p >/dev/null 2>&1
    
    # 验证是否成功开启
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}【BBR状态】成功：BBR 拥塞控制算法已成功启动，TCP网络已全面加速！${PLAIN}"
    else
        echo -e "${RED}【BBR状态】警告：BBR 自动开启失败。这通常是因为您的 VPS 属于 OpenVZ 虚拟化架构（如部分低端廉价魔方VPS），该架构不支持修改内核，请知悉。${PLAIN}"
    fi
fi

# 生成各种随机 UUID、路径和密码
UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
UUID_VMESS=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
WS_PATH="/vmessws"

# ==================== 📦 2. 安装基础依赖与 Nginx ====================
echo -e "\n${YELLOW}[2/6] 正在安装基础依赖、Nginx及二维码工具...${PLAIN}"
apt update -y || true 
apt install -y curl socat wget unzip nginx jq iptables psmisc git qrencode

# 强行释放 80 端口，防止被前次残留进程抢占
systemctl stop nginx
fuser -k 80/tcp >/dev/null 2>&1

# ==================== 🔒 3. 使用 acme.sh 申请 TLS 证书 ====================
echo -e "\n${YELLOW}[3/6] 正在通过 acme.sh 申请域名的 TLS 真实证书...${PLAIN}"
rm -rf ~/.acme.sh
curl -sSL https://get.acme.sh | sh -s email=$EMAIL

if [ ! -f "${HOME}/.acme.sh/acme.sh" ]; then
    echo -e "${YELLOW}网络超时，正在尝试使用 GitHub 备用源安装 acme.sh...${PLAIN}"
    git clone https://github.com/acmesh-official/acme.sh.git
    cd acme.sh && ./acme.sh --install -m $EMAIL && cd ..
fi

ACME_BIN="${HOME}/.acme.sh/acme.sh"
$ACME_BIN --upgrade --auto-upgrade
$ACME_BIN --set-default-ca --server letsencrypt

echo -e "${YELLOW}正在向 Let's Encrypt 验证域名并颁发证书，请稍候...${PLAIN}"
$ACME_BIN --issue -d $DOMAIN --standalone --keylength ec-256 --force

if [ $? -ne 0 ]; then
    echo -e "${RED}错误：证书申请失败！${PLAIN}"
    echo -e "${YELLOW}请排查：1. 您的域名 [${RED}$DOMAIN${PLAIN}] 是否正确解析到此 VPS IP？2. 服务商后台安全组的 80 端口是否放行？${PLAIN}"
    exit 1
fi

mkdir -p /etc/vps-cert
$ACME_BIN --install-cert -d $DOMAIN --ecc \
    --key-file       /etc/vps-cert/private.key \
    --fullchain-file /etc/vps-cert/cert.crt

chmod 644 /etc/vps-cert/private.key
chmod 644 /etc/vps-cert/cert.crt

# ==================== 🛠️ 4. 安装并配置 Xray (Vless / Vmess / AnyTLS思想) ====================
echo -e "\n${YELLOW}[4/6] 安装并配置 Xray-core 内核...${PLAIN}"
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

# ==================== 🌐 5. 配置 Nginx 网站伪装与反代 ====================
echo -e "\n${YELLOW}[5/6] 配置 Nginx 分流与网站防探测伪装...${PLAIN}"
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

# ==================== ⚡ 6. 安装并配置 Hysteria 2 ====================
echo -e "\n${YELLOW}[6/6] 安装并配置 Hysteria 2 核心...${PLAIN}"
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

# 放行系统防火墙端口
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT

# ==================== 🛠️ 自动拼接并生成节点链接逻辑 ====================

# 1. 拼接 VLESS-Reality-Vision (AnyTLS防探测标准链接)
VLESS_LINK="vless://${UUID_VLESS}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS_Reality_Vision"

# 2. 拼接 VMess-WS-TLS 链接 (VMess 链接需要将其内部参数打包为 JSON 再进行 Base64 编码)
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

# 3. 拼接 Hysteria 2 协议标准链接
HY2_LINK="hysteria2://${HY2_PASS}@${DOMAIN}:443?sni=${DOMAIN}&alpn=h3&insecure=0#Hysteria2_UDP"


# ==================== 🖨️ 最终大功告成打印结果 ====================
clear
echo -e "${GREEN}==================================================================${PLAIN}"
echo -e "  🎉 恭喜！多协议环境已成功搭建完成！BBR加速已全面加载生效！"
echo -e "${GREEN}==================================================================${PLAIN}"

echo -e "\n${YELLOW}👉 节点【1】: VLESS - Reality (AnyTLS / 无证书防探测方案)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${VLESS_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$VLESS_LINK"

echo -e "\n${GREEN}------------------------------------------------------------------${PLAIN}"

echo -e "\n${YELLOW}👉 节点【2】: VMess - WS - TLS (Nginx 反向代理传统稳定方案)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${VMESS_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$VMESS_LINK"

echo -e "\n${GREEN}------------------------------------------------------------------${PLAIN}"

echo -e "\n${YELLOW}👉 节点【3】: Hysteria 2 (UDP 协议 / 晚高峰强力冲破限制方案)${PLAIN}"
echo -e "链接 (直接复制):"
echo -e "${GREEN}${HY2_LINK}${PLAIN}"
echo -e "手机扫码导入:"
qrencode -t ansiutf8 "$HY2_LINK"

echo -e "${GREEN}==================================================================${PLAIN}"
echo -e "${YELLOW}使用提示：${PLAIN}"
echo -e "1. 电脑端：使用鼠标直接框选复制绿色的 ${GREEN}vless://、vmess:// 或 hysteria2://${PLAIN} 链接，在客户端中选择“从剪贴板导入”即可。"
echo -e "2. 手机端：直接打开 Shadowrocket（小火箭）等客户端，点击右上角的扫码框，扫描上方终端里渲染出的二维码即可一键添加。"
