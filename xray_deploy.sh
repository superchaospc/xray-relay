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
SYSCTL_FILE="/etc/sysctl.d/99-xray.conf"
# 客户端指纹（可选：chrome / firefox / safari / ios / android / edge / random）
CLIENT_FP="${CLIENT_FP:-chrome}"

# ========== 工具函数 ==========
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Xray VLESS Reality 中转部署工具 v2.0       ║"
    echo "║   支持多节点 · 一键部署 · 自动优化           ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

IP_CACHE_FILE="/root/.xray_vps_ip"

get_ip() {
    # 优先读缓存（24 小时内有效）
    if [ -f "$IP_CACHE_FILE" ]; then
        local cache_age=$(( $(date +%s) - $(stat -c %Y "$IP_CACHE_FILE" 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt 86400 ]; then
            local cached_ip=$(cat "$IP_CACHE_FILE" 2>/dev/null)
            if [ -n "$cached_ip" ]; then
                echo "$cached_ip"
                return
            fi
        fi
    fi

    IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || \
         curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
         curl -s4 --max-time 5 icanhazip.com 2>/dev/null || true)
    if [ -z "$IP" ]; then
        echo -e "${RED}无法获取本机公网 IP，请手动输入:${NC}" >&2
        read -p "VPS 公网 IP: " IP
    fi

    # 写缓存
    echo "$IP" > "$IP_CACHE_FILE" 2>/dev/null
    echo "$IP"
}

# 确保 qrencode 已安装（用于生成 VLESS 链接的终端二维码）
# 返回 0 = 可用，非 0 = 不可用（调用方应跳过二维码显示）
ensure_qrencode() {
    if command -v qrencode &>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}首次使用二维码功能，正在安装 qrencode...${NC}" >&2
    # 跨发行版安装：Debian/Ubuntu → apt；RHEL/AlmaLinux/Fedora → dnf；旧 CentOS → yum
    # set -e 下所有失败分支都要显式 return，不能让非零退出码逸出
    local rc=1
    if command -v apt-get &>/dev/null; then
        apt-get install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    elif command -v dnf &>/dev/null; then
        dnf install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    elif command -v yum &>/dev/null; then
        yum install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    else
        echo -e "${RED}未检测到支持的包管理器 (apt/dnf/yum)，跳过二维码显示${NC}" >&2
        return 1
    fi
    if [ "$rc" -eq 0 ]; then
        return 0
    else
        echo -e "${RED}qrencode 安装失败，将跳过二维码显示（链接仍可手动复制）${NC}" >&2
        return 1
    fi
}

# 在终端输出 VLESS 链接的二维码，供 Shadowrocket / V2rayN / Neobox / V2rayNG 扫码导入
# 用法: show_qrcode "<vless链接>" "<节点名(可选)>"
show_qrcode() {
    local link="$1"
    local name="${2:-节点}"

    [ -z "$link" ] && return 0
    ensure_qrencode || return 0

    echo ""
    echo -e "${GREEN}┌─ 扫码导入 [${name}] ──────────────────────────${NC}"
    echo -e "${CYAN}  Shadowrocket / V2rayN / Neobox / V2rayNG 均可扫码${NC}"
    echo ""
    # -t ANSIUTF8: 用半高块字符渲染，密度高、扫码友好
    # -m 2: quiet zone 留 2 格（默认 4 格在终端里太占空间）
    qrencode -t ANSIUTF8 -m 2 "$link" || {
        echo -e "${RED}  二维码生成失败${NC}"
        return 0
    }
    echo -e "${GREEN}└──────────────────────────────────────────────${NC}"
    echo ""
}

# 安全地下载并执行官方 Xray 安装脚本
# 用法: run_xray_installer install | remove
# 先把安装脚本内容抓到本地变量再执行，避免 curl 失败触发 set -e 导致脚本直接闪退
run_xray_installer() {
    local action="${1:-install}"
    echo "正在从 GitHub 下载 Xray 安装脚本..."
    local install_script
    install_script=$(curl -fsSL --max-time 15 \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh 2>/dev/null || true)
    if [ -z "$install_script" ]; then
        echo -e "${RED}✗ 无法连接到 GitHub 下载 Xray 安装脚本${NC}"
        echo -e "${YELLOW}  可能原因：网络不通 / GitHub 被墙 / DNS 污染${NC}"
        echo -e "${YELLOW}  建议：检查网络、配置代理，或为本机临时配置 DNS (如 1.1.1.1 / 8.8.8.8)${NC}"
        return 1
    fi
    bash -c "$install_script" @ "$action"
}

get_next_inbound_port() {
    python3 << 'PYEOF'
import json, sys

config_file = "/usr/local/etc/xray/config.json"

with open(config_file, "r") as f:
    config = json.load(f)

used = {
    inb.get("port", 0)
    for inb in config.get("inbounds", [])
    if inb.get("tag") != "api-in"
}

# 从 8443 开始找第一个没被配置占用的端口（与历史 max 无关，
# 避免 change_port 把端口改到 19999 之后再添加节点就溢出的 bug）
candidate = 8443
while candidate in used:
    candidate += 1
    if candidate > 20000:
        # 用正常退出码 + 字符串前缀，避免 set -e 下外层命令替换瞬间崩溃
        print("ERROR: next inbound port exceeds 20000")
        sys.exit(0)

print(candidate)
PYEOF
}

port_in_use() {
    local port="$1"
    ss -tln 2>/dev/null | grep -q ":${port} "
}

apply_firewall_port() {
    local port="$1"

    # 优先级 1: UFW (Debian/Ubuntu)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port" >/dev/null 2>&1 || true
        return
    fi

    # 优先级 2: firewalld (CentOS / RHEL / AlmaLinux / Rocky / Fedora)
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        return
    fi

    # 优先级 3: 裸 iptables（兜底）
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

get_next_tag_num() {
    CONFIG_FILE="$CONFIG_FILE" python3 << 'PYEOF'
import json
import os
import re

with open(os.environ["CONFIG_FILE"], "r") as f:
    config = json.load(f)

max_num = 0
for inb in config.get("inbounds", []):
    match = re.fullmatch(r"vless-in-(\d+)", inb.get("tag", ""))
    if match:
        max_num = max(max_num, int(match.group(1)))

print(max_num + 1)
PYEOF
}

load_node_identity() {
    eval "$(
        CONFIG_FILE="$CONFIG_FILE" python3 << 'PYEOF'
import json
import os
import shlex

with open(os.environ["CONFIG_FILE"], "r") as f:
    config = json.load(f)

private_key = ""
short_id = ""
uuid = ""

# 所有业务 inbound 共享同一套 reality 密钥，取第一个即可
for inb in config.get("inbounds", []):
    if inb.get("tag") == "api-in":
        continue
    reality = inb.get("streamSettings", {}).get("realitySettings", {})
    clients = inb.get("settings", {}).get("clients", [])
    private_key = reality.get("privateKey", "")
    short_ids = reality.get("shortIds", [])
    short_id = short_ids[0] if short_ids else ""
    uuid = clients[0].get("id", "") if clients else ""
    break

print(f"PRIVATE_KEY={shlex.quote(private_key)}")
print(f"SHORT_ID={shlex.quote(short_id)}")
print(f"UUID={shlex.quote(uuid)}")
PYEOF
    )"
}

# ========== 更新操作系统 ==========
update_system() {
    echo -e "${GREEN}[步骤0] 更新操作系统...${NC}"
    
    if command -v apt &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
        apt install -y curl python3 iproute2 ca-certificates
        apt autoremove -y
        echo -e "  ${GREEN}✓ 系统已更新 (apt)${NC}"
    elif command -v dnf &>/dev/null; then
        dnf update -y
        dnf install -y curl python3 iproute ca-certificates
        echo -e "  ${GREEN}✓ 系统已更新 (dnf)${NC}"
    elif command -v yum &>/dev/null; then
        yum update -y
        yum install -y curl python3 iproute ca-certificates
        echo -e "  ${GREEN}✓ 系统已更新 (yum)${NC}"
    else
        echo -e "  ${YELLOW}⚠ 未识别的包管理器，跳过系统更新${NC}"
    fi

    # 硬性检查 python3（整个脚本强依赖）
    if ! command -v python3 &>/dev/null; then
        echo -e "  ${RED}✗ 未检测到 python3，脚本无法继续${NC}"
        echo -e "  ${YELLOW}请手动安装 python3 后重新运行${NC}"
        exit 1
    fi
}

# ========== 安装 Xray ==========
install_xray() {
    echo -e "${GREEN}[步骤1] 检查并安装 Xray...${NC}"
    if command -v xray &> /dev/null; then
        echo "Xray 已安装: $(xray version | head -1)"
    else
        echo "正在安装 Xray..."
        if ! run_xray_installer install; then
            echo -e "${RED}Xray 安装失败，无法继续部署${NC}"
            exit 1
        fi
    fi
    mkdir -p /var/log/xray
}

generate_keys() {
    echo -e "${GREEN}[步骤2] 生成 Reality x25519 密钥对...${NC}"
    KEY_OUTPUT=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "public" | awk '{print $NF}')
    SHORT_ID=$(python3 -c 'import os; print(os.urandom(8).hex())')
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
    echo -e "  Private Key: ${YELLOW}${PRIVATE_KEY}${NC}"
    echo -e "  Public Key:  ${YELLOW}${PUBLIC_KEY}${NC}"
    echo -e "  UUID:        ${YELLOW}${UUID}${NC}"
    echo -e "  Short ID:    ${YELLOW}${SHORT_ID}${NC}"
}

collect_nodes() {
    echo ""
    echo -e "${GREEN}[步骤3] 添加 SOCKS5 住宅节点${NC}"
    echo -e "${CYAN}格式: IP:端口:用户名:密码${NC}"
    echo -e "${CYAN}例如: 161.77.77.5:12324:14a0f0ecfa3d6:384cafa39d${NC}"
    echo -e "${CYAN}（如果暂无住宅节点，可直接输入 done 跳过，脚本会创建一个 443 端口的 VPS 直连节点作为起点）${NC}"
    echo ""

    # 节点数组内部分隔符：使用 ASCII US（Unit Separator, 0x1F），
    # 避免与密码里可能出现的 | : 等常见字符冲突。
    local SEP=$'\x1f'

    NODES=()
    NODE_NUM=0

    while true; do
        NODE_NUM=$((NODE_NUM + 1))
        read -p "节点${NODE_NUM} (输入 done 结束): " INPUT

        if [ "$INPUT" = "done" ] || [ "$INPUT" = "d" ] || [ -z "$INPUT" ]; then
            if [ ${#NODES[@]} -eq 0 ]; then
                # 空节点：二次确认是否创建"纯直连"起步配置
                echo ""
                echo -e "${YELLOW}你还没有添加任何住宅 SOCKS5 节点。${NC}"
                echo -e "${YELLOW}是否创建一个 443 端口的 VPS 直连节点作为起点？${NC}"
                echo -e "${CYAN}（流量将直接从 VPS 机房 IP 出口，不经过住宅 IP；之后可随时通过菜单选项 2 追加住宅节点）${NC}"
                read -p "输入 y 创建直连起步节点 / 其他任意键继续录入住宅节点: " EMPTY_CHOICE
                if [ "$EMPTY_CHOICE" = "y" ] || [ "$EMPTY_CHOICE" = "Y" ]; then
                    # 哨兵格式：S_HOST=__DIRECT__ 表示这是直连节点，S_PORT/USER/PASS 留空
                    NODES+=("443${SEP}__DIRECT__${SEP}${SEP}${SEP}${SEP}VPS-Direct")
                    echo -e "${GREEN}  ✓ 已添加直连起步节点: VPS-Direct (监听端口: 443)${NC}"
                    break
                fi
                NODE_NUM=0
                continue
            fi
            break
        fi

        IFS=':' read -r S_HOST S_PORT S_USER S_PASS <<< "$INPUT"

        if [ -z "$S_HOST" ] || [ -z "$S_PORT" ] || [ -z "$S_USER" ] || [ -z "$S_PASS" ]; then
            echo -e "${RED}格式错误，请使用 IP:端口:用户名:密码${NC}"
            NODE_NUM=$((NODE_NUM - 1))
            continue
        fi

        # 第一个节点用 443（HTTPS 特权端口），第二个起从 8443 段递增
        if [ $NODE_NUM -eq 1 ]; then
            LISTEN_PORT=443
        else
            LISTEN_PORT=$((8442 + NODE_NUM))
        fi

        read -p "  备注名称 (如 KR-Seoul / US-LA，回车跳过): " NODE_NAME
        [ -z "$NODE_NAME" ] && NODE_NAME="Node-${NODE_NUM}"
        # 清理 URL 片段里的不安全字符（空格/井号/问号/&/换行/制表），
        # 否则客户端（V2rayN 等）从剪贴板导入时会按空格/# 截断链接。
        NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
        [ -z "$NODE_NAME" ] && NODE_NAME="Node-${NODE_NUM}"

        NODES+=("${LISTEN_PORT}${SEP}${S_HOST}${SEP}${S_PORT}${SEP}${S_USER}${SEP}${S_PASS}${SEP}${NODE_NAME}")
        echo -e "${GREEN}  ✓ 已添加: ${NODE_NAME} → ${S_HOST}:${S_PORT} (监听端口: ${LISTEN_PORT})${NC}"
        echo ""
    done
}

generate_config() {
    echo -e "${GREEN}[步骤4] 生成 Xray 配置文件...${NC}"
    NODES_DATA=$(printf '%s\n' "${NODES[@]}")

    CONFIG_FILE="$CONFIG_FILE" \
    UUID="$UUID" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    SHORT_ID="$SHORT_ID" \
    NODES_DATA="$NODES_DATA" \
    python3 << 'PYEOF'
import json
import os

config_file = os.environ["CONFIG_FILE"]
uuid = os.environ["UUID"]
private_key = os.environ["PRIVATE_KEY"]
short_id = os.environ["SHORT_ID"]
raw_nodes = [line for line in os.environ["NODES_DATA"].splitlines() if line.strip()]

inbounds = [{
    "tag": "api-in",
    "port": 10085,
    "listen": "127.0.0.1",
    "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"}
}]
outbounds = []
rules = [
    {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
    {"type": "field", "outboundTag": "block", "protocol": ["bittorrent"]},
    {"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]},
]

for idx, node in enumerate(raw_nodes, start=1):
    port, s_host, s_port, s_user, s_pass, name = node.split("\x1f", 5)
    tag_in = f"vless-in-{idx}"

    inbounds.append({
        "tag": tag_in,
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "dest": "www.microsoft.com:443",
                "serverNames": ["www.microsoft.com"],
                "privateKey": private_key,
                "shortIds": [short_id]
            },
            "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
    })

    # 哨兵 __DIRECT__：这是 VPS 直连节点，不创建 socks5-out 出站，路由直接指向全局 direct
    if s_host == "__DIRECT__":
        rules.append({"type": "field", "inboundTag": [tag_in], "outboundTag": "direct"})
        continue

    tag_out = f"socks5-out-{idx}"
    outbounds.append({
        "tag": tag_out,
        "protocol": "socks",
        "settings": {"servers": [{
            "address": s_host,
            "port": int(s_port),
            "users": [{"user": s_user, "pass": s_pass}]
        }]},
        "streamSettings": {"sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}}
    })

    rules.append({"type": "field", "inboundTag": [tag_in], "outboundTag": tag_out})

config = {
    "log": {"loglevel": "warning"},
    "stats": {},
    "api": {"tag": "api", "services": ["StatsService"]},
    "policy": {
        "system": {
            "statsInboundUplink": True,
            "statsInboundDownlink": True,
            "statsOutboundUplink": True,
            "statsOutboundDownlink": True
        }
    },
    "inbounds": inbounds,
    "outbounds": outbounds + [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules}
}

with open(config_file, "w") as f:
    json.dump(config, f, indent=4)
PYEOF
    echo -e "  ✓ 配置已写入 ${CONFIG_FILE}"
    echo -e "  ✓ 流量统计 API 已启用 (端口 10085)"
}

optimize_system() {
    echo -e "${GREEN}[步骤5] 系统优化 (BBR + 内核参数)...${NC}"

    if [ -f "$SYSCTL_FILE" ]; then
        echo "  sysctl 优化配置已存在，跳过写入"
    else
        cat > "$SYSCTL_FILE" << 'EOF'
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
        sysctl --system >/dev/null 2>&1 || true
        echo "  ✓ BBR 和内核参数配置已写入 ${SYSCTL_FILE}"
    fi

    if ! grep -q "LimitNOFILE=65535" /etc/systemd/system/xray.service.d/limits.conf 2>/dev/null; then
        mkdir -p /etc/systemd/system/xray.service.d
        cat > /etc/systemd/system/xray.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF
        echo "  ✓ 文件描述符限制已提升"
    fi

    # 检查系统是否已有任何 swap（不仅仅是 /swapfile）
    CURRENT_SWAP=$(free | awk '/Swap:/ {print $2}')
    if [ "${CURRENT_SWAP:-0}" -eq 0 ] && [ ! -f /swapfile ]; then
        if fallocate -l 1G /swapfile 2>/dev/null && \
           chmod 600 /swapfile && \
           mkswap /swapfile >/dev/null 2>&1 && \
           swapon /swapfile 2>/dev/null; then
            grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo "  ✓ 1G Swap 已添加"
        else
            echo -e "  ${YELLOW}⚠ Swap 创建失败，跳过${NC}"
            rm -f /swapfile
        fi
    else
        echo "  系统已有 Swap，跳过"
    fi
}

setup_firewall() {
    echo -e "${GREEN}[步骤6] 配置防火墙...${NC}"
    for NODE in "${NODES[@]}"; do
        IFS=$'\x1f' read -r PORT _ _ _ _ _ <<< "$NODE"
        apply_firewall_port "$PORT"
        echo "  ✓ 端口 ${PORT} 已放行"
    done
}

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

print_result() {
    VPS_IP=$(get_ip)

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              部署完成！                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    > "$INFO_FILE"

    for i in "${!NODES[@]}"; do
        IFS=$'\x1f' read -r PORT S_HOST S_PORT S_USER S_PASS NAME <<< "${NODES[$i]}"

        LINK="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NAME}"

        echo -e "${GREEN}━━━ ${NAME} ━━━${NC}"
        echo -e "  监听端口: ${PORT}"
        if [ "$S_HOST" = "__DIRECT__" ]; then
            echo -e "  出口:     VPS 直连 (${VPS_IP})"
        else
            echo -e "  落地节点: ${S_HOST}:${S_PORT}"
        fi
        echo -e "${YELLOW}  ${LINK}${NC}"
        echo ""

        echo "=== ${NAME} ===" >> "$INFO_FILE"
        echo "端口: ${PORT}" >> "$INFO_FILE"
        if [ "$S_HOST" = "__DIRECT__" ]; then
            echo "出口: VPS 直连 (${VPS_IP})" >> "$INFO_FILE"
        else
            echo "落地: ${S_HOST}:${S_PORT}" >> "$INFO_FILE"
        fi
        echo "链接: ${LINK}" >> "$INFO_FILE"
        echo "" >> "$INFO_FILE"

        # 显示该节点的二维码，方便客户端扫码导入
        show_qrcode "$LINK" "$NAME"
    done

    echo -e "${GREEN}━━━ 通用信息 ━━━${NC}"
    echo -e "  VPS IP:     ${VPS_IP}"
    echo -e "  UUID:       ${UUID}"
    echo -e "  Public Key: ${PUBLIC_KEY}"
    echo -e "  Short ID:   ${SHORT_ID}"
    echo ""
    echo -e "${GREEN}所有链接已保存到 ${INFO_FILE}${NC}"
}

add_node() {
    echo -e "${GREEN}[添加节点模式]${NC}"
    
    VPS_IP=$(get_ip)
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到现有配置，请先完整安装！${NC}"
        exit 1
    fi

    load_node_identity

    if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$UUID" ]; then
        echo -e "${RED}现有配置中的业务节点密钥信息不完整，无法添加节点${NC}"
        exit 1
    fi
    
    PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -i "public" | awk '{print $NF}')

    NEW_PORT=$(get_next_inbound_port)
    if [[ "$NEW_PORT" == ERROR:* ]]; then
        echo -e "${RED}${NEW_PORT}${NC}"
        exit 1
    fi
    while port_in_use "$NEW_PORT"; do
        NEW_PORT=$((NEW_PORT + 1))
        if [ "$NEW_PORT" -gt 20000 ]; then
            echo -e "${RED}未找到可用监听端口，请手动检查端口占用${NC}"
            exit 1
        fi
    done

    echo -e "新的监听端口: ${NEW_PORT}"
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
    # 清理 URL 片段里的不安全字符
    NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
    [ -z "$NODE_NAME" ] && NODE_NAME="Node-new"

    TAG_NUM=$(get_next_tag_num)

    CONFIG_FILE="$CONFIG_FILE" \
    TAG_NUM="$TAG_NUM" \
    NEW_PORT="$NEW_PORT" \
    UUID="$UUID" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    SHORT_ID="$SHORT_ID" \
    S_HOST="$S_HOST" \
    S_PORT="$S_PORT" \
    S_USER="$S_USER" \
    S_PASS="$S_PASS" \
    python3 << 'PYEOF'
import json
import os

config_file = os.environ["CONFIG_FILE"]
tag_num = os.environ["TAG_NUM"]
new_port = int(os.environ["NEW_PORT"])
uuid = os.environ["UUID"]
private_key = os.environ["PRIVATE_KEY"]
short_id = os.environ["SHORT_ID"]
s_host = os.environ["S_HOST"]
s_port = int(os.environ["S_PORT"])
s_user = os.environ["S_USER"]
s_pass = os.environ["S_PASS"]

with open(config_file, "r") as f:
    config = json.load(f)

config["inbounds"].append({
    "tag": f"vless-in-{tag_num}",
    "port": new_port,
    "protocol": "vless",
    "settings": {
        "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "www.microsoft.com:443",
            "serverNames": ["www.microsoft.com"],
            "privateKey": private_key,
            "shortIds": [short_id]
        },
        "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
})

new_out = {
    "tag": f"socks5-out-{tag_num}",
    "protocol": "socks",
    "settings": {"servers": [{
        "address": s_host,
        "port": s_port,
        "users": [{"user": s_user, "pass": s_pass}]
    }]},
    "streamSettings": {"sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}}
}
for idx, ob in enumerate(config["outbounds"]):
    if ob.get("tag") == "direct":
        config["outbounds"].insert(idx, new_out)
        break
else:
    config["outbounds"].append(new_out)

new_rule = {"type": "field", "inboundTag": [f"vless-in-{tag_num}"], "outboundTag": f"socks5-out-{tag_num}"}
config["routing"]["rules"].append(new_rule)

with open(config_file, "w") as f:
    json.dump(config, f, indent=4)

print("配置已更新")
PYEOF

    apply_firewall_port "$NEW_PORT"

    systemctl restart xray
    sleep 2

    if systemctl is-active --quiet xray; then
        LINK="vless://${UUID}@${VPS_IP}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"
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

        show_qrcode "$LINK" "$NODE_NAME"
    else
        echo -e "${RED}重启失败: journalctl -u xray -n 20${NC}"
    fi
}

# ========== 添加 VPS 直连节点（不经住宅 IP）==========
add_direct_node() {
    echo -e "${GREEN}[添加 VPS 直连节点]${NC}"
    echo -e "${CYAN}此模式不经过住宅 SOCKS5，流量直接从 VPS 出口访问目标站点。${NC}"
    echo -e "${CYAN}目标网站看到的将是你 VPS 的机房 IP。${NC}"
    echo ""

    VPS_IP=$(get_ip)

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到现有配置，请先完成【全新安装】(选项 1)！${NC}"
        return
    fi

    load_node_identity

    if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$UUID" ]; then
        echo -e "${RED}现有配置中的业务节点密钥信息不完整，无法添加节点${NC}"
        return
    fi

    PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -i "public" | awk '{print $NF}')

    NEW_PORT=$(get_next_inbound_port)
    if [[ "$NEW_PORT" == ERROR:* ]]; then
        echo -e "${RED}${NEW_PORT}${NC}"
        return
    fi
    while port_in_use "$NEW_PORT"; do
        NEW_PORT=$((NEW_PORT + 1))
        if [ "$NEW_PORT" -gt 20000 ]; then
            echo -e "${RED}未找到可用监听端口，请手动检查端口占用${NC}"
            return
        fi
    done

    echo -e "新的监听端口: ${NEW_PORT}"

    read -p "备注名称 (如 VPS-Direct / JP-Direct，回车默认 VPS-Direct): " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="VPS-Direct"
    # 清理 URL 片段里的不安全字符
    NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
    [ -z "$NODE_NAME" ] && NODE_NAME="VPS-Direct"

    TAG_NUM=$(get_next_tag_num)

    CONFIG_FILE="$CONFIG_FILE" \
    TAG_NUM="$TAG_NUM" \
    NEW_PORT="$NEW_PORT" \
    UUID="$UUID" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    SHORT_ID="$SHORT_ID" \
    python3 << 'PYEOF'
import json
import os

config_file = os.environ["CONFIG_FILE"]
tag_num = os.environ["TAG_NUM"]
new_port = int(os.environ["NEW_PORT"])
uuid = os.environ["UUID"]
private_key = os.environ["PRIVATE_KEY"]
short_id = os.environ["SHORT_ID"]

with open(config_file, "r") as f:
    config = json.load(f)

# 入站：和住宅节点同样的 VLESS+REALITY 设置，只是路由指向 direct
config["inbounds"].append({
    "tag": f"vless-in-{tag_num}",
    "port": new_port,
    "protocol": "vless",
    "settings": {
        "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "www.microsoft.com:443",
            "serverNames": ["www.microsoft.com"],
            "privateKey": private_key,
            "shortIds": [short_id]
        },
        "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}
    },
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
})

# 确保 direct 出站存在（全新安装一定会生成；防御性保底）
if not any(ob.get("tag") == "direct" for ob in config.get("outbounds", [])):
    config.setdefault("outbounds", []).append({"tag": "direct", "protocol": "freedom"})

# 路由：该入站 → direct，不走任何 SOCKS5
new_rule = {"type": "field", "inboundTag": [f"vless-in-{tag_num}"], "outboundTag": "direct"}
config.setdefault("routing", {}).setdefault("rules", []).append(new_rule)

with open(config_file, "w") as f:
    json.dump(config, f, indent=4)

print("直连节点配置已更新")
PYEOF

    apply_firewall_port "$NEW_PORT"

    systemctl restart xray
    sleep 2

    if systemctl is-active --quiet xray; then
        LINK="vless://${UUID}@${VPS_IP}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"
        echo ""
        echo -e "${GREEN}✓ VPS 直连节点添加成功！${NC}"
        echo -e "${GREEN}端口: ${NEW_PORT}${NC}"
        echo -e "${GREEN}出口: VPS 直连 (${VPS_IP})${NC}"
        echo -e "${YELLOW}${LINK}${NC}"

        echo "" >> "$INFO_FILE"
        echo "=== ${NODE_NAME} ===" >> "$INFO_FILE"
        echo "端口: ${NEW_PORT}" >> "$INFO_FILE"
        echo "出口: VPS 直连 (${VPS_IP})" >> "$INFO_FILE"
        echo "链接: ${LINK}" >> "$INFO_FILE"

        show_qrcode "$LINK" "$NODE_NAME"
    else
        echo -e "${RED}重启失败: journalctl -u xray -n 20${NC}"
    fi
}

show_status() {
    echo -e "${GREEN}━━━ Xray 状态 ━━━${NC}"
    # systemctl status 在服务非 active 时返回非零，set -e 下需要兜底
    systemctl status xray --no-pager -l || true
    echo ""
    echo -e "${GREEN}━━━ BBR 状态 ━━━${NC}"
    # 某些精简内核/首次部署前可能没有此 sysctl 键，避免触发 set -e 直接退出
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "BBR 尚未配置"
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

# 数据库格式(v2): timestamp|tag|port|cumulative_up|cumulative_down|delta_up|delta_down
#   - cumulative_*: Xray API 返回的原始累计值（重启会归零）
#   - delta_*: 相对上一次采样的增量，已处理了计数器归零的情况
# 旧格式(v1, 5字段)会被 promote_v1_row 兼容地当成 delta=0 处理

setup_traffic_cron() {
    CRON_SCRIPT="/root/.xray_traffic_record.sh"
    
    cat > "$CRON_SCRIPT" << 'CRONEOF'
#!/bin/bash
CONFIG_FILE="/usr/local/etc/xray/config.json"
TRAFFIC_DB="/root/.xray_traffic_db"
XRAY_BIN="/usr/local/bin/xray"

[ ! -f "$CONFIG_FILE" ] && exit 0
command -v xray &>/dev/null || exit 0

CONFIG_FILE="$CONFIG_FILE" \
TRAFFIC_DB="$TRAFFIC_DB" \
XRAY_BIN="$XRAY_BIN" \
python3 << 'PYEOF'
import json, subprocess, os, time

config_file = os.environ["CONFIG_FILE"]
db_file = os.environ["TRAFFIC_DB"]
xray_bin = os.environ["XRAY_BIN"]
timestamp = int(time.time())

with open(config_file, "r") as f:
    config = json.load(f)

def get_stat(name):
    try:
        result = subprocess.run(
            [xray_bin, "api", "stats", "--server=127.0.0.1:10085", f"-name={name}"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split("\n"):
            if "value:" in line.lower():
                val = line.split(":")[-1].strip()
                return int(val) if val else 0
    except Exception:
        pass
    return 0

# 读最后一次每个 tag 的累计值，用于计算 delta 并处理计数器归零
last_cum = {}
if os.path.exists(db_file):
    try:
        with open(db_file, "r") as f:
            for line in f:
                parts = line.strip().split("|")
                # v2 格式 7 字段；v1 格式 5 字段（兼容）
                if len(parts) >= 5:
                    try:
                        tag = parts[1]
                        cum_up = int(parts[3])
                        cum_down = int(parts[4])
                        last_cum[tag] = (cum_up, cum_down)
                    except ValueError:
                        pass
    except Exception:
        pass

new_rows = []
for inb in config.get("inbounds", []):
    tag = inb.get("tag", "")
    if tag == "api-in" or not tag:
        continue
    port = inb.get("port", 0)
    cur_up = get_stat(f"inbound>>>{tag}>>>traffic>>>uplink")
    cur_down = get_stat(f"inbound>>>{tag}>>>traffic>>>downlink")

    prev_up, prev_down = last_cum.get(tag, (0, 0))

    # 计数器归零检测：当前 < 上一次，说明 Xray 重启过，把当前值当成增量
    if cur_up < prev_up:
        delta_up = cur_up
    else:
        delta_up = cur_up - prev_up

    if cur_down < prev_down:
        delta_down = cur_down
    else:
        delta_down = cur_down - prev_down

    new_rows.append(f"{timestamp}|{tag}|{port}|{cur_up}|{cur_down}|{delta_up}|{delta_down}")

with open(db_file, "a") as f:
    for r in new_rows:
        f.write(r + "\n")

# 清理超过 60 天的旧数据
cutoff = timestamp - 60 * 86400
if os.path.exists(db_file):
    with open(db_file, "r") as f:
        lines = f.readlines()
    with open(db_file, "w") as f:
        for line in lines:
            parts = line.strip().split("|")
            if len(parts) >= 5:
                try:
                    if int(parts[0]) > cutoff:
                        f.write(line)
                except ValueError:
                    pass
PYEOF
CRONEOF

    chmod +x "$CRON_SCRIPT"
    
    if ! crontab -l 2>/dev/null | grep -q "xray_traffic_record"; then
        # crontab -l 在从未创建过 crontab 的用户下会返回非零，
        # 配合外层 set -e 会让子 shell 中断、echo 不执行、最终写入空 crontab。
        # 必须加 || true 规避。
        (crontab -l 2>/dev/null || true; echo "*/5 * * * * /root/.xray_traffic_record.sh # xray_traffic_record") | crontab -
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

    setup_traffic_cron
    bash /root/.xray_traffic_record.sh 2>/dev/null

    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              节点流量统计                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    CONFIG_FILE="$CONFIG_FILE" \
    TRAFFIC_DB="$TRAFFIC_DB" \
    XRAY_BIN="/usr/local/bin/xray" \
    python3 << 'PYEOF'
import json, subprocess, os, time

config_file = os.environ["CONFIG_FILE"]
db_file = os.environ["TRAFFIC_DB"]
xray_bin = os.environ["XRAY_BIN"]

with open(config_file, "r") as f:
    config = json.load(f)

def get_stat(name):
    try:
        result = subprocess.run(
            [xray_bin, "api", "stats", "--server=127.0.0.1:10085", f"-name={name}"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split("\n"):
            if "value:" in line.lower():
                val = line.split(":")[-1].strip()
                return int(val) if val else 0
    except Exception:
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
            # 公共出站 direct/block 不挂 servers，特判一下
            if out_tag == "direct":
                return "VPS"
            if out_tag == "block":
                return "BLOCK"
            for ob in config["outbounds"]:
                if ob.get("tag") == out_tag:
                    servers = ob.get("settings", {}).get("servers", [])
                    if servers:
                        return servers[0]["address"]
    return ""

# ===== 当前实时流量（自上次启动，从 API 直接取） =====
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
    # 读取所有记录; 每行: ts|tag|port|cum_up|cum_down|delta_up|delta_down
    # v1 旧格式（5 字段）: delta_up/delta_down 视作 0 跳过，不影响正确性
    records = []
    with open(db_file, "r") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 7:
                try:
                    ts = int(parts[0])
                    tag = parts[1]
                    port = int(parts[2])
                    delta_up = int(parts[5])
                    delta_down = int(parts[6])
                    records.append((ts, tag, port, delta_up, delta_down))
                except ValueError:
                    pass

    if records:
        now = int(time.time())
        periods = [
            ("过去1小时", now - 3600),
            ("今天", now - (now % 86400)),
            ("过去7天", now - 7 * 86400),
            ("过去30天", now - 30 * 86400),
        ]

        tags = sorted({(r[1], r[2]) for r in records}, key=lambda x: x[1])

        for period_name, since in periods:
            print(f"\n  ━━━ {period_name} ━━━")
            print(f"  {'节点':<22} {'上行':>10} {'下行':>10} {'合计':>10}")
            print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")

            p_total_up = 0
            p_total_down = 0

            for tag, port in tags:
                # 增量法：区间内所有 delta 之和即为该段实际流量
                # Xray 重启时 record.sh 已把重启后的当前值作为 delta 写入
                up = sum(r[3] for r in records if r[1] == tag and r[0] >= since)
                down = sum(r[4] for r in records if r[1] == tag and r[0] >= since)
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
display_idx = 0
for inb in config["inbounds"]:
    if inb.get("tag") == "api-in":
        continue
    display_idx += 1
    tag = inb.get("tag", "unknown")
    port = inb.get("port", "?")
    out_tag = None
    for rule in config.get("routing", {}).get("rules", []):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            out_tag = rule.get("outboundTag")
            break
    dest = ""
    if out_tag == "direct":
        dest = " → VPS 直连"
    elif out_tag:
        for ob in config["outbounds"]:
            if ob.get("tag") == out_tag:
                servers = ob.get("settings", {}).get("servers", [])
                if servers:
                    dest = f" → {servers[0]['address']}:{servers[0]['port']}"
                break
    print(f"  {display_idx}) 端口 {port}{dest} [{tag}]")
PYEOF

    echo ""
    read -p "选择要修改的节点编号: " IDX
    read -p "新端口号: " NEW_PORT

    if [ -z "$IDX" ] || [ -z "$NEW_PORT" ]; then
        echo -e "${RED}输入不能为空${NC}"
        return
    fi

    if port_in_use "$NEW_PORT"; then
        echo -e "${RED}端口 ${NEW_PORT} 已被占用，请换一个端口${NC}"
        return
    fi

    CONFIG_FILE="$CONFIG_FILE" IDX="$IDX" NEW_PORT="$NEW_PORT" python3 << 'PYEOF'
import json
import os

config_file = os.environ["CONFIG_FILE"]
idx = int(os.environ["IDX"]) - 1
new_port = int(os.environ["NEW_PORT"])

with open(config_file, "r") as f:
    config = json.load(f)

business_inbounds = [inb for inb in config["inbounds"] if inb.get("tag") != "api-in"]

if 0 <= idx < len(business_inbounds):
    target_tag = business_inbounds[idx]["tag"]
    old_port = business_inbounds[idx]["port"]
    for inb in config["inbounds"]:
        if inb.get("tag") == target_tag:
            inb["port"] = new_port
            break
    with open(config_file, "w") as f:
        json.dump(config, f, indent=4)
    print(f"端口已从 {old_port} 修改为 {new_port}")
else:
    print("编号无效")
PYEOF

    apply_firewall_port "$NEW_PORT"

    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ 端口修改成功，Xray 已重启${NC}"
        VPS_IP=$(get_ip)
        load_node_identity
        PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -i "public" | awk '{print $NF}')
        NEW_LINK="vless://${UUID}@${VPS_IP}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Port-${NEW_PORT}"
        echo -e "${YELLOW}新链接:${NC}"
        echo -e "${NEW_LINK}"

        show_qrcode "$NEW_LINK" "Port-${NEW_PORT}"
    else
        echo -e "${RED}重启失败: journalctl -u xray -n 20${NC}"
    fi
}

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
display_idx = 0
for inb in config["inbounds"]:
    if inb.get("tag") == "api-in":
        continue
    display_idx += 1
    tag = inb.get("tag", "unknown")
    port = inb.get("port", "?")
    out_tag = None
    for rule in config.get("routing", {}).get("rules", []):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            out_tag = rule.get("outboundTag")
            break
    dest = ""
    if out_tag == "direct":
        dest = " → VPS 直连"
    elif out_tag:
        for ob in config["outbounds"]:
            if ob.get("tag") == out_tag:
                servers = ob.get("settings", {}).get("servers", [])
                if servers:
                    dest = f" → {servers[0]['address']}:{servers[0]['port']}"
                break
    print(f"  {display_idx}) 端口 {port}{dest} [{tag}]")
PYEOF

    echo ""
    read -p "选择要删除的节点编号: " IDX

    if [ -z "$IDX" ]; then
        echo -e "${RED}输入不能为空${NC}"
        return
    fi

    CONFIG_FILE="$CONFIG_FILE" IDX="$IDX" python3 << 'PYEOF'
import json
import os

config_file = os.environ["CONFIG_FILE"]
idx = int(os.environ["IDX"]) - 1

with open(config_file, "r") as f:
    config = json.load(f)

business_inbounds = [inb for inb in config["inbounds"] if inb.get("tag") != "api-in"]

if 0 <= idx < len(business_inbounds):
    tag = business_inbounds[idx]["tag"]
    port = business_inbounds[idx]["port"]
    config["inbounds"] = [inb for inb in config["inbounds"] if inb.get("tag") != tag]

    out_tag = None
    new_rules = []
    for r in config["routing"]["rules"]:
        inbound_tags = r.get("inboundTag", [])
        if inbound_tags and tag in inbound_tags:
            out_tag = r.get("outboundTag")
        else:
            new_rules.append(r)
    config["routing"]["rules"] = new_rules

    if out_tag:
        # 保护公共出站：direct（VPS 直连）和 block（黑洞）是所有节点共享的，不能随节点删除
        # 注意：本脚本假设每个业务 inbound 绑定独占的 outbound（socks5-out-N）。
        # 若手动改过 config.json 让多个 inbound 共享同一个 socks5-out-X，此处删除会连带断开它们。
        if out_tag not in ("direct", "block"):
            config["outbounds"] = [o for o in config["outbounds"] if o.get("tag") != out_tag]

    with open(config_file, "w") as f:
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

troubleshoot() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              排错诊断                         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    ERRORS=0

    echo -e "${GREEN}[1/8] Xray 服务状态${NC}"
    if systemctl is-active --quiet xray; then
        echo -e "  ${GREEN}✓ Xray 正在运行${NC}"
    else
        echo -e "  ${RED}✗ Xray 未运行${NC}"
        ERRORS=$((ERRORS + 1))
        echo -e "  ${YELLOW}最近日志:${NC}"
        journalctl -u xray -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    fi

    echo ""
    echo -e "${GREEN}[2/8] 配置文件检查${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "  ${GREEN}✓ 配置文件存在${NC}"
        if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
            echo -e "  ${GREEN}✓ JSON 格式正确${NC}"
        else
            echo -e "  ${RED}✗ JSON 格式错误${NC}"
            ERRORS=$((ERRORS + 1))
            echo -e "  ${YELLOW}尝试: python3 -m json.tool $CONFIG_FILE${NC}"
        fi
        # 用 Python 解析检查 privateKey，避免 grep 对 JSON 空格格式敏感
        if python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
for inb in cfg.get('inbounds', []):
    if inb.get('tag') == 'api-in':
        continue
    pk = inb.get('streamSettings', {}).get('realitySettings', {}).get('privateKey', '')
    if not pk:
        sys.exit(1)
" 2>/dev/null; then
            echo -e "  ${GREEN}✓ privateKey 已配置${NC}"
        else
            echo -e "  ${RED}✗ privateKey 为空或缺失${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo -e "  ${RED}✗ 配置文件不存在${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""
    echo -e "${GREEN}[3/8] 端口监听检查${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        PORTS=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    config=json.load(f)
for inb in config.get('inbounds',[]):
    print(inb.get('port',''))
" 2>/dev/null)
        for PORT in $PORTS; do
            if ss -tlnp | grep -q ":${PORT} "; then
                echo -e "  ${GREEN}✓ 端口 ${PORT} 正在监听${NC}"
            else
                echo -e "  ${RED}✗ 端口 ${PORT} 未监听${NC}"
                ERRORS=$((ERRORS + 1))
            fi
        done
    fi

    echo ""
    echo -e "${GREEN}[4/8] 防火墙检查${NC}"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
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
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        echo -e "  firewalld: 运行中"
        if [ -f "$CONFIG_FILE" ]; then
            # set -e 下赋值语句里的命令失败会直接杀脚本
            OPEN_PORTS=$(firewall-cmd --list-ports 2>/dev/null || true)
            for PORT in $PORTS; do
                if echo "$OPEN_PORTS" | grep -q "${PORT}/tcp"; then
                    echo -e "  ${GREEN}✓ 端口 ${PORT} 已放行 (firewalld)${NC}"
                else
                    echo -e "  ${YELLOW}⚠ 端口 ${PORT} 可能未放行 (firewalld)${NC}"
                fi
            done
        fi
    else
        echo -e "  未检测到 UFW 或 firewalld，跳过（使用 iptables 兜底）"
    fi

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

    echo ""
    echo -e "${GREEN}[6/8] BBR 状态${NC}"
    BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$BBR" = "bbr" ]; then
        echo -e "  ${GREEN}✓ BBR 已启用${NC}"
    else
        echo -e "  ${RED}✗ BBR 未启用 (当前: ${BBR})${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    echo ""
    echo -e "${GREEN}[7/8] 系统资源${NC}"
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    if [ "${MEM_TOTAL:-0}" -gt 0 ]; then
        MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    else
        MEM_PERCENT=0
    fi
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

    echo ""
    echo -e "${GREEN}[8/8] 最近错误日志${NC}"
    RECENT_ERRORS=$(journalctl -u xray --since "1 hour ago" --no-pager 2>/dev/null | grep -i -E "error|fail|refused" | tail -5)
    if [ -n "$RECENT_ERRORS" ]; then
        echo -e "  ${YELLOW}发现以下错误:${NC}"
        echo "$RECENT_ERRORS" | sed 's/^/    /'
    else
        echo -e "  ${GREEN}✓ 最近1小时无错误${NC}"
    fi

    echo ""
    echo -e "${CYAN}━━━ 诊断总结 ━━━${NC}"
    if [ $ERRORS -eq 0 ]; then
        echo -e "${GREEN}✓ 所有检查通过，未发现问题${NC}"
    else
        echo -e "${RED}发现 ${ERRORS} 个问题，请根据上方提示修复${NC}"
    fi
    echo ""
}

uninstall() {
    read -p "确认卸载 Xray？(y/n): " CONFIRM
    if [ "$CONFIRM" = "y" ]; then
        # 停止并禁用所有相关服务（set -e 下必须加 || true，
        # 否则遇到不存在的服务 systemctl 返回非零会直接中断清理流程）
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        systemctl stop xray-monitor.timer 2>/dev/null || true
        systemctl disable xray-monitor.timer 2>/dev/null || true

        # 卸载 Xray 主体（下载失败就跳过远程卸载，本地文件清理照旧继续）
        run_xray_installer remove || echo -e "${YELLOW}⚠ 官方卸载脚本无法运行，将仅清理本地文件${NC}"

        # 清理监控相关 systemd 单元
        rm -f /etc/systemd/system/xray-monitor.service
        rm -f /etc/systemd/system/xray-monitor.timer
        rm -rf /etc/systemd/system/xray.service.d
        systemctl daemon-reload 2>/dev/null || true

        # 清理流量记录 cron（crontab -l 在没 crontab 的情况下会失败）
        (crontab -l 2>/dev/null || true) | grep -v "xray_traffic_record" | crontab - 2>/dev/null || true

        # 清理各类数据/配置文件
        rm -f "$INFO_FILE"
        rm -f "$SYSCTL_FILE"
        rm -f /root/.xray_traffic_db
        rm -f /root/.xray_traffic_record.sh
        rm -f /root/.xray_monitor.conf
        rm -f /root/.xray_monitor.sh
        rm -f /root/.xray_vps_ip
        rm -f /root/.msmtprc
        rm -f /tmp/.xray_node_failures
        rm -f /tmp/.xray_alert_lock_*

        # 应用 sysctl 清除（避免 BBR 参数残留影响其他服务诊断时混淆）
        sysctl --system >/dev/null 2>&1 || true

        # 询问是否清理 swapfile
        if [ -f /swapfile ]; then
            read -p "是否同时移除 /swapfile（1G swap）？(y/n): " RM_SWAP
            if [ "$RM_SWAP" = "y" ]; then
                swapoff /swapfile 2>/dev/null || true
                rm -f /swapfile
                sed -i '\|/swapfile none swap sw 0 0|d' /etc/fstab 2>/dev/null || true
                echo -e "${GREEN}✓ swapfile 已移除${NC}"
            fi
        fi

        echo -e "${GREEN}已完整卸载${NC}"
    fi
}

update_xray() {
    echo -e "${GREEN}[更新 Xray]${NC}"
    
    if command -v xray &>/dev/null; then
        CURRENT=$(xray version 2>/dev/null | head -1)
        echo -e "  当前版本: ${YELLOW}${CURRENT}${NC}"
    else
        echo -e "  ${RED}Xray 未安装${NC}"
        return
    fi

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

    if ! run_xray_installer install; then
        echo -e "${RED}更新中止：无法下载安装脚本，现有 Xray 保持不变${NC}"
        return
    fi

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

# ========== 监控报警 ==========
MONITOR_CONF="/root/.xray_monitor.conf"
MONITOR_SCRIPT="/root/.xray_monitor.sh"
MONITOR_LOG="/var/log/xray/monitor.log"

# 构造符合 SMTP 规范的邮件内容（使用 \r\n 作为行分隔符）
build_mail() {
    local subject="$1"
    local body="$2"
    local from="$3"
    local to="$4"
    printf "Subject: %s\r\nFrom: %s\r\nTo: %s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s" \
        "$subject" "$from" "$to" "$body"
}

setup_mail() {
    echo -e "${GREEN}[配置邮件通知]${NC}"
    echo ""

    if ! command -v msmtp &>/dev/null; then
        echo "正在安装邮件发送工具..."
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y msmtp msmtp-mta
        elif command -v dnf &>/dev/null; then
            dnf install -y msmtp
        elif command -v yum &>/dev/null; then
            yum install -y msmtp
        else
            echo -e "${RED}未检测到支持的包管理器 (apt/dnf/yum)，请手动安装 msmtp${NC}"
            return 1
        fi
    fi

    echo -e "${CYAN}支持 Gmail / QQ邮箱 / 163邮箱 等${NC}"
    echo ""
    read -p "SMTP 服务器 (如 smtp.gmail.com / smtp.qq.com): " SMTP_HOST
    read -p "SMTP 端口 (通常 587 或 465): " SMTP_PORT
    read -p "发件邮箱: " MAIL_FROM
    read -sp "邮箱密码/授权码: " MAIL_PASS
    echo ""
    read -p "收件邮箱 (报警发到哪): " MAIL_TO

    TLS_TYPE="on"
    TLS_STARTTLS="on"
    if [ "$SMTP_PORT" = "465" ]; then
        TLS_TYPE="on"
        TLS_STARTTLS="off"
    fi

    cat > /root/.msmtprc << EOF
defaults
auth           on
tls            ${TLS_TYPE}
tls_starttls   ${TLS_STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account        alert
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${MAIL_FROM}
user           ${MAIL_FROM}
password       ${MAIL_PASS}

account default : alert
EOF
    chmod 600 /root/.msmtprc

    cat > "$MONITOR_CONF" << EOF
MAIL_TO=${MAIL_TO}
MAIL_FROM=${MAIL_FROM}
CHECK_INTERVAL=60
AUTO_RESTART=yes
EOF

    echo -e "${YELLOW}正在发送测试邮件...${NC}"
    TEST_BODY="Xray 监控报警测试邮件
服务器: $(curl -s4 --max-time 5 ip.sb 2>/dev/null || echo unknown)
时间: $(date)"

    # set -e 下，管道末尾命令失败会直接杀脚本。
    # 用 if 条件包裹才能正确走到 else 分支打印错误提示。
    if build_mail "Xray Monitor Test" "$TEST_BODY" "$MAIL_FROM" "$MAIL_TO" | msmtp "$MAIL_TO" 2>/dev/null; then
        echo -e "${GREEN}✓ 测试邮件发送成功，请检查收件箱${NC}"
    else
        echo -e "${RED}✗ 发送失败，请检查 SMTP 配置${NC}"
        echo -e "${YELLOW}常见问题：Gmail 需要开启应用专用密码，QQ邮箱需要授权码${NC}"
    fi
}

install_monitor() {
    if [ ! -f "$MONITOR_CONF" ]; then
        echo -e "${RED}请先配置邮件通知（选 a）${NC}"
        return
    fi

    source "$MONITOR_CONF"
    VPS_IP=$(get_ip)

    cat > "$MONITOR_SCRIPT" << 'MONEOF'
#!/bin/bash
CONFIG_FILE="/usr/local/etc/xray/config.json"
MONITOR_CONF="/root/.xray_monitor.conf"
MONITOR_LOG="/var/log/xray/monitor.log"
ALERT_LOCK="/tmp/.xray_alert_lock"

source "$MONITOR_CONF"
VPS_IP=$(curl -s4 ip.sb 2>/dev/null || echo "unknown")
HOSTNAME=$(hostname)
NOW=$(date "+%Y-%m-%d %H:%M:%S")

log() {
    echo "[$NOW] $1" >> "$MONITOR_LOG"
}

send_alert() {
    local SUBJECT="$1"
    local BODY="$2"
    local LOCK_KEY=$(echo "$SUBJECT" | md5sum | cut -d' ' -f1)
    local LOCK_FILE="${ALERT_LOCK}_${LOCK_KEY}"

    if [ -f "$LOCK_FILE" ]; then
        local LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if [ "$LOCK_AGE" -lt 1800 ]; then
            return
        fi
    fi

    local FULL_BODY="${BODY}

服务器: ${VPS_IP} (${HOSTNAME})
时间: ${NOW}"

    printf "Subject: [Xray Alert] %s\r\nFrom: %s\r\nTo: %s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s" \
        "$SUBJECT" "$MAIL_FROM" "$MAIL_TO" "$FULL_BODY" | msmtp "$MAIL_TO" 2>/dev/null

    touch "$LOCK_FILE"
    log "ALERT SENT: $SUBJECT"
}

ERRORS=0
DETAILS=""

if ! systemctl is-active --quiet xray; then
    ERRORS=$((ERRORS + 1))
    DETAILS="${DETAILS}
[故障] Xray 进程已停止"
    log "ERROR: Xray is not running"

    if [ "$AUTO_RESTART" = "yes" ]; then
        systemctl restart xray
        sleep 3
        if systemctl is-active --quiet xray; then
            DETAILS="${DETAILS}
[恢复] 已自动重启成功"
            log "AUTO RESTART: success"
        else
            DETAILS="${DETAILS}
[失败] 自动重启失败，需要手动处理"
            log "AUTO RESTART: failed"
        fi
    fi
fi

if [ -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$CONFIG_FILE" python3 << 'PYEOF'
import json, socket, os

with open(os.environ["CONFIG_FILE"], "r") as f:
    config = json.load(f)

failures = []
for ob in config.get("outbounds", []):
    if ob.get("protocol") == "socks":
        servers = ob.get("settings", {}).get("servers", [])
        tag = ob.get("tag", "unknown")
        for s in servers:
            addr = s["address"]
            port = s["port"]
            try:
                sock = socket.create_connection((addr, port), timeout=10)
                sock.close()
            except Exception as e:
                failures.append(f"{addr}:{port} [{tag}] - {e}")

# 写标记文件代替 sys.exit(1)，避免 systemd service 记录为 failed
failure_file = "/tmp/.xray_node_failures"
if failures:
    with open(failure_file, "w") as f:
        for fail in failures:
            f.write(fail + "\n")
else:
    if os.path.exists(failure_file):
        os.remove(failure_file)
PYEOF

    if [ -f /tmp/.xray_node_failures ]; then
        ERRORS=$((ERRORS + 1))
        NODE_FAILURES=$(cat /tmp/.xray_node_failures)
        DETAILS="${DETAILS}
[故障] 落地节点不通:
${NODE_FAILURES}"
        log "ERROR: Node unreachable: $NODE_FAILURES"
    fi
fi

MEM_PERCENT=$(free | awk '/Mem:/ {if ($2>0) printf "%.0f", $3/$2*100; else print 0}')
if [ "$MEM_PERCENT" -gt 90 ]; then
    ERRORS=$((ERRORS + 1))
    DETAILS="${DETAILS}
[警告] 内存使用率 ${MEM_PERCENT}%"
    log "WARNING: Memory usage ${MEM_PERCENT}%"
fi

DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_PERCENT" -gt 90 ]; then
    ERRORS=$((ERRORS + 1))
    DETAILS="${DETAILS}
[警告] 磁盘使用率 ${DISK_PERCENT}%"
    log "WARNING: Disk usage ${DISK_PERCENT}%"
fi

if [ -f "$CONFIG_FILE" ]; then
    PORTS=$(CONFIG_FILE="$CONFIG_FILE" python3 -c "
import json, os
with open(os.environ['CONFIG_FILE']) as f:
    config=json.load(f)
for inb in config.get('inbounds',[]):
    print(inb.get('port',''))
" 2>/dev/null)
    for PORT in $PORTS; do
        if ! ss -tlnp | grep -q ":${PORT} "; then
            ERRORS=$((ERRORS + 1))
            DETAILS="${DETAILS}
[故障] 端口 ${PORT} 未监听"
            log "ERROR: Port ${PORT} not listening"
        fi
    done
fi

if [ $ERRORS -gt 0 ]; then
    send_alert "发现 ${ERRORS} 个问题" "$DETAILS"
fi

if [ $ERRORS -eq 0 ]; then
    log "OK: All checks passed"
fi

if [ -f "$MONITOR_LOG" ]; then
    LOG_SIZE=$(stat -c %s "$MONITOR_LOG" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 10485760 ]; then
        tail -n 5000 "$MONITOR_LOG" > "${MONITOR_LOG}.tmp"
        mv "${MONITOR_LOG}.tmp" "$MONITOR_LOG"
    fi
fi
MONEOF

    chmod +x "$MONITOR_SCRIPT"

    cat > /etc/systemd/system/xray-monitor.service << EOF
[Unit]
Description=Xray Monitor Check
After=network.target

[Service]
Type=oneshot
ExecStart=/root/.xray_monitor.sh
EOF

    cat > /etc/systemd/system/xray-monitor.timer << 'EOF'
[Unit]
Description=Xray Monitor Timer

[Timer]
OnCalendar=minutely
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable xray-monitor.timer
    systemctl start xray-monitor.timer

    echo -e "${GREEN}✓ 监控已启动（每分钟检查一次）${NC}"
    echo -e "${GREEN}  检查项: Xray进程 / 节点连通 / 内存 / 磁盘 / 端口${NC}"
    echo -e "${GREEN}  自动重启: 已开启${NC}"
    echo -e "${GREEN}  报警邮件: ${MAIL_TO}${NC}"
    echo -e "${GREEN}  日志文件: ${MONITOR_LOG}${NC}"
}

stop_monitor() {
    systemctl stop xray-monitor.timer 2>/dev/null
    systemctl disable xray-monitor.timer 2>/dev/null
    echo -e "${GREEN}✓ 监控已停止${NC}"
}

show_monitor_log() {
    if [ -f "$MONITOR_LOG" ]; then
        echo -e "${GREEN}━━━ 最近50条监控日志 ━━━${NC}"
        tail -n 50 "$MONITOR_LOG"
    else
        echo "暂无日志"
    fi
}

monitor_menu() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              监控报警管理                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    if systemctl is-active --quiet xray-monitor.timer 2>/dev/null; then
        echo -e "  当前状态: ${GREEN}运行中${NC}"
    else
        echo -e "  当前状态: ${RED}未启动${NC}"
    fi
    echo ""

    echo "  a) 配置邮件通知"
    echo "  b) 启动监控"
    echo "  c) 停止监控"
    echo "  d) 查看监控日志"
    echo "  e) 发送测试邮件"
    echo "  f) 返回主菜单"
    echo ""
    read -p "  选择: " MON_CHOICE

    case $MON_CHOICE in
        a)
            setup_mail
            ;;
        b)
            install_monitor
            ;;
        c)
            stop_monitor
            ;;
        d)
            show_monitor_log
            ;;
        e)
            if [ -f "$MONITOR_CONF" ]; then
                source "$MONITOR_CONF"
                VPS_IP=$(get_ip)
                TEST_BODY="测试邮件
服务器: ${VPS_IP}
时间: $(date)"
                if build_mail "Xray Monitor Test" "$TEST_BODY" "$MAIL_FROM" "$MAIL_TO" | msmtp "$MAIL_TO" 2>/dev/null; then
                    echo -e "${GREEN}✓ 测试邮件已发送${NC}"
                else
                    echo -e "${RED}✗ 发送失败${NC}"
                fi
            else
                echo -e "${RED}请先配置邮件（选 a）${NC}"
            fi
            ;;
        f)
            return
            ;;
    esac
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
    echo "  10) 监控报警"
    echo "  11) 卸载"
    echo "  12) 添加 VPS 直连节点 (不经住宅 IP)"
    echo "  0) 退出"
    echo ""
    read -p "请选择 [0-12]: " CHOICE

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
            monitor_menu
            ;;
        11)
            uninstall
            ;;
        12)
            add_direct_node
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac

    echo ""
    read -p "按回车键返回主菜单..." _
}

# ========== 启动前依赖自检 ==========
preflight_check() {
    local missing=()
    for cmd in python3 curl ss; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠ 缺少必要工具: ${missing[*]}${NC}"
        echo -e "${YELLOW}  正在尝试自动安装...${NC}"
        if command -v apt &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt update -y >/dev/null 2>&1 || true
            apt install -y python3 curl iproute2 >/dev/null 2>&1 || true
        elif command -v dnf &>/dev/null; then
            dnf install -y python3 curl iproute >/dev/null 2>&1 || true
        elif command -v yum &>/dev/null; then
            yum install -y python3 curl iproute >/dev/null 2>&1 || true
        fi
        # 再次检查
        for cmd in python3 curl ss; do
            if ! command -v "$cmd" &>/dev/null; then
                echo -e "${RED}✗ 无法自动安装 $cmd，请手动安装后重试${NC}"
                exit 1
            fi
        done
        echo -e "${GREEN}✓ 依赖已就绪${NC}"
    fi
}

preflight_check

while true; do
    main_menu
done