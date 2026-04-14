#!/bin/bash
# =====================================================
#  Xray VLESS Reality 中转 → SOCKS5 住宅节点 万能部署脚本
#  By Wayne Shen
# =====================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
INFO_FILE="/root/xray_nodes_info.txt"

# ========== 工具函数 ==========
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Xray VLESS Reality 中转部署工具 v2.0       ║"
    echo "║   支持多节点 · 一键部署 · 自动优化           ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

get_ip() {
    IP=$(curl -s4 ip.sb 2>/dev/null || curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null)
    if [ -z "$IP" ]; then
        echo -e "${RED}无法获取本机公网 IP，请手动输入:${NC}"
        read -p "VPS 公网 IP: " IP
    fi
    echo "$IP"
}

# ========== 更新操作系统 ==========
update_system() {
    echo -e "${GREEN}[步骤0] 更新操作系统...${NC}"
    
    if command -v apt &>/dev/null; then
        # Debian / Ubuntu
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
        apt autoremove -y
        echo -e "  ${GREEN}✓ 系统已更新 (apt)${NC}"
    elif command -v yum &>/dev/null; then
        # CentOS / RHEL
        yum update -y
        echo -e "  ${GREEN}✓ 系统已更新 (yum)${NC}"
    elif command -v dnf &>/dev/null; then
        # Fedora
        dnf update -y
        echo -e "  ${GREEN}✓ 系统已更新 (dnf)${NC}"
    else
        echo -e "  ${YELLOW}⚠ 未识别的包管理器，跳过系统更新${NC}"
    fi
}

# ========== 安装 Xray ==========
install_xray() {
    echo -e "${GREEN}[步骤1] 检查并安装 Xray...${NC}"
    if command -v xray &> /dev/null; then
        echo "Xray 已安装: $(xray version | head -1)"
    else
        echo "正在安装 Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
    mkdir -p /var/log/xray
}

# ========== 生成密钥对 ==========
generate_keys() {
    echo -e "${GREEN}[步骤2] 生成 Reality x25519 密钥对...${NC}"
    KEY_OUTPUT=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "public" | awk '{print $NF}')
    SHORT_ID=$(openssl rand -hex 8 2>/dev/null || head -c 16 /dev/urandom | xxd -p | head -c 16)
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
    echo -e "  Private Key: ${YELLOW}${PRIVATE_KEY}${NC}"
    echo -e "  Public Key:  ${YELLOW}${PUBLIC_KEY}${NC}"
    echo -e "  UUID:        ${YELLOW}${UUID}${NC}"
    echo -e "  Short ID:    ${YELLOW}${SHORT_ID}${NC}"
}

# ========== 收集节点信息 ==========
collect_nodes() {
    echo ""
    echo -e "${GREEN}[步骤3] 添加 SOCKS5 住宅节点${NC}"
    echo -e "${CYAN}格式: IP:端口:用户名:密码${NC}"
    echo -e "${CYAN}例如: 161.77.77.5:12324:14a0f0ecfa3d6:384cafa39d${NC}"
    echo ""

    NODES=()
    NODE_NUM=0
    BASE_PORT=443

    while true; do
        NODE_NUM=$((NODE_NUM + 1))
        read -p "节点${NODE_NUM} (输入 done 结束): " INPUT

        if [ "$INPUT" = "done" ] || [ "$INPUT" = "d" ] || [ -z "$INPUT" ]; then
            if [ ${#NODES[@]} -eq 0 ]; then
                echo -e "${RED}至少需要一个节点！${NC}"
                NODE_NUM=0
                continue
            fi
            break
        fi

        # 解析 IP:端口:用户名:密码
        IFS=':' read -r S_HOST S_PORT S_USER S_PASS <<< "$INPUT"

        if [ -z "$S_HOST" ] || [ -z "$S_PORT" ] || [ -z "$S_USER" ] || [ -z "$S_PASS" ]; then
            echo -e "${RED}格式错误，请使用 IP:端口:用户名:密码${NC}"
            NODE_NUM=$((NODE_NUM - 1))
            continue
        fi

        # 为每个节点分配端口
        if [ $NODE_NUM -eq 1 ]; then
            LISTEN_PORT=443
        else
            LISTEN_PORT=$((8442 + NODE_NUM))
        fi

        read -p "  备注名称 (如 KR-Seoul / US-LA，回车跳过): " NODE_NAME
        [ -z "$NODE_NAME" ] && NODE_NAME="Node-${NODE_NUM}"

        NODES+=("${LISTEN_PORT}|${S_HOST}|${S_PORT}|${S_USER}|${S_PASS}|${NODE_NAME}")
        echo -e "${GREEN}  ✓ 已添加: ${NODE_NAME} → ${S_HOST}:${S_PORT} (监听端口: ${LISTEN_PORT})${NC}"
        echo ""
    done
}

# ========== 生成配置文件 ==========
generate_config() {
    echo -e "${GREEN}[步骤4] 生成 Xray 配置文件...${NC}"

    # 构建 inbounds
    INBOUNDS=""
    OUTBOUNDS=""
    RULES=""

    for i in "${!NODES[@]}"; do
        IFS='|' read -r PORT S_HOST S_PORT S_USER S_PASS NAME <<< "${NODES[$i]}"
        TAG_IN="vless-in-$((i+1))"
        TAG_OUT="socks5-out-$((i+1))"

        # Inbound
        [ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
        INBOUNDS="${INBOUNDS}
        {
            \"tag\":\"${TAG_IN}\",
            \"port\":${PORT},
            \"protocol\":\"vless\",
            \"settings\":{
                \"clients\":[{\"id\":\"${UUID}\",\"flow\":\"xtls-rprx-vision\"}],
                \"decryption\":\"none\"
            },
            \"streamSettings\":{
                \"network\":\"tcp\",
                \"security\":\"reality\",
                \"realitySettings\":{
                    \"dest\":\"www.microsoft.com:443\",
                    \"serverNames\":[\"www.microsoft.com\"],
                    \"privateKey\":\"${PRIVATE_KEY}\",
                    \"shortIds\":[\"${SHORT_ID}\"]
                },
                \"sockopt\":{\"tcpFastOpen\":true,\"tcpNoDelay\":true}
            },
            \"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}
        }"

        # Outbound
        [ -n "$OUTBOUNDS" ] && OUTBOUNDS="${OUTBOUNDS},"
        OUTBOUNDS="${OUTBOUNDS}
        {
            \"tag\":\"${TAG_OUT}\",
            \"protocol\":\"socks\",
            \"settings\":{\"servers\":[{
                \"address\":\"${S_HOST}\",
                \"port\":${S_PORT},
                \"users\":[{\"user\":\"${S_USER}\",\"pass\":\"${S_PASS}\"}]
            }]},
            \"streamSettings\":{\"sockopt\":{\"tcpFastOpen\":true,\"tcpNoDelay\":true}}
        }"

        # Routing rule
        [ -n "$RULES" ] && RULES="${RULES},"
        RULES="${RULES}
            {\"type\":\"field\",\"inboundTag\":[\"${TAG_IN}\"],\"outboundTag\":\"${TAG_OUT}\"}"
    done

    # 写入配置
    cat > "$CONFIG_FILE" << EOF
{
    "log":{"loglevel":"warning"},
    "stats":{},
    "api":{
        "tag":"api",
        "services":["StatsService"]
    },
    "policy":{
        "system":{
            "statsInboundUplink":true,
            "statsInboundDownlink":true,
            "statsOutboundUplink":true,
            "statsOutboundDownlink":true
        }
    },
    "inbounds":[
        {
            "tag":"api-in",
            "port":10085,
            "listen":"127.0.0.1",
            "protocol":"dokodemo-door",
            "settings":{"address":"127.0.0.1"}
        },${INBOUNDS}
    ],
    "outbounds":[${OUTBOUNDS},
        {"tag":"direct","protocol":"freedom"},
        {"tag":"block","protocol":"blackhole"}
    ],
    "routing":{
        "domainStrategy":"AsIs",
        "rules":[
            {"type":"field","inboundTag":["api-in"],"outboundTag":"api"},
            {"type":"field","outboundTag":"block","protocol":["bittorrent"]},
            {"type":"field","outboundTag":"direct","ip":["geoip:private"]},${RULES}
        ]
    }
}
EOF
    echo -e "  ✓ 配置已写入 ${CONFIG_FILE}"
    echo -e "  ✓ 流量统计 API 已启用 (端口 10085)"
}

# ========== 系统优化 ==========
optimize_system() {
    echo -e "${GREEN}[步骤5] 系统优化 (BBR + 内核参数)...${NC}"

    # 检查是否已优化
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo "  BBR 已启用，跳过重复配置"
    else
        cat >> /etc/sysctl.conf << 'EOF'

# === Xray 中转优化 ===
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_tw_reuse=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=8192
net.core.somaxconn=8192
EOF
        sysctl -p 2>/dev/null
        echo "  ✓ BBR 和内核参数已优化"
    fi

    # 文件描述符
    if ! grep -q "LimitNOFILE=65535" /etc/systemd/system/xray.service.d/limits.conf 2>/dev/null; then
        mkdir -p /etc/systemd/system/xray.service.d
        cat > /etc/systemd/system/xray.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF
        echo "  ✓ 文件描述符限制已提升"
    fi

    # Swap
    if [ ! -f /swapfile ]; then
        fallocate -l 1G /swapfile 2>/dev/null && \
        chmod 600 /swapfile && \
        mkswap /swapfile 2>/dev/null && \
        swapon /swapfile 2>/dev/null && \
        echo '/swapfile none swap sw 0 0' >> /etc/fstab && \
        echo "  ✓ 1G Swap 已添加"
    else
        echo "  Swap 已存在，跳过"
    fi
}

# ========== 防火墙 ==========
setup_firewall() {
    echo -e "${GREEN}[步骤6] 配置防火墙...${NC}"
    for NODE in "${NODES[@]}"; do
        IFS='|' read -r PORT _ _ _ _ _ <<< "$NODE"
        ufw allow "$PORT" 2>/dev/null || true
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        echo "  ✓ 端口 ${PORT} 已放行"
    done
}

# ========== 启动服务 ==========
start_service() {
    echo -e "${GREEN}[步骤7] 启动 Xray...${NC}"
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 2

    if systemctl is-active --quiet xray; then
        echo -e "  ${GREEN}✓ Xray 启动成功！${NC}"
    else
        echo -e "  ${RED}✗ 启动失败，查看日志: journalctl -u xray -n 20${NC}"
        exit 1
    fi
}

# ========== 输出结果 ==========
print_result() {
    VPS_IP=$(get_ip)

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              部署完成！                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    > "$INFO_FILE"

    for i in "${!NODES[@]}"; do
        IFS='|' read -r PORT S_HOST S_PORT S_USER S_PASS NAME <<< "${NODES[$i]}"

        LINK="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NAME}"

        echo -e "${GREEN}━━━ ${NAME} ━━━${NC}"
        echo -e "  监听端口: ${PORT}"
        echo -e "  落地节点: ${S_HOST}:${S_PORT}"
        echo -e "${YELLOW}  ${LINK}${NC}"
        echo ""

        echo "=== ${NAME} ===" >> "$INFO_FILE"
        echo "端口: ${PORT}" >> "$INFO_FILE"
        echo "落地: ${S_HOST}:${S_PORT}" >> "$INFO_FILE"
        echo "链接: ${LINK}" >> "$INFO_FILE"
        echo "" >> "$INFO_FILE"
    done

    echo -e "${GREEN}━━━ 通用信息 ━━━${NC}"
    echo -e "  VPS IP:     ${VPS_IP}"
    echo -e "  UUID:       ${UUID}"
    echo -e "  Public Key: ${PUBLIC_KEY}"
    echo -e "  Short ID:   ${SHORT_ID}"
    echo ""
    echo -e "${GREEN}所有链接已保存到 ${INFO_FILE}${NC}"
}

# ========== 添加节点（不重装） ==========
add_node() {
    echo -e "${GREEN}[添加节点模式]${NC}"
    
    VPS_IP=$(get_ip)
    
    # 读取现有配置中的密钥信息
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到现有配置，请先完整安装！${NC}"
        exit 1
    fi

    PRIVATE_KEY=$(grep -o '"privateKey":"[^"]*"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    SHORT_ID=$(grep -o '"shortIds":\["[^"]*"\]' "$CONFIG_FILE" | head -1 | grep -o '"[a-f0-9]*"' | tail -1 | tr -d '"')
    UUID=$(grep -o '"id":"[^"]*"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    
    # 生成 public key
    PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -i "public" | awk '{print $NF}')

    # 获取当前最大端口
    MAX_PORT=$(grep -o '"port":[0-9]*' "$CONFIG_FILE" | grep -o '[0-9]*' | sort -n | tail -1)
    [ -z "$MAX_PORT" ] && MAX_PORT=443

    echo -e "当前最大端口: ${MAX_PORT}"
    echo ""
    echo -e "${CYAN}输入新的 SOCKS5 节点 (格式: IP:端口:用户名:密码)${NC}"
    read -p "节点信息: " INPUT

    IFS=':' read -r S_HOST S_PORT S_USER S_PASS <<< "$INPUT"
    if [ -z "$S_HOST" ] || [ -z "$S_PORT" ] || [ -z "$S_USER" ] || [ -z "$S_PASS" ]; then
        echo -e "${RED}格式错误！${NC}"
        exit 1
    fi

    read -p "备注名称: " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="Node-new"

    NEW_PORT=$((MAX_PORT == 443 ? 8443 : MAX_PORT + 1))
    TAG_NUM=$(grep -c '"tag":"vless-in-' "$CONFIG_FILE" 2>/dev/null)
    TAG_NUM=$((TAG_NUM + 1))

    # 构建新的 inbound
    NEW_INBOUND=",
        {
            \"tag\":\"vless-in-${TAG_NUM}\",
            \"port\":${NEW_PORT},
            \"protocol\":\"vless\",
            \"settings\":{
                \"clients\":[{\"id\":\"${UUID}\",\"flow\":\"xtls-rprx-vision\"}],
                \"decryption\":\"none\"
            },
            \"streamSettings\":{
                \"network\":\"tcp\",
                \"security\":\"reality\",
                \"realitySettings\":{
                    \"dest\":\"www.microsoft.com:443\",
                    \"serverNames\":[\"www.microsoft.com\"],
                    \"privateKey\":\"${PRIVATE_KEY}\",
                    \"shortIds\":[\"${SHORT_ID}\"]
                },
                \"sockopt\":{\"tcpFastOpen\":true,\"tcpNoDelay\":true}
            },
            \"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}
        }"

    NEW_OUTBOUND=",
        {
            \"tag\":\"socks5-out-${TAG_NUM}\",
            \"protocol\":\"socks\",
            \"settings\":{\"servers\":[{
                \"address\":\"${S_HOST}\",
                \"port\":${S_PORT},
                \"users\":[{\"user\":\"${S_USER}\",\"pass\":\"${S_PASS}\"}]
            }]},
            \"streamSettings\":{\"sockopt\":{\"tcpFastOpen\":true,\"tcpNoDelay\":true}}
        }"

    NEW_RULE=",
            {\"type\":\"field\",\"inboundTag\":[\"vless-in-${TAG_NUM}\"],\"outboundTag\":\"socks5-out-${TAG_NUM}\"}"

    # 插入配置 (用 python 处理 JSON 更安全)
    python3 << PYEOF
import json

with open("${CONFIG_FILE}", "r") as f:
    config = json.load(f)

config["inbounds"].append({
    "tag": "vless-in-${TAG_NUM}",
    "port": ${NEW_PORT},
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "www.microsoft.com:443",
            "serverNames": ["www.microsoft.com"],
            "privateKey": "${PRIVATE_KEY}",
            "shortIds": ["${SHORT_ID}"]
        },
        "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
})

# 在 direct 之前插入新 outbound
new_out = {
    "tag": "socks5-out-${TAG_NUM}",
    "protocol": "socks",
    "settings": {"servers": [{
        "address": "${S_HOST}",
        "port": ${S_PORT},
        "users": [{"user": "${S_USER}", "pass": "${S_PASS}"}]
    }]},
    "streamSettings": {"sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}}
}
# 插入到 direct 之前
for idx, ob in enumerate(config["outbounds"]):
    if ob.get("tag") == "direct":
        config["outbounds"].insert(idx, new_out)
        break
else:
    config["outbounds"].append(new_out)

# 添加路由规则
new_rule = {"type": "field", "inboundTag": ["vless-in-${TAG_NUM}"], "outboundTag": "socks5-out-${TAG_NUM}"}
config["routing"]["rules"].append(new_rule)

with open("${CONFIG_FILE}", "w") as f:
    json.dump(config, f, indent=4)

print("配置已更新")
PYEOF

    # 放行端口
    ufw allow "$NEW_PORT" 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null || true

    # 重启
    systemctl restart xray
    sleep 2

    if systemctl is-active --quiet xray; then
        LINK="vless://${UUID}@${VPS_IP}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"
        echo ""
        echo -e "${GREEN}✓ 节点添加成功！${NC}"
        echo -e "${GREEN}端口: ${NEW_PORT}${NC}"
        echo -e "${GREEN}落地: ${S_HOST}:${S_PORT}${NC}"
        echo -e "${YELLOW}${LINK}${NC}"

        echo "" >> "$INFO_FILE"
        echo "=== ${NODE_NAME} ===" >> "$INFO_FILE"
        echo "端口: ${NEW_PORT}" >> "$INFO_FILE"
        echo "落地: ${S_HOST}:${S_PORT}" >> "$INFO_FILE"
        echo "链接: ${LINK}" >> "$INFO_FILE"
    else
        echo -e "${RED}重启失败: journalctl -u xray -n 20${NC}"
    fi
}

# ========== 查看状态 ==========
show_status() {
    echo -e "${GREEN}━━━ Xray 状态 ━━━${NC}"
    systemctl status xray --no-pager -l
    echo ""
    echo -e "${GREEN}━━━ BBR 状态 ━━━${NC}"
    sysctl net.ipv4.tcp_congestion_control
    echo ""
    echo -e "${GREEN}━━━ 节点信息 ━━━${NC}"
    if [ -f "$INFO_FILE" ]; then
        cat "$INFO_FILE"
    else
        echo "暂无节点信息"
    fi
}

# ========== 流量统计 ==========
TRAFFIC_DB="/root/.xray_traffic_db"

# 安装流量记录定时任务
setup_traffic_cron() {
    CRON_SCRIPT="/root/.xray_traffic_record.sh"
    
    cat > "$CRON_SCRIPT" << 'CRONEOF'
#!/bin/bash
CONFIG_FILE="/usr/local/etc/xray/config.json"
TRAFFIC_DB="/root/.xray_traffic_db"
XRAY_BIN="/usr/local/bin/xray"
TIMESTAMP=$(date +%s)

[ ! -f "$CONFIG_FILE" ] && exit 0
command -v xray &>/dev/null || exit 0

get_stat() {
    local result=$($XRAY_BIN api stats --server=127.0.0.1:10085 -name="$1" 2>/dev/null)
    echo "$result" | grep -i "value:" | awk '{print $NF}'
}

python3 << PYEOF
import json, subprocess, os, time

config_file = "$CONFIG_FILE"
db_file = "$TRAFFIC_DB"
xray_bin = "$XRAY_BIN"
timestamp = int("$TIMESTAMP")

with open(config_file, "r") as f:
    config = json.load(f)

def get_stat(name):
    try:
        result = subprocess.run([xray_bin, "api", "stats", "--server=127.0.0.1:10085", f"-name={name}"],
                                capture_output=True, text=True, timeout=5)
        for line in result.stdout.strip().split("\n"):
            if "value:" in line.lower():
                val = line.split(":")[-1].strip()
                return int(val) if val else 0
    except:
        pass
    return 0

records = []
for inb in config.get("inbounds", []):
    tag = inb.get("tag", "")
    if tag == "api-in" or not tag:
        continue
    port = inb.get("port", 0)
    up = get_stat(f"inbound>>>{tag}>>>traffic>>>uplink")
    down = get_stat(f"inbound>>>{tag}>>>traffic>>>downlink")
    records.append(f"{timestamp}|{tag}|{port}|{up}|{down}")

# 追加到数据库
with open(db_file, "a") as f:
    for r in records:
        f.write(r + "\n")

# 清理超过60天的旧数据
cutoff = timestamp - 60 * 86400
if os.path.exists(db_file):
    with open(db_file, "r") as f:
        lines = f.readlines()
    with open(db_file, "w") as f:
        for line in lines:
            parts = line.strip().split("|")
            if len(parts) >= 5 and int(parts[0]) > cutoff:
                f.write(line)
PYEOF
CRONEOF

    chmod +x "$CRON_SCRIPT"
    
    # 添加 crontab（每5分钟记录一次）
    if ! crontab -l 2>/dev/null | grep -q "xray_traffic_record"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * /root/.xray_traffic_record.sh # xray_traffic_record") | crontab -
        echo -e "  ${GREEN}✓ 流量记录定时任务已安装 (每5分钟)${NC}"
    fi
}

show_traffic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件！${NC}"
        return
    fi

    if ! grep -q '"StatsService"' "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}当前配置未启用流量统计 API${NC}"
        echo -e "${YELLOW}需要重新全新安装(选1)才能使用${NC}"
        return
    fi

    # 确保定时任务已安装
    setup_traffic_cron
    # 立即记录一次当前快照
    bash /root/.xray_traffic_record.sh 2>/dev/null

    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              节点流量统计                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    python3 << 'PYEOF'
import json, subprocess, os, time
from collections import defaultdict

config_file = "/usr/local/etc/xray/config.json"
db_file = "/root/.xray_traffic_db"
xray_bin = "/usr/local/bin/xray"

with open(config_file, "r") as f:
    config = json.load(f)

def get_stat(name):
    try:
        result = subprocess.run([xray_bin, "api", "stats", "--server=127.0.0.1:10085", f"-name={name}"],
                                capture_output=True, text=True, timeout=5)
        for line in result.stdout.strip().split("\n"):
            if "value:" in line.lower():
                val = line.split(":")[-1].strip()
                return int(val) if val else 0
    except:
        pass
    return 0

def format_bytes(b):
    b = abs(b)
    if b < 1024:
        return f"{b} B"
    elif b < 1024**2:
        return f"{b/1024:.1f} KB"
    elif b < 1024**3:
        return f"{b/1024**2:.1f} MB"
    else:
        return f"{b/1024**3:.2f} GB"

def get_dest(tag):
    for rule in config.get("routing", {}).get("rules", []):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            out_tag = rule.get("outboundTag", "")
            for ob in config["outbounds"]:
                if ob.get("tag") == out_tag:
                    servers = ob.get("settings", {}).get("servers", [])
                    if servers:
                        return servers[0]["address"]
    return ""

# ===== 当前实时流量（从 API） =====
print("  ━━━ 当前实时 (自上次启动) ━━━")
print(f"  {'节点':<22} {'上行':>10} {'下行':>10} {'合计':>10}")
print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")

total_up = 0
total_down = 0

for inb in config.get("inbounds", []):
    tag = inb.get("tag", "")
    if tag == "api-in" or not tag:
        continue
    port = inb.get("port", "?")
    dest = get_dest(tag)
    up = get_stat(f"inbound>>>{tag}>>>traffic>>>uplink")
    down = get_stat(f"inbound>>>{tag}>>>traffic>>>downlink")
    total = up + down
    total_up += up
    total_down += down
    name = f":{port}→{dest}" if dest else f":{port}"
    print(f"  {name:<22} {format_bytes(up):>10} {format_bytes(down):>10} {format_bytes(total):>10}")

print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
print(f"  {'总计':<22} {format_bytes(total_up):>10} {format_bytes(total_down):>10} {format_bytes(total_up+total_down):>10}")

# ===== 历史流量统计 =====
if not os.path.exists(db_file):
    print("\n  历史数据尚未积累，请等待5分钟后再查看")
else:
    # 读取所有记录
    records = []  # [(timestamp, tag, port, up, down)]
    with open(db_file, "r") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 5:
                try:
                    records.append((int(parts[0]), parts[1], int(parts[2]), int(parts[3]), int(parts[4])))
                except:
                    pass

    if records:
        now = int(time.time())
        periods = [
            ("过去1小时", now - 3600),
            ("今天", now - (now % 86400)),
            ("过去7天", now - 7 * 86400),
            ("过去30天", now - 30 * 86400),
        ]

        # 获取所有节点标签
        tags = set()
        for r in records:
            tags.add((r[1], r[2]))  # (tag, port)

        for period_name, since in periods:
            print(f"\n  ━━━ {period_name} ━━━")
            print(f"  {'节点':<22} {'上行':>10} {'下行':>10} {'合计':>10}")
            print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")

            p_total_up = 0
            p_total_down = 0

            for tag, port in sorted(tags, key=lambda x: x[1]):
                # 找该时间段内最早和最晚的记录
                tag_records = [(r[0], r[3], r[4]) for r in records if r[1] == tag and r[0] >= since]
                
                if len(tag_records) < 2:
                    # 数据不够，用当前值减去最早记录
                    if tag_records:
                        # 只有一条，用当前API值减去那条
                        cur_up = get_stat(f"inbound>>>{tag}>>>traffic>>>uplink")
                        cur_down = get_stat(f"inbound>>>{tag}>>>traffic>>>downlink")
                        up = cur_up - tag_records[0][1]
                        down = cur_down - tag_records[0][2]
                        up = max(0, up)
                        down = max(0, down)
                    else:
                        up = 0
                        down = 0
                else:
                    # 最新减最早
                    earliest = min(tag_records, key=lambda x: x[0])
                    latest = max(tag_records, key=lambda x: x[0])
                    up = max(0, latest[1] - earliest[1])
                    down = max(0, latest[2] - earliest[2])

                total = up + down
                p_total_up += up
                p_total_down += down
                dest = get_dest(tag)
                name = f":{port}→{dest}" if dest else f":{port}"
                print(f"  {name:<22} {format_bytes(up):>10} {format_bytes(down):>10} {format_bytes(total):>10}")

            print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
            print(f"  {'总计':<22} {format_bytes(p_total_up):>10} {format_bytes(p_total_down):>10} {format_bytes(p_total_up+p_total_down):>10}")

PYEOF

    echo ""
    echo -e "${YELLOW}流量每5分钟自动记录一次，历史数据保留60天${NC}"
    echo ""
    echo "  r) 重置当前计数"
    echo "  c) 清除历史数据"
    echo "  其他) 返回"
    read -p "  选择: " ACTION
    case $ACTION in
        r)
            xray api stats --server=127.0.0.1:10085 -reset 2>/dev/null
            echo -e "${GREEN}✓ 当前计数已重置${NC}"
            ;;
        c)
            rm -f "$TRAFFIC_DB"
            echo -e "${GREEN}✓ 历史数据已清除${NC}"
            ;;
    esac
}

# ========== 修改端口 ==========
change_port() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件！${NC}"
        return
    fi

    echo -e "${GREEN}[修改端口]${NC}"
    echo "当前节点端口:"
    python3 << 'PYEOF'
import json
with open("/usr/local/etc/xray/config.json", "r") as f:
    config = json.load(f)
for i, inb in enumerate(config["inbounds"]):
    tag = inb.get("tag", "unknown")
    port = inb.get("port", "?")
    # 找到对应的出站落地信息
    out_tag = None
    for rule in config.get("routing", {}).get("rules", []):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            out_tag = rule.get("outboundTag")
            break
    dest = ""
    if out_tag:
        for ob in config["outbounds"]:
            if ob.get("tag") == out_tag:
                servers = ob.get("settings", {}).get("servers", [])
                if servers:
                    dest = f" → {servers[0]['address']}:{servers[0]['port']}"
                break
    print(f"  {i+1}) 端口 {port}{dest} [{tag}]")
PYEOF

    echo ""
    read -p "选择要修改的节点编号: " IDX
    read -p "新端口号: " NEW_PORT

    if [ -z "$IDX" ] || [ -z "$NEW_PORT" ]; then
        echo -e "${RED}输入不能为空${NC}"
        return
    fi

    python3 << PYEOF
import json
with open("${CONFIG_FILE}", "r") as f:
    config = json.load(f)
idx = int("${IDX}") - 1
if 0 <= idx < len(config["inbounds"]):
    old_port = config["inbounds"][idx]["port"]
    config["inbounds"][idx]["port"] = int("${NEW_PORT}")
    with open("${CONFIG_FILE}", "w") as f:
        json.dump(config, f, indent=4)
    print(f"端口已从 {old_port} 修改为 ${NEW_PORT}")
else:
    print("编号无效")
PYEOF

    # 放行新端口
    ufw allow "$NEW_PORT" 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null || true

    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ 端口修改成功，Xray 已重启${NC}"
        # 重新生成链接
        VPS_IP=$(get_ip)
        UUID=$(grep -o '"id":"[^"]*"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
        PRIVATE_KEY=$(grep -o '"privateKey":"[^"]*"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
        PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -i "public" | awk '{print $NF}')
        SHORT_ID=$(grep -o '"shortIds":\["[^"]*"\]' "$CONFIG_FILE" | head -1 | grep -o '"[a-f0-9]*"' | tail -1 | tr -d '"')
        echo -e "${YELLOW}新链接:${NC}"
        echo -e "vless://${UUID}@${VPS_IP}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Port-${NEW_PORT}"
    else
        echo -e "${RED}重启失败: journalctl -u xray -n 20${NC}"
    fi
}

# ========== 删除节点 ==========
delete_node() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件！${NC}"
        return
    fi

    echo -e "${GREEN}[删除节点]${NC}"
    echo "当前节点:"
    python3 << 'PYEOF'
import json
with open("/usr/local/etc/xray/config.json", "r") as f:
    config = json.load(f)
for i, inb in enumerate(config["inbounds"]):
    tag = inb.get("tag", "unknown")
    port = inb.get("port", "?")
    out_tag = None
    for rule in config.get("routing", {}).get("rules", []):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            out_tag = rule.get("outboundTag")
            break
    dest = ""
    if out_tag:
        for ob in config["outbounds"]:
            if ob.get("tag") == out_tag:
                servers = ob.get("settings", {}).get("servers", [])
                if servers:
                    dest = f" → {servers[0]['address']}:{servers[0]['port']}"
                break
    print(f"  {i+1}) 端口 {port}{dest} [{tag}]")
PYEOF

    echo ""
    read -p "选择要删除的节点编号: " IDX

    if [ -z "$IDX" ]; then
        echo -e "${RED}输入不能为空${NC}"
        return
    fi

    python3 << PYEOF
import json
with open("${CONFIG_FILE}", "r") as f:
    config = json.load(f)
idx = int("${IDX}") - 1
if 0 <= idx < len(config["inbounds"]):
    tag = config["inbounds"][idx]["tag"]
    port = config["inbounds"][idx]["port"]
    # 删除 inbound
    config["inbounds"].pop(idx)
    # 找到并删除对应的路由规则和 outbound
    out_tag = None
    config["routing"]["rules"] = [
        r for r in config["routing"]["rules"]
        if not (r.get("inboundTag") and tag in r.get("inboundTag", []))
        or not (out_tag := r.get("outboundTag")) is None  # 捕获 out_tag
    ]
    # 重新处理：先找 out_tag 再删除
    out_tag = None
    new_rules = []
    for r in config["routing"]["rules"]:
        if r.get("inboundTag") and tag in r.get("inboundTag", []):
            out_tag = r.get("outboundTag")
        else:
            new_rules.append(r)
    config["routing"]["rules"] = new_rules
    if out_tag:
        config["outbounds"] = [o for o in config["outbounds"] if o.get("tag") != out_tag]
    with open("${CONFIG_FILE}", "w") as f:
        json.dump(config, f, indent=4)
    print(f"已删除: 端口 {port} [{tag}]")
else:
    print("编号无效")
PYEOF

    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ 节点已删除，Xray 已重启${NC}"
    else
        echo -e "${RED}重启失败: journalctl -u xray -n 20${NC}"
    fi
}

# ========== 排错诊断 ==========
troubleshoot() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              排错诊断                         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    ERRORS=0

    # 1. Xray 运行状态
    echo -e "${GREEN}[1/8] Xray 服务状态${NC}"
    if systemctl is-active --quiet xray; then
        echo -e "  ${GREEN}✓ Xray 正在运行${NC}"
    else
        echo -e "  ${RED}✗ Xray 未运行${NC}"
        ERRORS=$((ERRORS + 1))
        echo -e "  ${YELLOW}最近日志:${NC}"
        journalctl -u xray -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    fi

    # 2. 配置文件检查
    echo ""
    echo -e "${GREEN}[2/8] 配置文件检查${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "  ${GREEN}✓ 配置文件存在${NC}"
        # 验证 JSON 格式
        if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
            echo -e "  ${GREEN}✓ JSON 格式正确${NC}"
        else
            echo -e "  ${RED}✗ JSON 格式错误${NC}"
            ERRORS=$((ERRORS + 1))
            echo -e "  ${YELLOW}尝试: python3 -m json.tool $CONFIG_FILE${NC}"
        fi
        # 检查 privateKey
        if grep -q '"privateKey":""' "$CONFIG_FILE" 2>/dev/null; then
            echo -e "  ${RED}✗ privateKey 为空${NC}"
            ERRORS=$((ERRORS + 1))
        else
            echo -e "  ${GREEN}✓ privateKey 已配置${NC}"
        fi
    else
        echo -e "  ${RED}✗ 配置文件不存在${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    # 3. 端口监听检查
    echo ""
    echo -e "${GREEN}[3/8] 端口监听检查${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        PORTS=$(grep -o '"port":[0-9]*' "$CONFIG_FILE" | grep -o '[0-9]*')
        for PORT in $PORTS; do
            if ss -tlnp | grep -q ":${PORT} "; then
                echo -e "  ${GREEN}✓ 端口 ${PORT} 正在监听${NC}"
            else
                echo -e "  ${RED}✗ 端口 ${PORT} 未监听${NC}"
                ERRORS=$((ERRORS + 1))
            fi
        done
    fi

    # 4. 防火墙检查
    echo ""
    echo -e "${GREEN}[4/8] 防火墙检查${NC}"
    if command -v ufw &>/dev/null; then
        UFW_STATUS=$(ufw status 2>/dev/null | head -1)
        echo -e "  UFW: ${UFW_STATUS}"
        if [ -f "$CONFIG_FILE" ]; then
            for PORT in $PORTS; do
                if ufw status 2>/dev/null | grep -q "$PORT"; then
                    echo -e "  ${GREEN}✓ 端口 ${PORT} 已放行 (ufw)${NC}"
                else
                    echo -e "  ${YELLOW}⚠ 端口 ${PORT} 可能未放行 (ufw)${NC}"
                fi
            done
        fi
    else
        echo -e "  UFW 未安装，跳过"
    fi

    # 5. SOCKS5 落地节点连通性
    echo ""
    echo -e "${GREEN}[5/8] SOCKS5 落地节点连通性${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        python3 << 'PYEOF'
import json, socket

with open("/usr/local/etc/xray/config.json", "r") as f:
    config = json.load(f)

for ob in config["outbounds"]:
    if ob.get("protocol") == "socks":
        servers = ob.get("settings", {}).get("servers", [])
        for s in servers:
            addr = s["address"]
            port = s["port"]
            tag = ob.get("tag", "unknown")
            try:
                sock = socket.create_connection((addr, port), timeout=5)
                sock.close()
                print(f"  ✓ {addr}:{port} [{tag}] 连通")
            except Exception as e:
                print(f"  ✗ {addr}:{port} [{tag}] 不通 - {e}")
PYEOF
    fi

    # 6. BBR 检查
    echo ""
    echo -e "${GREEN}[6/8] BBR 状态${NC}"
    BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$BBR" = "bbr" ]; then
        echo -e "  ${GREEN}✓ BBR 已启用${NC}"
    else
        echo -e "  ${RED}✗ BBR 未启用 (当前: ${BBR})${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    # 7. 系统资源
    echo ""
    echo -e "${GREEN}[7/8] 系统资源${NC}"
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')

    echo -e "  内存: ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PERCENT}%)"
    if [ "$MEM_PERCENT" -gt 90 ]; then
        echo -e "  ${RED}⚠ 内存使用率过高！${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    echo -e "  磁盘: ${DISK_PERCENT}% 已用"
    if [ "$DISK_PERCENT" -gt 90 ]; then
        echo -e "  ${RED}⚠ 磁盘空间不足！${NC}"
        ERRORS=$((ERRORS + 1))
    fi
    echo -e "  负载: ${CPU_LOAD}"

    # 8. Xray 错误日志
    echo ""
    echo -e "${GREEN}[8/8] 最近错误日志${NC}"
    RECENT_ERRORS=$(journalctl -u xray --since "1 hour ago" --no-pager 2>/dev/null | grep -i -E "error|fail|refused" | tail -5)
    if [ -n "$RECENT_ERRORS" ]; then
        echo -e "  ${YELLOW}发现以下错误:${NC}"
        echo "$RECENT_ERRORS" | sed 's/^/    /'
    else
        echo -e "  ${GREEN}✓ 最近1小时无错误${NC}"
    fi

    # 总结
    echo ""
    echo -e "${CYAN}━━━ 诊断总结 ━━━${NC}"
    if [ $ERRORS -eq 0 ]; then
        echo -e "${GREEN}✓ 所有检查通过，未发现问题${NC}"
    else
        echo -e "${RED}发现 ${ERRORS} 个问题，请根据上方提示修复${NC}"
    fi
    echo ""
}

# ========== 卸载 ==========
uninstall() {
    read -p "确认卸载 Xray？(y/n): " CONFIRM
    if [ "$CONFIRM" = "y" ]; then
        systemctl stop xray 2>/dev/null
        systemctl disable xray 2>/dev/null
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
        rm -f "$INFO_FILE"
        echo -e "${GREEN}已卸载${NC}"
    fi
}

# ========== 更新 Xray ==========
update_xray() {
    echo -e "${GREEN}[更新 Xray]${NC}"
    
    # 当前版本
    if command -v xray &>/dev/null; then
        CURRENT=$(xray version 2>/dev/null | head -1)
        echo -e "  当前版本: ${YELLOW}${CURRENT}${NC}"
    else
        echo -e "  ${RED}Xray 未安装${NC}"
        return
    fi

    # 获取最新版本号
    echo "  正在检查最新版本..."
    LATEST=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$LATEST" ]; then
        echo -e "  最新版本: ${YELLOW}${LATEST}${NC}"
    else
        echo -e "  ${YELLOW}无法获取最新版本号，将直接更新${NC}"
    fi

    echo ""
    read -p "确认更新？(y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "已取消"
        return
    fi

    # 更新
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    # 重启
    systemctl restart xray
    sleep 2

    if systemctl is-active --quiet xray; then
        NEW_VER=$(xray version 2>/dev/null | head -1)
        echo -e "${GREEN}✓ 更新成功: ${NEW_VER}${NC}"
        echo -e "${GREEN}✓ Xray 已重启，配置不变${NC}"
    else
        echo -e "${RED}✗ 更新后启动失败，查看日志: journalctl -u xray -n 20${NC}"
    fi
}

# ========== 主菜单 ==========
main_menu() {
    print_banner
    echo "  1) 全新安装 (首次部署)"
    echo "  2) 添加节点"
    echo "  3) 删除节点"
    echo "  4) 修改端口"
    echo "  5) 查看状态"
    echo "  6) 流量统计"
    echo "  7) 排错诊断"
    echo "  8) 更新 Xray"
    echo "  9) 重启 Xray"
    echo "  10) 卸载"
    echo "  0) 退出"
    echo ""
    read -p "请选择 [0-10]: " CHOICE

    case $CHOICE in
        1)
            update_system
            install_xray
            generate_keys
            collect_nodes
            generate_config
            optimize_system
            setup_firewall
            start_service
            print_result
            ;;
        2)
            add_node
            ;;
        3)
            delete_node
            ;;
        4)
            change_port
            ;;
        5)
            show_status
            ;;
        6)
            show_traffic
            ;;
        7)
            troubleshoot
            ;;
        8)
            update_xray
            ;;
        9)
            systemctl restart xray
            echo -e "${GREEN}已重启${NC}"
            systemctl status xray --no-pager
            ;;
        10)
            uninstall
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac
}

# ========== 入口 ==========
main_menu
