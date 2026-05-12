#!/bin/bash
# =====================================================
#  Xray VLESS Reality 中转 → SOCKS5 住宅节点 万能部署脚本
#  By Wayne Shen
#
#  v2.2.1 修复点：
#    - 所有节点变更路径都会同步刷新订阅文件
#    - 补充订阅文件生成测试，并在卸载时清理订阅文件
#
#  v2.2 改进点：
#    - 新增批量添加住宅 SOCKS5 节点，一次最多导入 20 个
#    - 批量节点自动以 IP/host 命名，成功后逐条输出链接和二维码
#    - 自动生成 base64 订阅内容和 Data URL 订阅链接
#
#  v2.1 改进点（基于 code review）：
#    - 配置写入采用 备份 → 临时文件 → xray -test → 原子替换 → 失败回滚 流程
#    - 编号无效等校验失败时不再触发 firewall / 重启
#    - Xray 官方安装脚本默认使用 main，可通过 XRAY_INSTALL_REF pin 到固定 commit
#    - SOCKS5 输入支持 host:port:user:pass 常见格式，也支持 socks5:// URL 特殊字符格式
#    - 系统升级与依赖安装拆分（默认仅装依赖，XRAY_FULL_UPGRADE=1 才整机升级）
#    - 防火墙规则去重 + nftables 检测 + 安全组提示
#    - 敏感文件 umask 077 + chmod 600
#    - root / systemd / 443 占用预检
#    - SMTP 配置改用 Python 安全写入，避免特殊字符破坏文件
# =====================================================

set -e
umask 077

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
CONFIG_BACKUP_KEEP=5
INFO_FILE="/root/xray_nodes_info.txt"
SUB_FILE="/root/xray_subscription.txt"
SYSCTL_FILE="/etc/sysctl.d/99-xray.conf"
IP_CACHE_FILE="/root/.xray_vps_ip"
# VPS 公网 IP 缓存时间（秒）。EIP / 浮动 IP 切换后最多等 1 小时自动刷新。
IP_CACHE_TTL="${IP_CACHE_TTL:-3600}"
# 客户端指纹（chrome / firefox / safari / ios / android / edge / random）
CLIENT_FP="${CLIENT_FP:-chrome}"
# REALITY 伪装目标，可用环境变量覆盖：
#   REALITY_SERVER_NAME=www.apple.com REALITY_DEST=www.apple.com:443 bash xray_deploy.sh
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SERVER_NAME}:443}"
#
# === Xray 官方安装脚本来源（供应链安全） ===
#
# 默认使用 XTLS/Xray-install 的 main 分支，方便一键部署到新 VPS。
# 生产环境推荐把 XRAY_INSTALL_REF_DEFAULT 改成你审计过的具体 commit SHA：
#     XRAY_INSTALL_REF_DEFAULT="2f37cdc7a76ab8d6a5e3a7f0e5d2cafe..."
#     可选附加 sha256 校验：
#     XRAY_INSTALL_SHA256_DEFAULT="<sha256 of install-release.sh at that commit>"
#     拿到方法：
#       git ls-remote https://github.com/XTLS/Xray-install.git refs/heads/main
#       curl -L https://raw.githubusercontent.com/XTLS/Xray-install/<COMMIT>/install-release.sh \
#         | sha256sum
XRAY_INSTALL_REF_DEFAULT="main"
XRAY_INSTALL_SHA256_DEFAULT=""
XRAY_INSTALL_REF="${XRAY_INSTALL_REF:-$XRAY_INSTALL_REF_DEFAULT}"
XRAY_INSTALL_SHA256="${XRAY_INSTALL_SHA256:-$XRAY_INSTALL_SHA256_DEFAULT}"
# 是否在敏感输出中隐藏 UUID/密码片段（设 1 启用）
XRAY_REDACT="${XRAY_REDACT:-0}"

# qrencode 安装状态缓存：0=可用 1=不可用 unset=未尝试
_QRENCODE_CHECKED=""

# ========== 工具函数 ==========
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Xray VLESS Reality 中转部署工具 v2.2.1     ║"
    echo "║   多节点 · 一键部署 · 配置自动回滚           ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

redact() {
    # 隐藏中间字符，仅保留首 4 末 4
    local s="$1"
    if [ "$XRAY_REDACT" != "1" ] || [ ${#s} -lt 12 ]; then
        echo "$s"
        return
    fi
    echo "${s:0:4}…${s: -4}"
}

get_ip() {
    if [ -f "$IP_CACHE_FILE" ]; then
        local cache_age=$(( $(date +%s) - $(stat -c %Y "$IP_CACHE_FILE" 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt "$IP_CACHE_TTL" ]; then
            local cached_ip
            cached_ip=$(cat "$IP_CACHE_FILE" 2>/dev/null)
            if [ -n "$cached_ip" ]; then
                echo "$cached_ip"
                return
            fi
        fi
    fi

    local IP
    IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || \
         curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
         curl -s4 --max-time 5 icanhazip.com 2>/dev/null || true)
    if [ -z "$IP" ]; then
        echo -e "${RED}无法获取本机公网 IP，请手动输入:${NC}" >&2
        read -rp "VPS 公网 IP: " IP
    fi

    echo "$IP" > "$IP_CACHE_FILE" 2>/dev/null || true
    chmod 600 "$IP_CACHE_FILE" 2>/dev/null || true
    echo "$IP"
}

ensure_qrencode() {
    if [ "$_QRENCODE_CHECKED" = "0" ]; then return 0; fi
    if [ "$_QRENCODE_CHECKED" = "1" ]; then return 1; fi

    if command -v qrencode &>/dev/null; then
        _QRENCODE_CHECKED=0
        return 0
    fi
    echo -e "${YELLOW}首次使用二维码功能，正在安装 qrencode...${NC}" >&2
    local rc=1
    if command -v apt-get &>/dev/null; then
        apt-get install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    elif command -v dnf &>/dev/null; then
        dnf install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    elif command -v yum &>/dev/null; then
        yum install -y qrencode >/dev/null 2>&1 && rc=0 || rc=1
    else
        echo -e "${RED}未检测到支持的包管理器 (apt/dnf/yum)，跳过二维码显示${NC}" >&2
        _QRENCODE_CHECKED=1
        return 1
    fi
    if [ "$rc" -eq 0 ]; then
        _QRENCODE_CHECKED=0
        return 0
    fi
    echo -e "${RED}qrencode 安装失败，将跳过二维码显示（链接仍可手动复制）${NC}" >&2
    _QRENCODE_CHECKED=1
    return 1
}

show_qrcode() {
    local link="$1"
    local name="${2:-节点}"
    [ -z "$link" ] && return 0
    ensure_qrencode || return 0

    echo ""
    echo -e "${GREEN}┌─ 扫码导入 [${name}] ──────────────────────────${NC}"
    echo -e "${CYAN}  Shadowrocket / V2rayN / Neobox / V2rayNG 均可扫码${NC}"
    echo ""
    qrencode -t ANSIUTF8 -m 2 "$link" || {
        echo -e "${RED}  二维码生成失败${NC}"
        return 0
    }
    echo -e "${GREEN}└──────────────────────────────────────────────${NC}"
    echo ""
}

# ---------- 远程 Xray 安装脚本（pin 到固定 ref + 下载到文件后执行） ----------
# 用法: run_xray_installer install | remove
run_xray_installer() {
    local action="${1:-install}"
    local ref="$XRAY_INSTALL_REF"
    local expected_sha="$XRAY_INSTALL_SHA256"

    # 拒绝空 ref，避免拼出无意义的 raw URL
    if [ -z "$ref" ]; then
        echo -e "${RED}✗ Xray 安装脚本来源未配置${NC}"
        echo -e "${YELLOW}  请设置 XRAY_INSTALL_REF=main，或指定 XTLS/Xray-install 的具体 commit SHA。${NC}"
        echo -e "${YELLOW}  查询当前 main 的 commit SHA 可用：${NC}"
        echo -e "${YELLOW}    git ls-remote https://github.com/XTLS/Xray-install.git refs/heads/main${NC}"
        return 1
    fi

    local url="https://raw.githubusercontent.com/XTLS/Xray-install/${ref}/install-release.sh"
    echo "正在下载 Xray 安装脚本 (ref=${ref})..."
    if [ "$ref" = "main" ]; then
        echo -e "${YELLOW}⚠ 当前使用 main 分支（追新，无哈希校验）。${NC}"
        echo -e "${YELLOW}  生产环境强烈建议改用具体 commit SHA + sha256。${NC}"
    fi

    local tmp_script
    tmp_script=$(mktemp /tmp/xray-install.XXXXXX.sh)
    chmod 600 "$tmp_script"
    # shellcheck disable=SC2064  # 我们要的就是当前 tmp_script 路径展开
    trap "rm -f '$tmp_script'" RETURN

    if ! curl -fsSL --max-time 30 "$url" -o "$tmp_script" 2>/dev/null; then
        echo -e "${RED}✗ 无法下载 Xray 安装脚本${NC}"
        echo -e "${YELLOW}  URL: $url${NC}"
        echo -e "${YELLOW}  可能原因：网络不通 / GitHub 被墙 / DNS 污染 / commit 不存在${NC}"
        return 1
    fi

    # 简单 sanity check：必须以 #! 开头且包含 install-release 的特征字符串
    if ! head -1 "$tmp_script" | grep -q '^#!'; then
        echo -e "${RED}✗ 下载内容不是有效 shell 脚本（可能是错误页）${NC}"
        return 1
    fi
    if ! grep -q "Xray" "$tmp_script"; then
        echo -e "${RED}✗ 下载内容缺少 Xray 关键字，疑似被劫持${NC}"
        return 1
    fi

    # sha256 校验（如果配了 expected_sha）
    if [ -n "$expected_sha" ]; then
        local actual_sha
        actual_sha=$(sha256sum "$tmp_script" | awk '{print $1}')
        if [ "$actual_sha" != "$expected_sha" ]; then
            echo -e "${RED}✗ sha256 校验失败！${NC}"
            echo -e "${YELLOW}  预期: $expected_sha${NC}"
            echo -e "${YELLOW}  实际: $actual_sha${NC}"
            echo -e "${YELLOW}  上游可能强制推送了 commit，或者下载内容被劫持。${NC}"
            return 1
        fi
        echo -e "  ${GREEN}✓ sha256 校验通过${NC}"
    elif [ "$ref" != "main" ]; then
        # 用了固定 commit 但没配 sha256：给一个温和提示
        local actual_sha
        actual_sha=$(sha256sum "$tmp_script" | awk '{print $1}')
        echo -e "  ${CYAN}ℹ 当前下载的 sha256: $actual_sha${NC}"
        echo -e "  ${CYAN}  建议把这个值写进 XRAY_INSTALL_SHA256_DEFAULT 以启用校验${NC}"
    fi

    bash "$tmp_script" "$action"
}

# ---------- SOCKS5 输入解析 ----------
# 接受两种格式：
#   1. host:port:user:pass            （常见格式，密码不能含 :）
#   2. socks5://user:pass@host:port   （密码含特殊字符时使用，按 RFC 3986 URL 编码）
# 解析成功后通过全局变量 PARSED_HOST / PARSED_PORT / PARSED_USER / PARSED_PASS 返回；
# 解析失败时通过 PARSE_ERROR 返回错误文案。
parse_socks5_raw() {
    local raw="$1"
    local out payload
    PARSED_HOST="" PARSED_PORT="" PARSED_USER="" PARSED_PASS="" PARSE_ERROR=""
    if [ -z "$raw" ]; then
        PARSE_ERROR="输入不能为空"
        return 1
    fi
    out=$(INPUT="$raw" python3 - <<'PYEOF' 2>&1
import os, sys, re
from urllib.parse import urlsplit, unquote

raw = os.environ["INPUT"].strip()

def fail(msg):
    print(f"ERR\t{msg}")
    sys.exit(0)

def ok(host, port, user, pwd):
    try:
        p = int(port)
    except (TypeError, ValueError):
        fail(f"端口必须是数字: {port}")
    if not (1 <= p <= 65535):
        fail(f"端口超出范围 1-65535: {p}")
    if not host:
        fail("host 为空")
    if not user:
        fail("用户名为空")
    if pwd is None or pwd == "":
        fail("密码为空")
    for field in (host, str(p), user, pwd):
        if re.search(r'[\x00-\x1f\x7f]', field):
            fail("字段含控制字符（换行/Tab/回车等）")
    # 用 \x1f 分隔，控制字符已拒绝，避免 payload 被换行截断
    print("OK\t" + "\x1f".join([host, str(p), user, pwd]))
    sys.exit(0)

if raw.startswith(("socks5://", "socks://")):
    try:
        u = urlsplit(raw)
        # 关键：urlsplit 本身不会抛，但 u.port getter 在端口非数字/越界时抛 ValueError
        # 必须把 hostname / port 的访问也包进同一个 try
        host = u.hostname
        port = u.port
        username = u.username
        password = u.password
    except Exception as e:
        fail(f"URL 解析失败: {e}")
    if not host or not port:
        fail("URL 缺少 host 或 port")
    ok(host, port, unquote(username or ""), unquote(password or ""))

m = re.match(r"^\[([0-9a-fA-F:]+)\]:(\d+):([^:]+):(.+)$", raw)
if m:
    ok(m.group(1), m.group(2), m.group(3), m.group(4))

parts = raw.split(":")
if len(parts) != 4:
    fail(f"常见格式必须 3 个冒号 (实际 {len(parts)-1} 个)；密码含特殊字符请改用 socks5://user:pass@host:port")

ok(parts[0], parts[1], parts[2], parts[3])
PYEOF
)
    if [[ "$out" == OK* ]]; then
        payload="${out#OK	}"
        IFS=$'\x1f' read -r PARSED_HOST PARSED_PORT PARSED_USER PARSED_PASS <<< "$payload"
        return 0
    fi
    PARSE_ERROR="${out#ERR	}"
    return 1
}

# 失败时循环让用户重新输入，直到合法或 Ctrl+C。
read_socks5() {
    local prompt="$1"
    local raw
    while true; do
        read -rp "$prompt" raw
        if parse_socks5_raw "$raw"; then
            return 0
        fi
        echo -e "${RED}格式错误: ${PARSE_ERROR}${NC}"
        echo -e "${CYAN}请重新输入，或按 Ctrl+C 退出${NC}"
    done
}

# ---------- 配置原子写入 ----------
# 用法: safe_write_config "<生成新配置的 python 命令名>" -- [可选环境变量传递]
# 该函数负责：
#   1. 备份原配置
#   2. 在 /tmp 生成新配置
#   3. xray run -test 校验
#   4. 原子 mv 替换
# 调用方只需提供一个把 NEW_CONFIG_FILE 路径读取并输出到该路径的 python 闭包
# 这里采用更直接的契约：调用方先把新配置写到 $1（临时文件），本函数负责其后的校验/替换
validate_and_install_config() {
    local new_config="$1"
    if [ ! -s "$new_config" ]; then
        echo -e "${RED}✗ 新配置文件为空: $new_config${NC}"
        rm -f "$new_config"
        return 1
    fi

    # JSON 合法性
    if ! python3 -c "import json,sys; json.load(open('$new_config'))" 2>/dev/null; then
        echo -e "${RED}✗ 新配置不是合法 JSON${NC}"
        rm -f "$new_config"
        return 1
    fi

    # xray -test
    if command -v xray &>/dev/null; then
        if ! xray run -test -config "$new_config" >/tmp/.xray-test.log 2>&1; then
            echo -e "${RED}✗ xray 配置测试失败：${NC}"
            sed 's/^/    /' /tmp/.xray-test.log
            rm -f "$new_config" /tmp/.xray-test.log
            return 1
        fi
        rm -f /tmp/.xray-test.log
    else
        echo -e "${YELLOW}⚠ xray 二进制尚未安装，跳过 -test 校验${NC}"
    fi

    # config.json 必须让 xray 服务用户(nobody)能读
    # 历史教训：盲目继承现有文件 owner/group 会延续错误（一旦老文件是 600 root:root，
    # 新文件继续 600，nobody 永远读不到，启动 permission denied）
    # 直接强制 644 root:root：/usr/local/etc/xray/ 目录默认 755 只有 root 能进入，
    # 即便文件 644 也不会泄露给非特权本地用户

    # 备份原配置
    if [ -f "$CONFIG_FILE" ]; then
        local ts backup
        ts=$(date +%Y%m%d-%H%M%S)
        backup="${CONFIG_FILE}.bak.${ts}"
        cp -a "$CONFIG_FILE" "$backup"
        chmod 600 "$backup"
        # 仅保留最近 N 份
        ls -1t "${CONFIG_FILE}.bak."* 2>/dev/null | tail -n +"$((CONFIG_BACKUP_KEEP+1))" | xargs -r rm -f
        echo -e "  ✓ 已备份原配置: $backup"
    fi

    # 原子替换 + 强制权限到 nobody 可读
    mv "$new_config" "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE" 2>/dev/null || true
    chmod 644 "$CONFIG_FILE"
    return 0
}

create_config_workfile() {
    local mode="${1:-empty}"
    local tmp
    if ! tmp=$(mktemp /tmp/.xray_config.new.XXXXXX.json); then
        echo -e "${RED}✗ 无法创建临时配置文件${NC}" >&2
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true

    if [ "$mode" = "copy" ]; then
        if ! cp "$CONFIG_FILE" "$tmp"; then
            echo -e "${RED}✗ 无法复制现有配置到临时文件: $tmp${NC}" >&2
            rm -f "$tmp"
            return 1
        fi
        chmod 600 "$tmp" 2>/dev/null || true
    fi

    echo "$tmp"
}

# 重启 xray 并在失败时回滚到最近备份
restart_with_rollback() {
    systemctl restart xray
    sleep 3
    if systemctl is-active --quiet xray; then
        return 0
    fi

    echo -e "${RED}✗ Xray 重启失败，准备回滚...${NC}"
    local last_backup
    last_backup=$(ls -1t "${CONFIG_FILE}.bak."* 2>/dev/null | head -1)
    if [ -z "$last_backup" ]; then
        echo -e "${RED}✗ 找不到任何备份文件，无法自动回滚${NC}"
        echo -e "${YELLOW}  请手动检查: journalctl -u xray -n 30${NC}"
        return 1
    fi

    cp -a "$last_backup" "$CONFIG_FILE"
    systemctl restart xray
    sleep 3
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}✓ 已回滚到 $last_backup，Xray 恢复运行${NC}"
        return 1   # 业务上仍然算"操作失败"
    fi

    echo -e "${RED}✗ 回滚后 Xray 仍未启动，请手动排查${NC}"
    echo -e "${YELLOW}  备份位置: $last_backup${NC}"
    return 1
}

get_next_inbound_port() {
    python3 << 'PYEOF'
import json, sys
config_file = "/usr/local/etc/xray/config.json"
with open(config_file) as f:
    config = json.load(f)
used = {inb.get("port", 0) for inb in config.get("inbounds", []) if inb.get("tag") != "api-in"}
candidate = 8443
while candidate in used:
    candidate += 1
    if candidate > 20000:
        print("ERROR: next inbound port exceeds 20000")
        sys.exit(2)
print(candidate)
PYEOF
}

port_in_use() {
    local port="$1"
    ss -tln 2>/dev/null | grep -q ":${port} "
}

config_port_in_use() {
    local port="$1"
    CONFIG_FILE="$CONFIG_FILE" CHECK_PORT="$port" python3 << 'PYEOF'
import json, os, sys
with open(os.environ["CONFIG_FILE"]) as f:
    config = json.load(f)
check = int(os.environ["CHECK_PORT"])
used = {
    inb.get("port")
    for inb in config.get("inbounds", [])
    if inb.get("tag") != "api-in"
}
sys.exit(0 if check in used else 1)
PYEOF
}

# apply_firewall_port_capture: 调用 apply_firewall_port 并把返回码塞到全局变量 LAST_FW_RC。
# 这样 set -e 下不会因为防火墙失败退出，调用方又能拿到状态做后续提示。
# 用法：apply_firewall_port_capture "$NEW_PORT"
apply_firewall_port_capture() {
    LAST_FW_RC=0
    apply_firewall_port "$1" || LAST_FW_RC=$?
    return 0
}

# format_fw_status: 根据 LAST_FW_RC 输出一行可附加在"节点添加成功"等消息后的状态提示
# 不输出任何内容时返回 0；调用方可以直接 echo "$(format_fw_status)"
format_fw_status() {
    case "${LAST_FW_RC:-0}" in
        0)  echo -e "${GREEN}防火墙: 已放行 ✓${NC}" ;;
        2)  echo -e "${YELLOW}防火墙: 未检测到后端，请确认默认策略允许该端口${NC}" ;;
        3)  echo -e "${RED}⚠ 防火墙放行失败！外部连接可能不通，请按上方提示手动处理${NC}" ;;
        *)  echo -e "${YELLOW}防火墙: 未知状态 (rc=${LAST_FW_RC})${NC}" ;;
    esac
}

persist_nftables_rules() {
    local tmp_conf backup
    tmp_conf=$(mktemp /tmp/.xray-nftables.XXXXXX.conf) || return 1

    if ! nft list ruleset > "$tmp_conf" 2>/dev/null; then
        rm -f "$tmp_conf"
        return 1
    fi

    if ! nft -c -f "$tmp_conf" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠ 当前 nft ruleset 无法通过配置校验，跳过持久化${NC}"
        rm -f "$tmp_conf"
        return 1
    fi

    if [ -f /etc/nftables.conf ]; then
        backup="/etc/nftables.conf.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a /etc/nftables.conf "$backup" 2>/dev/null || true
        [ -n "${backup:-}" ] && echo -e "  ${CYAN}ℹ 已备份 nftables 配置: ${backup}${NC}"
    fi

    if ! mv "$tmp_conf" /etc/nftables.conf; then
        rm -f "$tmp_conf"
        return 1
    fi
    chmod 600 /etc/nftables.conf 2>/dev/null || true

    if command -v systemctl &>/dev/null; then
        systemctl enable nftables >/dev/null 2>&1 || true
    fi
    return 0
}

nft_input_chains() {
    nft list ruleset 2>/dev/null | awk '
        /^table[ \t]+/ {
            family=$2
            table=$3
            gsub(/[ \t]*\{.*$/, "", table)
        }
        /^[ \t]*chain[ \t]+/ {
            chain=$2
            gsub(/[ \t]*\{.*$/, "", chain)
        }
        /hook[ \t]+input/ {
            policy="accept"
            for (i = 1; i <= NF; i++) {
                if ($i == "policy" && i < NF) {
                    policy=$(i + 1)
                    gsub(/[;}]/, "", policy)
                }
            }
            if (family != "" && table != "" && chain != "") {
                print family "\t" table "\t" chain "\t" policy
            }
        }
    '
}

# apply_firewall_port: 在主流防火墙后端中放行指定 TCP 端口
# 返回值：
#   0 = 成功放行（或规则已存在）
#   2 = 没找到任何已激活的防火墙后端 / 默认策略疑似 ACCEPT，可能不需要放行
#   3 = 检测到 nftables 但自动放行失败，外部连接很可能被丢弃
apply_firewall_port() {
    local port="$1"

    # UFW
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw allow "$port" >/dev/null 2>&1; then
            echo -e "  ${CYAN}ℹ 提醒：云厂商安全组仍需手动放行 ${port}/tcp${NC}"
            return 0
        fi
        echo -e "  ${RED}✗ ufw 处于 active 但放行端口 ${port} 失败${NC}"
        echo -e "  ${YELLOW}  请手动执行: ufw allow ${port}/tcp${NC}"
        echo -e "  ${YELLOW}  常见原因: 配置异常、规则上限、ufw 二进制损坏${NC}"
        return 3
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        local fw_add_rc=0 fw_reload_rc=0
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || fw_add_rc=$?
        firewall-cmd --reload >/dev/null 2>&1 || fw_reload_rc=$?
        if [ "$fw_add_rc" -eq 0 ] && [ "$fw_reload_rc" -eq 0 ]; then
            echo -e "  ${CYAN}ℹ 提醒：云厂商安全组仍需手动放行 ${port}/tcp${NC}"
            return 0
        fi
        echo -e "  ${RED}✗ firewalld 处于 active 但放行端口 ${port} 失败${NC}"
        echo -e "  ${YELLOW}  add-port rc=${fw_add_rc}, reload rc=${fw_reload_rc}${NC}"
        echo -e "  ${YELLOW}  请手动执行:${NC}"
        echo -e "  ${YELLOW}    firewall-cmd --zone=public --add-port=${port}/tcp --permanent${NC}"
        echo -e "  ${YELLOW}    firewall-cmd --reload${NC}"
        return 3
    fi

    # nftables：遍历实际存在的 input base chain。不同发行版/工具会创建不同表名，
    # 例如 fail2ban 常见 f2b-table/f2b-chain，不能假设一定有 inet filter input。
    if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q "^table"; then
        local nft_seen_input=0 nft_changed=0 nft_failed=0
        local family table chain policy chain_rules

        while IFS=$'\t' read -r family table chain policy; do
            [ -n "${family:-}" ] && [ -n "${table:-}" ] && [ -n "${chain:-}" ] || continue
            nft_seen_input=1
            policy="${policy:-accept}"

            chain_rules=$(nft list chain "$family" "$table" "$chain" 2>/dev/null || true)
            if echo "$chain_rules" | grep -qE "tcp dport .*\b${port}\b.* accept"; then
                echo -e "  ${GREEN}✓ nftables 已存在 ${port}/tcp 放行规则: ${family} ${table} ${chain}${NC}"
                continue
            fi

            if [ "$policy" = "drop" ] || [ "$policy" = "reject" ]; then
                if nft insert rule "$family" "$table" "$chain" tcp dport "$port" accept 2>/dev/null; then
                    nft_changed=1
                    echo -e "  ${GREEN}✓ 已通过 nftables 放行 ${port}/tcp: ${family} ${table} ${chain}${NC}"
                else
                    nft_failed=1
                    echo -e "  ${RED}✗ nftables 放行 ${port}/tcp 失败: ${family} ${table} ${chain}${NC}"
                fi
            else
                echo -e "  ${GREEN}✓ nftables input 链默认 ${policy}，无需额外放行: ${family} ${table} ${chain}${NC}"
            fi
        done < <(nft_input_chains)

        if [ "$nft_failed" -eq 0 ] && [ "$nft_seen_input" -eq 0 ]; then
            echo -e "  ${GREEN}✓ nftables 未发现 input 过滤链，系统默认不拦截入站${NC}"
        fi

        if [ "$nft_failed" -eq 0 ]; then
            if [ "$nft_changed" -eq 1 ]; then
                if persist_nftables_rules; then
                    echo -e "  ${GREEN}✓ nftables 规则已持久化到 /etc/nftables.conf${NC}"
                else
                    echo -e "  ${YELLOW}⚠ nftables 当前已放行，但自动持久化失败，重启后可能失效${NC}"
                fi
            fi
            echo -e "  ${CYAN}ℹ 提醒：云厂商安全组仍需手动放行 ${port}/tcp${NC}"
            return 0
        fi

        # 自动放行失败：返回硬错误
        echo -e "  ${RED}✗ 检测到 nftables，但未能自动放行端口 ${port}${NC}"
        echo -e "  ${YELLOW}  外部连接可能被默认 drop 策略丢弃，请按上方表/链名手动 insert 规则${NC}"
        echo -e "  ${YELLOW}    （或写入你的 /etc/nftables.conf 后 nft -f 重新加载）${NC}"
        echo -e "  ${CYAN}ℹ 提醒：云厂商安全组仍需手动放行 ${port}/tcp${NC}"
        return 3
    fi

    # iptables 兜底
    if command -v iptables &>/dev/null; then
        if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            :   # 已存在
        else
            local ipt_rc=0
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ipt_rc=$?
            if [ "$ipt_rc" -ne 0 ]; then
                echo -e "  ${RED}✗ iptables 插入规则失败 (rc=${ipt_rc})${NC}"
                echo -e "  ${YELLOW}  请手动执行: iptables -I INPUT -p tcp --dport ${port} -j ACCEPT${NC}"
                return 3
            fi
        fi
        local ipt_persisted=0
        if command -v netfilter-persistent &>/dev/null && netfilter-persistent save >/dev/null 2>&1; then
            ipt_persisted=1
        elif [ -d /etc/iptables ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
            ipt_persisted=1
        elif command -v service &>/dev/null && service iptables save >/dev/null 2>&1; then
            ipt_persisted=1
        fi
        if [ "$ipt_persisted" -eq 1 ]; then
            echo -e "  ${GREEN}✓ iptables 规则已尝试持久化${NC}"
        else
            echo -e "  ${YELLOW}⚠ iptables 当前已放行，但未检测到可用持久化工具，重启后可能失效${NC}"
        fi
        echo -e "  ${CYAN}ℹ 提醒：云厂商安全组仍需手动放行 ${port}/tcp${NC}"
        return 0
    fi

    # 完全没有任何防火墙后端可用
    echo -e "  ${YELLOW}⚠ 未检测到 ufw / firewalld / nftables / iptables，跳过${NC}"
    echo -e "  ${CYAN}ℹ 如系统默认策略是 ACCEPT，无需操作；否则请手动放行 ${port}/tcp${NC}"
    return 2
}

get_next_tag_num() {
    CONFIG_FILE="$CONFIG_FILE" python3 << 'PYEOF'
import json, os, re
with open(os.environ["CONFIG_FILE"]) as f:
    config = json.load(f)
max_num = 0
for inb in config.get("inbounds", []):
    m = re.fullmatch(r"vless-in-(\d+)", inb.get("tag", ""))
    if m:
        max_num = max(max_num, int(m.group(1)))
print(max_num + 1)
PYEOF
}

format_vless_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]\n' "$host"
    else
        printf '%s\n' "$host"
    fi
}

load_node_identity() {
    eval "$(
        CONFIG_FILE="$CONFIG_FILE" python3 << 'PYEOF'
import json, os, shlex
with open(os.environ["CONFIG_FILE"]) as f:
    config = json.load(f)
private_key = ""; short_id = ""; uuid = ""
for inb in config.get("inbounds", []):
    if inb.get("tag") == "api-in": continue
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

# ========== 系统更新 / 依赖安装 ==========
update_system() {
    echo -e "${GREEN}[步骤0] 安装必要依赖...${NC}"

    if command -v apt &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt install -y curl python3 iproute2 ca-certificates qrencode
        if [ "${XRAY_FULL_UPGRADE:-0}" = "1" ]; then
            echo -e "  ${YELLOW}XRAY_FULL_UPGRADE=1，执行完整系统升级...${NC}"
            apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
            apt autoremove -y
        else
            echo -e "  ${CYAN}ℹ 仅安装依赖（如需整机升级请用 XRAY_FULL_UPGRADE=1 重跑）${NC}"
        fi
        echo -e "  ${GREEN}✓ 依赖已就绪 (apt)${NC}"
    elif command -v dnf &>/dev/null; then
        dnf install -y curl python3 iproute ca-certificates qrencode
        if [ "${XRAY_FULL_UPGRADE:-0}" = "1" ]; then
            dnf update -y
        fi
        echo -e "  ${GREEN}✓ 依赖已就绪 (dnf)${NC}"
    elif command -v yum &>/dev/null; then
        yum install -y curl python3 iproute ca-certificates qrencode
        if [ "${XRAY_FULL_UPGRADE:-0}" = "1" ]; then
            yum update -y
        fi
        echo -e "  ${GREEN}✓ 依赖已就绪 (yum)${NC}"
    else
        echo -e "  ${YELLOW}⚠ 未识别的包管理器，跳过自动安装${NC}"
    fi

    if ! command -v python3 &>/dev/null; then
        echo -e "  ${RED}✗ 未检测到 python3，脚本无法继续${NC}"
        exit 1
    fi
}

install_xray() {
    echo -e "${GREEN}[步骤1] 检查并安装 Xray...${NC}"
    if command -v xray &>/dev/null; then
        echo "Xray 已安装: $(xray version | head -1)"
    else
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
    echo -e "  Private Key: ${YELLOW}$(redact "$PRIVATE_KEY")${NC}"
    echo -e "  Public Key:  ${YELLOW}${PUBLIC_KEY}${NC}"
    echo -e "  UUID:        ${YELLOW}$(redact "$UUID")${NC}"
    echo -e "  Short ID:    ${YELLOW}${SHORT_ID}${NC}"
}

derive_public_key() {
    local private_key="$1"
    local public_key
    public_key=$(xray x25519 -i "$private_key" 2>/dev/null | grep -i "public" | awk '{print $NF}' || true)
    if [ -z "$public_key" ]; then
        echo -e "${RED}✗ 无法派生 public key，请检查 xray 二进制或 private key${NC}" >&2
        return 1
    fi
    echo "$public_key"
}

collect_nodes() {
    echo ""
    echo -e "${GREEN}[步骤3] 添加 SOCKS5 住宅节点${NC}"
    echo -e "${CYAN}支持两种格式：${NC}"
    echo -e "${CYAN}  1) host:port:user:pass            (常见格式，推荐)${NC}"
    echo -e "${CYAN}  2) socks5://user:pass@host:port  (密码含 :@/ 等特殊字符时使用)${NC}"
    echo -e "${CYAN}（输入 done 跳过，脚本会创建一个 443 端口的 VPS 直连节点作为起点）${NC}"
    echo ""

    local SEP=$'\x1f'
    NODES=()
    NODE_NUM=0

    while true; do
        NODE_NUM=$((NODE_NUM + 1))
        local INPUT
        read -rp "节点${NODE_NUM} (输入 done 结束): " INPUT

        if [ "$INPUT" = "done" ] || [ "$INPUT" = "d" ] || [ -z "$INPUT" ]; then
            if [ ${#NODES[@]} -eq 0 ]; then
                echo ""
                echo -e "${YELLOW}你还没有添加任何住宅 SOCKS5 节点。${NC}"
                echo -e "${YELLOW}是否创建一个 443 端口的 VPS 直连节点作为起点？${NC}"
                local EMPTY_CHOICE
                read -rp "输入 y 创建直连起步节点 / 其他键继续录入: " EMPTY_CHOICE
                if [ "$EMPTY_CHOICE" = "y" ] || [ "$EMPTY_CHOICE" = "Y" ]; then
                    local DIRECT_NAME
                    read -rp "  备注名称 (如 LA-Direct / JP-Direct，回车默认 VPS-Direct): " DIRECT_NAME
                    [ -z "$DIRECT_NAME" ] && DIRECT_NAME="VPS-Direct"
                    # 清理 URL 片段里的不安全字符（与其他节点录入保持一致）
                    DIRECT_NAME=$(echo "$DIRECT_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
                    [ -z "$DIRECT_NAME" ] && DIRECT_NAME="VPS-Direct"
                    NODES+=("443${SEP}__DIRECT__${SEP}${SEP}${SEP}${SEP}${DIRECT_NAME}")
                    echo -e "${GREEN}  ✓ 已添加直连起步节点: ${DIRECT_NAME} (监听端口: 443)${NC}"
                    break
                fi
                NODE_NUM=0
                continue
            fi
            break
        fi

        # 严格解析 + 校验
        if ! parse_socks5_raw "$INPUT"; then
            echo -e "${RED}格式错误: ${PARSE_ERROR}${NC}"
            NODE_NUM=$((NODE_NUM - 1))
            continue
        fi
        local S_HOST S_PORT S_USER S_PASS
        S_HOST="$PARSED_HOST"
        S_PORT="$PARSED_PORT"
        S_USER="$PARSED_USER"
        S_PASS="$PARSED_PASS"

        local LISTEN_PORT
        if [ $NODE_NUM -eq 1 ]; then
            LISTEN_PORT=443
        else
            LISTEN_PORT=$((8442 + NODE_NUM))
        fi

        local NODE_NAME
        read -rp "  备注名称 (如 KR-Seoul / US-LA，回车跳过): " NODE_NAME
        [ -z "$NODE_NAME" ] && NODE_NAME="Node-${NODE_NUM}"
        NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
        [ -z "$NODE_NAME" ] && NODE_NAME="Node-${NODE_NUM}"

        NODES+=("${LISTEN_PORT}${SEP}${S_HOST}${SEP}${S_PORT}${SEP}${S_USER}${SEP}${S_PASS}${SEP}${NODE_NAME}")
        echo -e "${GREEN}  ✓ 已添加: ${NODE_NAME} → ${S_HOST}:${S_PORT} (监听 ${LISTEN_PORT})${NC}"
        echo ""
    done
}

generate_config() {
    echo -e "${GREEN}[步骤4] 生成 Xray 配置文件...${NC}"
    NODES_DATA=$(printf '%s\n' "${NODES[@]}")

    local NEW_CONFIG
    if ! NEW_CONFIG=$(create_config_workfile empty); then
        echo -e "${RED}配置生成失败，无法创建临时配置${NC}"
        return 1
    fi

    NEW_CONFIG_FILE="$NEW_CONFIG" \
    UUID="$UUID" \
    PRIVATE_KEY="$PRIVATE_KEY" \
    SHORT_ID="$SHORT_ID" \
    REALITY_DEST="$REALITY_DEST" \
    REALITY_SERVER_NAME="$REALITY_SERVER_NAME" \
    NODES_DATA="$NODES_DATA" \
    python3 << 'PYEOF'
import json, os
new_config = os.environ["NEW_CONFIG_FILE"]
uuid = os.environ["UUID"]
private_key = os.environ["PRIVATE_KEY"]
short_id = os.environ["SHORT_ID"]
reality_dest = os.environ["REALITY_DEST"]
reality_server_name = os.environ["REALITY_SERVER_NAME"]
raw_nodes = [line for line in os.environ["NODES_DATA"].splitlines() if line.strip()]

inbounds = [{"tag":"api-in","port":10085,"listen":"127.0.0.1","protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}}]
outbounds = []
rules = [
    {"type":"field","inboundTag":["api-in"],"outboundTag":"api"},
    {"type":"field","outboundTag":"block","protocol":["bittorrent"]},
    {"type":"field","outboundTag":"direct","ip":["geoip:private"]},
]

for idx, node in enumerate(raw_nodes, start=1):
    port, s_host, s_port, s_user, s_pass, name = node.split("\x1f", 5)
    tag_in = f"vless-in-{idx}"
    inbounds.append({
        "tag": tag_in, "port": int(port), "protocol": "vless",
        "_remark": name,
        "settings": {"clients":[{"id":uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
        "streamSettings": {"network":"tcp","security":"reality",
            "realitySettings":{"dest":reality_dest,"serverNames":[reality_server_name],
                "privateKey":private_key,"shortIds":[short_id]},
            "sockopt":{"tcpFastOpen":True,"tcpNoDelay":True}},
        "sniffing":{"enabled":True,"destOverride":["http","tls"]}
    })
    if s_host == "__DIRECT__":
        rules.append({"type":"field","inboundTag":[tag_in],"outboundTag":"direct"})
        continue
    tag_out = f"socks5-out-{idx}"
    outbounds.append({
        "tag": tag_out, "protocol": "socks",
        "settings":{"servers":[{"address":s_host,"port":int(s_port),"users":[{"user":s_user,"pass":s_pass}]}]},
        "streamSettings":{"sockopt":{"tcpFastOpen":True,"tcpNoDelay":True}}
    })
    rules.append({"type":"field","inboundTag":[tag_in],"outboundTag":tag_out})

config = {
    "log":{"loglevel":"warning"},"stats":{},
    "api":{"tag":"api","services":["StatsService"]},
    "policy":{"system":{"statsInboundUplink":True,"statsInboundDownlink":True,
                        "statsOutboundUplink":True,"statsOutboundDownlink":True}},
    "inbounds": inbounds,
    "outbounds": outbounds + [{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],
    "routing":{"domainStrategy":"IPIfNonMatch","rules":rules}
}
with open(new_config,"w") as f:
    json.dump(config, f, indent=4)
os.chmod(new_config, 0o600)
PYEOF

    if ! validate_and_install_config "$NEW_CONFIG"; then
        echo -e "${RED}配置生成失败，部署终止${NC}"
        exit 1
    fi
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
    local fw_rc
    for NODE in "${NODES[@]}"; do
        IFS=$'\x1f' read -r PORT _ _ _ _ _ <<< "$NODE"
        fw_rc=0
        apply_firewall_port "$PORT" || fw_rc=$?
        case "$fw_rc" in
            0) echo "  ✓ 端口 ${PORT} 已放行" ;;
            2) echo -e "  ${YELLOW}⚠ 端口 ${PORT}: 未检测到防火墙，未做放行${NC}" ;;
            3) echo -e "  ${RED}⚠ 端口 ${PORT}: 防火墙自动放行失败，外部连接可能不通！请按上方提示手动处理${NC}" ;;
            *) echo -e "  ${RED}⚠ 端口 ${PORT}: 防火墙处理异常 (rc=${fw_rc})${NC}" ;;
        esac
    done
}

start_service() {
    echo -e "${GREEN}[步骤7] 启动 Xray...${NC}"
    systemctl daemon-reload
    systemctl enable xray
    if restart_with_rollback; then
        echo -e "  ${GREEN}✓ Xray 启动成功！${NC}"
    else
        echo -e "  ${RED}✗ 启动失败，查看日志: journalctl -u xray -n 20${NC}"
        exit 1
    fi
}

print_result() {
    VPS_IP=$(get_ip)
    local LINK_HOST
    LINK_HOST=$(format_vless_host "$VPS_IP")
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              部署完成！                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""
    : > "$INFO_FILE"
    chmod 600 "$INFO_FILE"

    for i in "${!NODES[@]}"; do
        IFS=$'\x1f' read -r PORT S_HOST S_PORT S_USER S_PASS NAME <<< "${NODES[$i]}"
        LINK="vless://${UUID}@${LINK_HOST}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NAME}"

        echo -e "${GREEN}━━━ ${NAME} ━━━${NC}"
        echo -e "  监听端口: ${PORT}"
        if [ "$S_HOST" = "__DIRECT__" ]; then
            echo -e "  出口:     VPS 直连 (${VPS_IP})"
        else
            echo -e "  落地节点: ${S_HOST}:${S_PORT}"
        fi
        echo -e "${YELLOW}  ${LINK}${NC}"
        echo ""

        {
            echo "=== ${NAME} ==="
            echo "端口: ${PORT}"
            if [ "$S_HOST" = "__DIRECT__" ]; then
                echo "出口: VPS 直连 (${VPS_IP})"
            else
                echo "落地: ${S_HOST}:${S_PORT}"
            fi
            echo "链接: ${LINK}"
            echo ""
        } >> "$INFO_FILE"

        show_qrcode "$LINK" "$NAME"
    done

    echo -e "${GREEN}━━━ 通用信息 ━━━${NC}"
    echo -e "  VPS IP:     ${VPS_IP}"
    echo -e "  UUID:       $(redact "$UUID")"
    echo -e "  Public Key: ${PUBLIC_KEY}"
    echo -e "  Short ID:   ${SHORT_ID}"
    echo ""
    echo -e "${GREEN}所有链接已保存到 ${INFO_FILE} (权限 600)${NC}"
    refresh_subscription_file_from_info || true
    print_subscription_info
    if [ "$CLIENT_FP" = "chrome" ]; then
        echo -e "${CYAN}ℹ iOS / Shadowrocket 用户如需更贴近 iOS 指纹，可用 CLIENT_FP=ios 重新运行脚本${NC}"
    fi
    if [ "$XRAY_REDACT" = "1" ]; then
        echo -e "${YELLOW}（敏感字段已隐藏，需查看完整信息请用 XRAY_REDACT=0 重跑或直接查看 INFO_FILE）${NC}"
    fi
}

refresh_info_file_from_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi

    if ! CONFIG_FILE="$CONFIG_FILE" python3 << 'PYEOF'
import json
import os
import sys

with open(os.environ["CONFIG_FILE"]) as f:
    config = json.load(f)

has_business = any(inb.get("tag") != "api-in" for inb in config.get("inbounds", []))
sys.exit(0 if has_business else 1)
PYEOF
    then
        : > "$INFO_FILE"
        chmod 600 "$INFO_FILE" 2>/dev/null || true
        : > "$SUB_FILE"
        chmod 600 "$SUB_FILE" 2>/dev/null || true
        return 0
    fi

    local VPS_IP PUBLIC_KEY
    VPS_IP=$(get_ip)
    load_node_identity
    if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ]; then
        echo -e "${YELLOW}⚠ 无法从现有配置读取节点身份，跳过刷新 ${INFO_FILE}${NC}"
        return 1
    fi
    if ! PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY"); then
        echo -e "${YELLOW}⚠ 跳过刷新 ${INFO_FILE}${NC}"
        return 1
    fi

    CONFIG_FILE="$CONFIG_FILE" \
    INFO_FILE="$INFO_FILE" \
    VPS_IP="$VPS_IP" \
    UUID="$UUID" \
    PUBLIC_KEY="$PUBLIC_KEY" \
    SHORT_ID="$SHORT_ID" \
    CLIENT_FP="$CLIENT_FP" \
    REALITY_SERVER_NAME="$REALITY_SERVER_NAME" \
    REFRESH_NAME_PORT="${REFRESH_NAME_PORT:-}" \
    REFRESH_NAME="${REFRESH_NAME:-}" \
    python3 << 'PYEOF'
import json
import os
import re

config_file = os.environ["CONFIG_FILE"]
info_file = os.environ["INFO_FILE"]
vps_ip = os.environ["VPS_IP"]
uuid = os.environ["UUID"]
public_key = os.environ["PUBLIC_KEY"]
short_id = os.environ["SHORT_ID"]
client_fp = os.environ["CLIENT_FP"]
reality_server_name = os.environ["REALITY_SERVER_NAME"]

def format_vless_host(host):
    if ":" in host and not (host.startswith("[") and host.endswith("]")):
        return f"[{host}]"
    return host

link_host = format_vless_host(vps_ip)

old_names = {}
if os.path.exists(info_file):
    current_name = None
    with open(info_file, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            m = re.fullmatch(r"===\s*(.*?)\s*===", line)
            if m:
                current_name = m.group(1).strip() or None
                continue
            m = re.fullmatch(r"端口:\s*(\d+)", line)
            if m and current_name:
                old_names[int(m.group(1))] = current_name

override_port = os.environ.get("REFRESH_NAME_PORT", "")
override_name = os.environ.get("REFRESH_NAME", "")
if override_port and override_name:
    try:
        old_names[int(override_port)] = override_name
    except ValueError:
        pass

with open(config_file) as f:
    config = json.load(f)

outbounds = {ob.get("tag"): ob for ob in config.get("outbounds", [])}
route_by_inbound = {}
for rule in config.get("routing", {}).get("rules", []):
    out_tag = rule.get("outboundTag")
    for tag in rule.get("inboundTag", []) or []:
        route_by_inbound[tag] = out_tag

lines = []
for inb in config.get("inbounds", []):
    tag = inb.get("tag", "")
    if tag == "api-in":
        continue
    port = inb.get("port")
    if not isinstance(port, int):
        continue

    out_tag = route_by_inbound.get(tag, "")
    ob = outbounds.get(out_tag, {})
    name = old_names.get(port)
    if not name:
        name = inb.get("_remark")
    if not name:
        name = "VPS-Direct" if out_tag == "direct" else f"Port-{port}"
    safe_name = re.sub(r"[\s#?&\r\n\t]+", "-", name).strip("-") or f"Port-{port}"

    if out_tag == "direct":
        dest_line = f"出口: VPS 直连 ({vps_ip})"
    else:
        servers = ob.get("settings", {}).get("servers", [])
        if servers:
            dest_line = f"落地: {servers[0].get('address', '?')}:{servers[0].get('port', '?')}"
        else:
            dest_line = f"出口: {out_tag or 'unknown'}"

    link = (
        f"vless://{uuid}@{link_host}:{port}"
        f"?encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni={reality_server_name}&fp={client_fp}&pbk={public_key}"
        f"&sid={short_id}&type=tcp#{safe_name}"
    )
    lines.extend([f"=== {safe_name} ===", f"端口: {port}", dest_line, f"链接: {link}", ""])

with open(info_file, "w") as f:
    f.write("\n".join(lines))
    if lines:
        f.write("\n")
PYEOF
    chmod 600 "$INFO_FILE" 2>/dev/null || true
    refresh_subscription_file_from_info || true
}

sanitize_node_name() {
    local name="$1"
    local fallback="${2:-Node}"
    name=$(printf '%s' "$name" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
    [ -z "$name" ] && name="$fallback"
    printf '%s\n' "$name"
}

refresh_subscription_file_from_info() {
    if ! INFO_FILE="$INFO_FILE" SUB_FILE="$SUB_FILE" python3 << 'PYEOF'
import base64
import os
import re

info_file = os.environ["INFO_FILE"]
sub_file = os.environ["SUB_FILE"]
links = []

if os.path.exists(info_file):
    with open(info_file, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            m = re.match(r"^链接:\s*(\S+)\s*$", raw.strip())
            if m:
                links.append(m.group(1))

content = "\n".join(links)
if links:
    content += "\n"
encoded = base64.b64encode(content.encode("utf-8")).decode("ascii")
with open(sub_file, "w", encoding="utf-8") as f:
    f.write(encoded + "\n")
os.chmod(sub_file, 0o600)
PYEOF
    then
        echo -e "${YELLOW}⚠ 订阅内容生成失败，节点链接仍已保存到 ${INFO_FILE}${NC}" >&2
        return 1
    fi
}

print_subscription_info() {
    if [ ! -f "$SUB_FILE" ]; then
        return 0
    fi

    echo -e "${GREEN}订阅内容已保存到 ${SUB_FILE} (base64，权限 600)${NC}"
    if [ "${XRAY_PRINT_SUB_DATA_URL:-0}" = "1" ]; then
        local data_uri
        data_uri=$(tr -d '\n' < "$SUB_FILE")
        echo -e "${GREEN}订阅链接 (Data URL):${NC}"
        echo -e "${YELLOW}data:text/plain;base64,${data_uri}${NC}"
    else
        echo -e "${CYAN}如确需在终端打印 Data URL，可设置 XRAY_PRINT_SUB_DATA_URL=1 后重跑对应操作。${NC}"
    fi
    echo -e "${CYAN}如需稳定远程订阅，可把 ${SUB_FILE} 的内容放到你自己的 HTTPS 静态地址。${NC}"
}

# ========== 批量添加节点（住宅 SOCKS5）==========
add_batch_nodes() {
    echo -e "${GREEN}[批量添加住宅 SOCKS5 节点]${NC}"
    echo -e "${CYAN}每行一个节点，最多 20 个；格式: host:port:user:pass${NC}"
    echo -e "${CYAN}也支持 socks5://user:pass@host:port。粘贴完成后输入 done 结束。${NC}"
    echo -e "${CYAN}线路名称会自动使用 host/IP。${NC}"
    echo ""

    VPS_IP=$(get_ip)

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到现有配置，请先完整安装！${NC}"
        return
    fi

    load_node_identity
    if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$UUID" ]; then
        echo -e "${RED}现有配置中的业务节点密钥信息不完整${NC}"
        return
    fi
    PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY") || return

    local RAW_LINES=()
    local INPUT
    while [ "${#RAW_LINES[@]}" -lt 20 ]; do
        read -r INPUT || break
        if [ "$INPUT" = "done" ] || [ "$INPUT" = "d" ]; then
            break
        fi
        if [ -z "$INPUT" ]; then
            echo -e "${YELLOW}空行已忽略；请输入 done 结束批量录入。${NC}"
            continue
        fi
        RAW_LINES+=("$INPUT")
    done

    if [ "${#RAW_LINES[@]}" -eq 20 ]; then
        echo -e "${YELLOW}已达到单次批量上限 20 个节点。${NC}"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        echo -e "${YELLOW}未输入任何节点，已取消。${NC}"
        return
    fi

    local NEXT_PORT NEXT_TAG
    if ! NEXT_PORT=$(get_next_inbound_port); then
        echo -e "${RED}${NEXT_PORT:-ERROR: 无法计算下一个监听端口}${NC}"
        return
    fi
    NEXT_TAG=$(get_next_tag_num)

    local SEP=$'\x1f'
    local BATCH_NODES=()
    local i line S_HOST S_PORT S_USER S_PASS NODE_NAME TAG_NUM LISTEN_PORT LINK_HOST LINK
    LISTEN_PORT="$NEXT_PORT"
    for i in "${!RAW_LINES[@]}"; do
        line="${RAW_LINES[$i]}"
        if ! parse_socks5_raw "$line"; then
            echo -e "${RED}第 $((i + 1)) 行格式错误: ${PARSE_ERROR}${NC}"
            echo -e "${CYAN}未修改配置，请修正后重新批量导入。${NC}"
            return
        fi

        S_HOST="$PARSED_HOST"
        S_PORT="$PARSED_PORT"
        S_USER="$PARSED_USER"
        S_PASS="$PARSED_PASS"
        NODE_NAME=$(sanitize_node_name "$S_HOST" "Node-$((i + 1))")
        TAG_NUM=$((NEXT_TAG + i))

        while port_in_use "$LISTEN_PORT" || config_port_in_use "$LISTEN_PORT"; do
            LISTEN_PORT=$((LISTEN_PORT + 1))
            if [ "$LISTEN_PORT" -gt 20000 ]; then
                echo -e "${RED}未找到足够的可用监听端口${NC}"
                return
            fi
        done

        BATCH_NODES+=("${TAG_NUM}${SEP}${LISTEN_PORT}${SEP}${S_HOST}${SEP}${S_PORT}${SEP}${S_USER}${SEP}${S_PASS}${SEP}${NODE_NAME}")
        echo -e "${GREEN}  ✓ 准备添加: ${NODE_NAME} → ${S_HOST}:${S_PORT} (监听 ${LISTEN_PORT})${NC}"
        LISTEN_PORT=$((LISTEN_PORT + 1))
    done

    local NEW_CONFIG BATCH_DATA
    if ! NEW_CONFIG=$(create_config_workfile copy); then
        return
    fi
    BATCH_DATA=$(printf '%s\n' "${BATCH_NODES[@]}")

    if ! NEW_CONFIG_FILE="$NEW_CONFIG" \
        UUID="$UUID" PRIVATE_KEY="$PRIVATE_KEY" SHORT_ID="$SHORT_ID" \
        REALITY_DEST="$REALITY_DEST" REALITY_SERVER_NAME="$REALITY_SERVER_NAME" \
        BATCH_DATA="$BATCH_DATA" \
        python3 << 'PYEOF'
import json
import os
import sys

new_config = os.environ["NEW_CONFIG_FILE"]
uuid = os.environ["UUID"]
private_key = os.environ["PRIVATE_KEY"]
short_id = os.environ["SHORT_ID"]
reality_dest = os.environ["REALITY_DEST"]
reality_server_name = os.environ["REALITY_SERVER_NAME"]
raw_nodes = [line for line in os.environ["BATCH_DATA"].splitlines() if line.strip()]

with open(new_config) as f:
    config = json.load(f)

outbounds = config.setdefault("outbounds", [])
if not any(ob.get("tag") == "direct" for ob in outbounds):
    outbounds.append({"tag": "direct", "protocol": "freedom"})
if not any(ob.get("tag") == "block" for ob in outbounds):
    outbounds.append({"tag": "block", "protocol": "blackhole"})

new_outbounds = []
rules = config.setdefault("routing", {}).setdefault("rules", [])
for node in raw_nodes:
    tag_num, new_port, s_host, s_port, s_user, s_pass, node_name = node.split("\x1f", 6)
    new_port = int(new_port)
    try:
        s_port = int(s_port)
    except ValueError:
        print("S_PORT 非数字")
        sys.exit(2)

    config.setdefault("inbounds", []).append({
        "tag": f"vless-in-{tag_num}", "port": new_port, "protocol": "vless",
        "_remark": node_name,
        "settings": {"clients": [{"id": uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"},
        "streamSettings": {"network": "tcp", "security": "reality",
            "realitySettings": {"dest": reality_dest, "serverNames": [reality_server_name],
                "privateKey": private_key, "shortIds": [short_id]},
            "sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
    })
    new_outbounds.append({
        "tag": f"socks5-out-{tag_num}", "protocol": "socks",
        "settings": {"servers": [{"address": s_host, "port": s_port, "users": [{"user": s_user, "pass": s_pass}]}]},
        "streamSettings": {"sockopt": {"tcpFastOpen": True, "tcpNoDelay": True}}
    })
    rules.append({"type": "field", "inboundTag": [f"vless-in-{tag_num}"], "outboundTag": f"socks5-out-{tag_num}"})

insert_at = next((idx for idx, ob in enumerate(outbounds) if ob.get("tag") == "direct"), len(outbounds))
outbounds[insert_at:insert_at] = new_outbounds

with open(new_config, "w") as f:
    json.dump(config, f, indent=4)
PYEOF
    then
        echo -e "${RED}配置生成失败${NC}"
        rm -f "$NEW_CONFIG"
        return
    fi

    if ! validate_and_install_config "$NEW_CONFIG"; then
        echo -e "${RED}新配置校验失败，已保留原配置${NC}"
        return
    fi

    if restart_with_rollback; then
        echo ""
        echo -e "${GREEN}正在放行批量节点端口...${NC}"
        for line in "${BATCH_NODES[@]}"; do
            IFS=$'\x1f' read -r _ LISTEN_PORT _ _ _ _ _ <<< "$line"
            apply_firewall_port_capture "$LISTEN_PORT"
            echo -e "  ${LISTEN_PORT}: $(format_fw_status)"
        done

        echo ""
        echo -e "${GREEN}✓ 批量节点添加成功！共 ${#BATCH_NODES[@]} 个${NC}"
        REFRESH_NAME_PORT="" REFRESH_NAME="" refresh_info_file_from_config || true
        for line in "${BATCH_NODES[@]}"; do
            IFS=$'\x1f' read -r _ LISTEN_PORT S_HOST S_PORT _ _ NODE_NAME <<< "$line"
            LINK_HOST=$(format_vless_host "$VPS_IP")
            LINK="vless://${UUID}@${LINK_HOST}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"
            echo ""
            echo -e "${GREEN}━━━ ${NODE_NAME} ━━━${NC}"
            echo -e "  监听端口: ${LISTEN_PORT}"
            echo -e "  落地节点: ${S_HOST}:${S_PORT}"
            echo -e "${YELLOW}  ${LINK}${NC}"
            show_qrcode "$LINK" "$NODE_NAME"
        done
        print_subscription_info
    fi
}

# ========== 添加节点（住宅 SOCKS5）==========
add_node() {
    echo -e "${GREEN}[添加节点模式]${NC}"
    VPS_IP=$(get_ip)

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到现有配置，请先完整安装！${NC}"
        return
    fi

    load_node_identity
    if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$UUID" ]; then
        echo -e "${RED}现有配置中的业务节点密钥信息不完整${NC}"
        return
    fi
    PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY") || return

    if ! NEW_PORT=$(get_next_inbound_port); then
        echo -e "${RED}${NEW_PORT:-ERROR: 无法计算下一个监听端口}${NC}"
        return
    fi
    while port_in_use "$NEW_PORT"; do
        NEW_PORT=$((NEW_PORT + 1))
        if [ "$NEW_PORT" -gt 20000 ]; then
            echo -e "${RED}未找到可用监听端口${NC}"; return
        fi
    done
    echo -e "新的监听端口: ${NEW_PORT}"

    # 严格解析 SOCKS5 输入
    PARSED_HOST="" PARSED_PORT="" PARSED_USER="" PARSED_PASS=""
    read_socks5 "节点信息 (host:port:user:pass 或 socks5://user:pass@host:port): "
    local S_HOST="$PARSED_HOST" S_PORT="$PARSED_PORT" S_USER="$PARSED_USER" S_PASS="$PARSED_PASS"

    local NODE_NAME
    read -rp "备注名称: " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="Node-new"
    NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
    [ -z "$NODE_NAME" ] && NODE_NAME="Node-new"

    TAG_NUM=$(get_next_tag_num)

    local NEW_CONFIG
    if ! NEW_CONFIG=$(create_config_workfile copy); then
        return
    fi

    if ! NEW_CONFIG_FILE="$NEW_CONFIG" \
        TAG_NUM="$TAG_NUM" NEW_PORT="$NEW_PORT" UUID="$UUID" \
        PRIVATE_KEY="$PRIVATE_KEY" SHORT_ID="$SHORT_ID" \
        REALITY_DEST="$REALITY_DEST" REALITY_SERVER_NAME="$REALITY_SERVER_NAME" \
        NODE_NAME="$NODE_NAME" \
        S_HOST="$S_HOST" S_PORT="$S_PORT" S_USER="$S_USER" S_PASS="$S_PASS" \
        python3 << 'PYEOF'
import json, os, sys
new_config = os.environ["NEW_CONFIG_FILE"]
tag_num = os.environ["TAG_NUM"]
new_port = int(os.environ["NEW_PORT"])
uuid = os.environ["UUID"]
private_key = os.environ["PRIVATE_KEY"]
short_id = os.environ["SHORT_ID"]
reality_dest = os.environ["REALITY_DEST"]
reality_server_name = os.environ["REALITY_SERVER_NAME"]
node_name = os.environ["NODE_NAME"]
s_host = os.environ["S_HOST"]
try:
    s_port = int(os.environ["S_PORT"])
except ValueError:
    print("S_PORT 非数字"); sys.exit(2)
s_user = os.environ["S_USER"]
s_pass = os.environ["S_PASS"]

with open(new_config) as f:
    config = json.load(f)

config.setdefault("inbounds", []).append({
    "tag": f"vless-in-{tag_num}", "port": new_port, "protocol": "vless",
    "_remark": node_name,
    "settings": {"clients":[{"id":uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings": {"network":"tcp","security":"reality",
        "realitySettings":{"dest":reality_dest,"serverNames":[reality_server_name],
            "privateKey":private_key,"shortIds":[short_id]},
        "sockopt":{"tcpFastOpen":True,"tcpNoDelay":True}},
    "sniffing":{"enabled":True,"destOverride":["http","tls"]}
})

outbounds = config.setdefault("outbounds", [])
if not any(ob.get("tag") == "direct" for ob in outbounds):
    outbounds.append({"tag":"direct","protocol":"freedom"})
if not any(ob.get("tag") == "block" for ob in outbounds):
    outbounds.append({"tag":"block","protocol":"blackhole"})

new_out = {
    "tag": f"socks5-out-{tag_num}", "protocol": "socks",
    "settings":{"servers":[{"address":s_host,"port":s_port,"users":[{"user":s_user,"pass":s_pass}]}]},
    "streamSettings":{"sockopt":{"tcpFastOpen":True,"tcpNoDelay":True}}
}
for idx, ob in enumerate(outbounds):
    if ob.get("tag") == "direct":
        outbounds.insert(idx, new_out); break
else:
    outbounds.append(new_out)

config.setdefault("routing", {}).setdefault("rules", []).append(
    {"type":"field","inboundTag":[f"vless-in-{tag_num}"],"outboundTag":f"socks5-out-{tag_num}"})

with open(new_config, "w") as f:
    json.dump(config, f, indent=4)
PYEOF
    then
        echo -e "${RED}配置生成失败${NC}"
        rm -f "$NEW_CONFIG"
        return
    fi

    if ! validate_and_install_config "$NEW_CONFIG"; then
        echo -e "${RED}新配置校验失败，已保留原配置${NC}"
        return
    fi

    if restart_with_rollback; then
        apply_firewall_port_capture "$NEW_PORT"
        local LINK_HOST
        LINK_HOST=$(format_vless_host "$VPS_IP")
        LINK="vless://${UUID}@${LINK_HOST}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"
        echo ""
        echo -e "${GREEN}✓ 节点添加成功！${NC}"
        echo -e "${GREEN}端口: ${NEW_PORT}${NC}"
        echo -e "${GREEN}落地: ${S_HOST}:${S_PORT}${NC}"
        echo -e "  $(format_fw_status)"
        echo -e "${YELLOW}${LINK}${NC}"
        REFRESH_NAME_PORT="$NEW_PORT" REFRESH_NAME="$NODE_NAME" refresh_info_file_from_config || true
        show_qrcode "$LINK" "$NODE_NAME"
        print_subscription_info
    fi
}

# ========== 添加 VPS 直连节点 ==========
add_direct_node() {
    echo -e "${GREEN}[添加 VPS 直连节点]${NC}"
    echo -e "${CYAN}流量直接从 VPS 出口，目标看到的是机房 IP。${NC}"
    VPS_IP=$(get_ip)

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到现有配置，请先完成【全新安装】！${NC}"; return
    fi

    load_node_identity
    if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$UUID" ]; then
        echo -e "${RED}现有配置密钥信息不完整${NC}"; return
    fi
    PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY") || return

    if ! NEW_PORT=$(get_next_inbound_port); then
        echo -e "${RED}${NEW_PORT:-ERROR: 无法计算下一个监听端口}${NC}"
        return
    fi
    while port_in_use "$NEW_PORT"; do
        NEW_PORT=$((NEW_PORT + 1))
        if [ "$NEW_PORT" -gt 20000 ]; then echo -e "${RED}无可用端口${NC}"; return; fi
    done
    echo -e "新的监听端口: ${NEW_PORT}"

    local NODE_NAME
    read -rp "备注名称 (默认 VPS-Direct): " NODE_NAME
    [ -z "$NODE_NAME" ] && NODE_NAME="VPS-Direct"
    NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
    [ -z "$NODE_NAME" ] && NODE_NAME="VPS-Direct"

    TAG_NUM=$(get_next_tag_num)

    local NEW_CONFIG
    if ! NEW_CONFIG=$(create_config_workfile copy); then
        return
    fi

    if ! NEW_CONFIG_FILE="$NEW_CONFIG" \
        TAG_NUM="$TAG_NUM" NEW_PORT="$NEW_PORT" UUID="$UUID" \
        PRIVATE_KEY="$PRIVATE_KEY" SHORT_ID="$SHORT_ID" \
        REALITY_DEST="$REALITY_DEST" REALITY_SERVER_NAME="$REALITY_SERVER_NAME" \
        NODE_NAME="$NODE_NAME" \
        python3 << 'PYEOF'
import json, os
new_config = os.environ["NEW_CONFIG_FILE"]
tag_num = os.environ["TAG_NUM"]
new_port = int(os.environ["NEW_PORT"])
uuid = os.environ["UUID"]; private_key = os.environ["PRIVATE_KEY"]; short_id = os.environ["SHORT_ID"]
reality_dest = os.environ["REALITY_DEST"]; reality_server_name = os.environ["REALITY_SERVER_NAME"]
node_name = os.environ["NODE_NAME"]

with open(new_config) as f:
    config = json.load(f)

config.setdefault("inbounds", []).append({
    "tag": f"vless-in-{tag_num}", "port": new_port, "protocol": "vless",
    "_remark": node_name,
    "settings": {"clients":[{"id":uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings": {"network":"tcp","security":"reality",
        "realitySettings":{"dest":reality_dest,"serverNames":[reality_server_name],
            "privateKey":private_key,"shortIds":[short_id]},
        "sockopt":{"tcpFastOpen":True,"tcpNoDelay":True}},
    "sniffing":{"enabled":True,"destOverride":["http","tls"]}
})

outbounds = config.setdefault("outbounds", [])
if not any(ob.get("tag")=="direct" for ob in outbounds):
    outbounds.append({"tag":"direct","protocol":"freedom"})
if not any(ob.get("tag")=="block" for ob in outbounds):
    outbounds.append({"tag":"block","protocol":"blackhole"})

config.setdefault("routing",{}).setdefault("rules",[]).append(
    {"type":"field","inboundTag":[f"vless-in-{tag_num}"],"outboundTag":"direct"})

with open(new_config, "w") as f:
    json.dump(config, f, indent=4)
PYEOF
    then
        echo -e "${RED}配置生成失败${NC}"
        rm -f "$NEW_CONFIG"
        return
    fi

    if ! validate_and_install_config "$NEW_CONFIG"; then
        echo -e "${RED}配置校验失败${NC}"; return
    fi

    if restart_with_rollback; then
        apply_firewall_port_capture "$NEW_PORT"
        local LINK_HOST
        LINK_HOST=$(format_vless_host "$VPS_IP")
        LINK="vless://${UUID}@${LINK_HOST}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"
        echo ""
        echo -e "${GREEN}✓ VPS 直连节点添加成功！${NC}"
        echo -e "${GREEN}端口: ${NEW_PORT}${NC}"
        echo -e "${GREEN}出口: VPS 直连 (${VPS_IP})${NC}"
        echo -e "  $(format_fw_status)"
        echo -e "${YELLOW}${LINK}${NC}"
        REFRESH_NAME_PORT="$NEW_PORT" REFRESH_NAME="$NODE_NAME" refresh_info_file_from_config || true
        show_qrcode "$LINK" "$NODE_NAME"
        print_subscription_info
    fi
}

show_status() {
    echo -e "${GREEN}━━━ Xray 状态 ━━━${NC}"
    systemctl status xray --no-pager -l || true
    echo ""
    echo -e "${GREEN}━━━ BBR 状态 ━━━${NC}"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "BBR 尚未配置"
    echo ""
    echo -e "${GREEN}━━━ 节点信息 ━━━${NC}"
    refresh_info_file_from_config || true
    if [ ! -f "$INFO_FILE" ]; then
        echo "暂无节点信息"
        return
    fi
    if [ ! -s "$INFO_FILE" ]; then
        echo "暂无节点信息"
        return
    fi
    cat "$INFO_FILE"

    # 解析 INFO_FILE 里所有节点（名称 + 链接），让用户选择是否扫码
    # INFO_FILE 的结构（由 print_result / add_node / add_direct_node 写入）:
    #   === <名称> ===
    #   端口: ...
    #   出口/落地: ...
    #   链接: vless://...
    #   <空行>
    local names=() links=()
    local cur_name="" cur_link=""
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^===\ (.+)\ ===$ ]]; then
            cur_name="${BASH_REMATCH[1]}"
            cur_link=""
        elif [[ "$line" =~ ^链接:\ (.+)$ ]]; then
            cur_link="${BASH_REMATCH[1]}"
            if [ -n "$cur_name" ] && [ -n "$cur_link" ]; then
                names+=("$cur_name")
                links+=("$cur_link")
                cur_name=""; cur_link=""
            fi
        fi
    done < "$INFO_FILE"

    if [ ${#names[@]} -eq 0 ]; then
        return
    fi

    echo ""
    echo -e "${CYAN}━━━ 显示二维码 ━━━${NC}"
    local i=1
    for n in "${names[@]}"; do
        echo "  $i) $n"
        i=$((i + 1))
    done
    echo "  a) 全部"
    echo "  其他/回车) 跳过"
    echo ""
    local QR_CHOICE
    read -rp "  选择要显示二维码的节点: " QR_CHOICE

    case "$QR_CHOICE" in
        a|A)
            for idx in "${!names[@]}"; do
                show_qrcode "${links[$idx]}" "${names[$idx]}"
            done
            ;;
        ''|*[!0-9]*)
            return
            ;;
        *)
            local sel=$((QR_CHOICE - 1))
            if [ "$sel" -ge 0 ] && [ "$sel" -lt "${#names[@]}" ]; then
                show_qrcode "${links[$sel]}" "${names[$sel]}"
            else
                echo -e "${RED}编号超出范围${NC}"
            fi
            ;;
    esac
}

# ========== 流量统计（保持原逻辑，仅敏感文件加权限） ==========
TRAFFIC_DB="/root/.xray_traffic_db"

# 确保 cron 守护进程已安装并运行
# 某些精简发行版（如 Debian minimal）默认不带 cron / cronie，
# 历史教训：脚本菜单 6) 流量统计直接报 "crontab: command not found"
ensure_cron_installed() {
    if command -v crontab &>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}⚠ 未检测到 crontab，正在自动安装 cron...${NC}"
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y cron >/dev/null 2>&1 || true
        systemctl enable --now cron >/dev/null 2>&1 || true
    elif command -v dnf &>/dev/null; then
        dnf install -y cronie >/dev/null 2>&1 || true
        systemctl enable --now crond >/dev/null 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum install -y cronie >/dev/null 2>&1 || true
        systemctl enable --now crond >/dev/null 2>&1 || true
    fi
    if ! command -v crontab &>/dev/null; then
        echo -e "${RED}✗ 无法自动安装 cron，请手动执行: apt install cron 或 yum install cronie${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ cron 已安装并启动${NC}"
    return 0
}

setup_traffic_cron() {
    ensure_cron_installed || return 1
    CRON_SCRIPT="/root/.xray_traffic_record.sh"
    cat > "$CRON_SCRIPT" << 'CRONEOF'
#!/bin/bash
CONFIG_FILE="/usr/local/etc/xray/config.json"
TRAFFIC_DB="/root/.xray_traffic_db"
XRAY_BIN="/usr/local/bin/xray"
[ ! -f "$CONFIG_FILE" ] && exit 0
command -v xray &>/dev/null || exit 0

CONFIG_FILE="$CONFIG_FILE" TRAFFIC_DB="$TRAFFIC_DB" XRAY_BIN="$XRAY_BIN" \
python3 << 'PYEOF'
import json, subprocess, os, time
config_file = os.environ["CONFIG_FILE"]
db_file = os.environ["TRAFFIC_DB"]
xray_bin = os.environ["XRAY_BIN"]
timestamp = int(time.time())

with open(config_file) as f:
    config = json.load(f)

def get_stat(name):
    try:
        result = subprocess.run([xray_bin,"api","stats","--server=127.0.0.1:10085",f"-name={name}"],
                                capture_output=True, text=True, timeout=5)
        out = result.stdout.strip()
        if not out:
            return 0
        if out.startswith("{"):
            try:
                import json as _json
                v = _json.loads(out).get("stat", {}).get("value", 0)
                return int(v) if v else 0
            except Exception: pass
        for line in out.split("\n"):
            if "value:" in line.lower():
                val = line.split(":")[-1].strip()
                return int(val) if val else 0
    except Exception: pass
    return 0

last_cum = {}
if os.path.exists(db_file):
    try:
        with open(db_file) as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 5:
                    try:
                        last_cum[parts[1]] = (int(parts[3]), int(parts[4]))
                    except ValueError: pass
    except Exception: pass

new_rows = []
for inb in config.get("inbounds", []):
    tag = inb.get("tag", "")
    if tag == "api-in" or not tag: continue
    port = inb.get("port", 0)
    cur_up = get_stat(f"inbound>>>{tag}>>>traffic>>>uplink")
    cur_down = get_stat(f"inbound>>>{tag}>>>traffic>>>downlink")
    if tag not in last_cum:
        delta_up = 0
        delta_down = 0
    else:
        prev_up, prev_down = last_cum[tag]
        delta_up = cur_up if cur_up < prev_up else cur_up - prev_up
        delta_down = cur_down if cur_down < prev_down else cur_down - prev_down
    new_rows.append(f"{timestamp}|{tag}|{port}|{cur_up}|{cur_down}|{delta_up}|{delta_down}")

# 用 'a' 模式但创建时设置权限
fd = os.open(db_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
with os.fdopen(fd, "a") as f:
    for r in new_rows:
        f.write(r + "\n")

cutoff = timestamp - 60 * 86400
if os.path.exists(db_file):
    with open(db_file) as f:
        lines = f.readlines()
    fd = os.open(db_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        for line in lines:
            parts = line.strip().split("|")
            if len(parts) >= 5:
                try:
                    if int(parts[0]) > cutoff:
                        f.write(line)
                except ValueError: pass
PYEOF
CRONEOF

    chmod 700 "$CRON_SCRIPT"
    if ! crontab -l 2>/dev/null | grep -q "xray_traffic_record"; then
        (crontab -l 2>/dev/null || true; echo "*/5 * * * * /root/.xray_traffic_record.sh # xray_traffic_record") | crontab -
        echo -e "  ${GREEN}✓ 流量记录定时任务已安装 (每5分钟)${NC}"
    fi
}

show_traffic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件！${NC}"; return
    fi
    if ! grep -q '"StatsService"' "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}当前配置未启用流量统计 API${NC}"
        echo -e "${YELLOW}需要重新全新安装才能使用${NC}"; return
    fi

    setup_traffic_cron
    bash /root/.xray_traffic_record.sh 2>/dev/null

    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              节点流量统计                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    CONFIG_FILE="$CONFIG_FILE" TRAFFIC_DB="$TRAFFIC_DB" XRAY_BIN="/usr/local/bin/xray" \
    python3 << 'PYEOF'
import json, subprocess, os, time
config_file = os.environ["CONFIG_FILE"]; db_file = os.environ["TRAFFIC_DB"]; xray_bin = os.environ["XRAY_BIN"]
with open(config_file) as f:
    config = json.load(f)

def get_stat(name):
    try:
        r = subprocess.run([xray_bin,"api","stats","--server=127.0.0.1:10085",f"-name={name}"],
                           capture_output=True, text=True, timeout=5)
        out = r.stdout.strip()
        if not out:
            return 0
        if out.startswith("{"):
            try:
                import json as _json
                v = _json.loads(out).get("stat", {}).get("value", 0)
                return int(v) if v else 0
            except Exception: pass
        for line in out.split("\n"):
            if "value:" in line.lower():
                v = line.split(":")[-1].strip()
                return int(v) if v else 0
    except Exception: pass
    return 0

def fmt(b):
    b = abs(b)
    if b < 1024: return f"{b} B"
    if b < 1024**2: return f"{b/1024:.1f} KB"
    if b < 1024**3: return f"{b/1024**2:.1f} MB"
    return f"{b/1024**3:.2f} GB"

def get_dest(tag):
    for rule in config.get("routing",{}).get("rules",[]):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            ot = rule.get("outboundTag","")
            if ot == "direct": return "VPS"
            if ot == "block": return "BLOCK"
            for ob in config["outbounds"]:
                if ob.get("tag") == ot:
                    s = ob.get("settings",{}).get("servers",[])
                    if s: return s[0]["address"]
    return ""

print("  ━━━ 当前实时 (自上次启动) ━━━")
print(f"  {'节点':<22} {'上行':>10} {'下行':>10} {'合计':>10}")
print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
total_up=0; total_down=0
for inb in config.get("inbounds",[]):
    tag = inb.get("tag","");
    if tag == "api-in" or not tag: continue
    port = inb.get("port","?"); dest = get_dest(tag)
    up = get_stat(f"inbound>>>{tag}>>>traffic>>>uplink")
    down = get_stat(f"inbound>>>{tag}>>>traffic>>>downlink")
    total_up += up; total_down += down
    name = f":{port}→{dest}" if dest else f":{port}"
    print(f"  {name:<22} {fmt(up):>10} {fmt(down):>10} {fmt(up+down):>10}")
print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
print(f"  {'总计':<22} {fmt(total_up):>10} {fmt(total_down):>10} {fmt(total_up+total_down):>10}")

if not os.path.exists(db_file):
    print("\n  历史数据尚未积累，请等待5分钟后再查看")
else:
    records = []
    with open(db_file) as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 7:
                try:
                    records.append((int(parts[0]), parts[1], int(parts[2]), int(parts[5]), int(parts[6])))
                except ValueError: pass
    if records:
        now = int(time.time())
        periods = [("过去1小时", now-3600), ("今天", now-(now%86400)),
                   ("过去7天", now-7*86400), ("过去30天", now-30*86400)]
        tags = sorted({(r[1], r[2]) for r in records}, key=lambda x: x[1])
        for pn, since in periods:
            print(f"\n  ━━━ {pn} ━━━")
            print(f"  {'节点':<22} {'上行':>10} {'下行':>10} {'合计':>10}")
            print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
            tu=0; td=0
            for tag, port in tags:
                u = sum(r[3] for r in records if r[1]==tag and r[0]>=since)
                d = sum(r[4] for r in records if r[1]==tag and r[0]>=since)
                tu+=u; td+=d
                dest = get_dest(tag); name = f":{port}→{dest}" if dest else f":{port}"
                print(f"  {name:<22} {fmt(u):>10} {fmt(d):>10} {fmt(u+d):>10}")
            print(f"  {'─'*22} {'─'*10} {'─'*10} {'─'*10}")
            print(f"  {'总计':<22} {fmt(tu):>10} {fmt(td):>10} {fmt(tu+td):>10}")
PYEOF

    echo ""
    echo -e "${YELLOW}流量每5分钟自动记录，历史保留60天${NC}"
    echo "  r) 重置当前计数"
    echo "  c) 清除历史数据"
    echo "  其他) 返回"
    read -rp "  选择: " ACTION
    case $ACTION in
        r) xray api stats --server=127.0.0.1:10085 -reset 2>/dev/null
           echo -e "${GREEN}✓ 当前计数已重置${NC}";;
        c) rm -f "$TRAFFIC_DB"; echo -e "${GREEN}✓ 历史数据已清除${NC}";;
    esac
}

# ========== 修改端口（带原子写入 + 编号无效不重启） ==========
change_port() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件！${NC}"; return
    fi

    echo -e "${GREEN}[修改端口]${NC}"
    echo "当前节点端口:"
    python3 << 'PYEOF'
import json
with open("/usr/local/etc/xray/config.json") as f:
    config = json.load(f)
display_idx = 0
for inb in config["inbounds"]:
    if inb.get("tag") == "api-in": continue
    display_idx += 1
    tag = inb.get("tag","unknown"); port = inb.get("port","?")
    out_tag = None
    for rule in config.get("routing",{}).get("rules",[]):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            out_tag = rule.get("outboundTag"); break
    dest = ""
    if out_tag == "direct": dest = " → VPS 直连"
    elif out_tag:
        for ob in config["outbounds"]:
            if ob.get("tag") == out_tag:
                s = ob.get("settings",{}).get("servers",[])
                if s: dest = f" → {s[0]['address']}:{s[0]['port']}"
                break
    print(f"  {display_idx}) 端口 {port}{dest} [{tag}]")
PYEOF

    echo ""
    local IDX NEW_PORT
    read -rp "选择要修改的节点编号: " IDX
    read -rp "新端口号: " NEW_PORT
    if [ -z "$IDX" ] || [ -z "$NEW_PORT" ]; then
        echo -e "${RED}输入不能为空${NC}"; return
    fi
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}端口必须是 1-65535 的整数${NC}"; return
    fi
    if port_in_use "$NEW_PORT"; then
        echo -e "${RED}端口 ${NEW_PORT} 已被占用${NC}"; return
    fi

    local NEW_CONFIG
    if ! NEW_CONFIG=$(create_config_workfile copy); then
        return
    fi

    # 关键：Python 在编号无效时退出码 2，外层捕获后 return，不再走 firewall / restart
    if ! NEW_CONFIG_FILE="$NEW_CONFIG" IDX="$IDX" NEW_PORT="$NEW_PORT" python3 << 'PYEOF'
import json, os, sys
new_config = os.environ["NEW_CONFIG_FILE"]
try:
    idx = int(os.environ["IDX"]) - 1
except ValueError:
    print("编号必须是整数"); sys.exit(2)
new_port = int(os.environ["NEW_PORT"])

with open(new_config) as f:
    config = json.load(f)
business = [inb for inb in config["inbounds"] if inb.get("tag") != "api-in"]
if not (0 <= idx < len(business)):
    print(f"编号无效（应在 1-{len(business)} 之间）"); sys.exit(2)

target = business[idx]["tag"]; old = business[idx]["port"]
for inb in config["inbounds"]:
    if inb.get("tag") == target:
        inb["port"] = new_port; break
with open(new_config, "w") as f:
    json.dump(config, f, indent=4)
print(f"端口已从 {old} 修改为 {new_port}")
PYEOF
    then
        echo -e "${RED}✗ 修改取消（编号无效或参数错误），原配置保持不变${NC}"
        rm -f "$NEW_CONFIG"
        return
    fi

    if ! validate_and_install_config "$NEW_CONFIG"; then
        echo -e "${RED}配置校验失败，已保留原配置${NC}"; return
    fi

    if restart_with_rollback; then
        apply_firewall_port_capture "$NEW_PORT"
        echo -e "${GREEN}✓ 端口修改成功${NC}"
        echo -e "  $(format_fw_status)"
        VPS_IP=$(get_ip)
        load_node_identity
        PUBLIC_KEY=$(derive_public_key "$PRIVATE_KEY") || return
        NODE_NAME=$(CONFIG_FILE="$CONFIG_FILE" NEW_PORT="$NEW_PORT" python3 - << 'PYEOF'
import json
import os

port = int(os.environ["NEW_PORT"])
with open(os.environ["CONFIG_FILE"]) as f:
    config = json.load(f)
for inb in config.get("inbounds", []):
    if inb.get("port") == port:
        print(inb.get("_remark") or f"Port-{port}")
        break
else:
    print(f"Port-{port}")
PYEOF
)
        NODE_NAME=$(echo "$NODE_NAME" | tr ' \t#?&\r\n' '-' | tr -s '-' | sed 's/^-//; s/-$//')
        [ -z "$NODE_NAME" ] && NODE_NAME="Port-${NEW_PORT}"
        local LINK_HOST
        LINK_HOST=$(format_vless_host "$VPS_IP")
        NEW_LINK="vless://${UUID}@${LINK_HOST}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=${CLIENT_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"
        echo -e "${YELLOW}新链接:${NC} ${NEW_LINK}"
        refresh_info_file_from_config || true
        show_qrcode "$NEW_LINK" "$NODE_NAME"
        print_subscription_info
    fi
}

# ========== 删除节点（同样的安全模式）==========
delete_node() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}未找到配置文件！${NC}"; return
    fi
    echo -e "${GREEN}[删除节点]${NC}"
    echo "当前节点:"
    python3 << 'PYEOF'
import json
with open("/usr/local/etc/xray/config.json") as f:
    config = json.load(f)
i = 0
for inb in config["inbounds"]:
    if inb.get("tag") == "api-in": continue
    i += 1
    tag = inb.get("tag","unknown"); port = inb.get("port","?")
    out_tag = None
    for rule in config.get("routing",{}).get("rules",[]):
        if rule.get("inboundTag") and tag in rule["inboundTag"]:
            out_tag = rule.get("outboundTag"); break
    dest = ""
    if out_tag == "direct": dest = " → VPS 直连"
    elif out_tag:
        for ob in config["outbounds"]:
            if ob.get("tag") == out_tag:
                s = ob.get("settings",{}).get("servers",[])
                if s: dest = f" → {s[0]['address']}:{s[0]['port']}"
                break
    print(f"  {i}) 端口 {port}{dest} [{tag}]")
PYEOF

    echo ""
    local IDX
    read -rp "选择要删除的节点编号: " IDX
    if [ -z "$IDX" ]; then
        echo -e "${RED}输入不能为空${NC}"; return
    fi

    local NEW_CONFIG
    if ! NEW_CONFIG=$(create_config_workfile copy); then
        return
    fi

    if ! NEW_CONFIG_FILE="$NEW_CONFIG" IDX="$IDX" python3 << 'PYEOF'
import json, os, sys
new_config = os.environ["NEW_CONFIG_FILE"]
try:
    idx = int(os.environ["IDX"]) - 1
except ValueError:
    print("编号必须是整数"); sys.exit(2)

with open(new_config) as f:
    config = json.load(f)
business = [inb for inb in config["inbounds"] if inb.get("tag") != "api-in"]
if not (0 <= idx < len(business)):
    print(f"编号无效（应在 1-{len(business)} 之间）"); sys.exit(2)

tag = business[idx]["tag"]; port = business[idx]["port"]
config["inbounds"] = [inb for inb in config["inbounds"] if inb.get("tag") != tag]
out_tag = None; new_rules = []
for r in config["routing"]["rules"]:
    inb_tags = r.get("inboundTag", [])
    if inb_tags and tag in inb_tags:
        out_tag = r.get("outboundTag")
    else:
        new_rules.append(r)
config["routing"]["rules"] = new_rules

if out_tag and out_tag not in ("direct","block"):
    # 仅当没有其他规则引用此 outbound 时才删除（防止共享 outbound 被误删）
    still_used = any(out_tag in (r.get("outboundTag") or "") for r in config["routing"]["rules"])
    if not still_used:
        config["outbounds"] = [o for o in config["outbounds"] if o.get("tag") != out_tag]

with open(new_config, "w") as f:
    json.dump(config, f, indent=4)
print(f"已删除: 端口 {port} [{tag}]")
PYEOF
    then
        echo -e "${RED}✗ 删除取消（编号无效），原配置保持不变${NC}"
        rm -f "$NEW_CONFIG"
        return
    fi

    if ! validate_and_install_config "$NEW_CONFIG"; then
        echo -e "${RED}配置校验失败，已保留原配置${NC}"; return
    fi

    if restart_with_rollback; then
        refresh_info_file_from_config || true
        echo -e "${GREEN}✓ 节点已删除${NC}"
        print_subscription_info
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
        echo -e "  ${RED}✗ Xray 未运行${NC}"; ERRORS=$((ERRORS+1))
        journalctl -u xray -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    fi

    echo ""
    echo -e "${GREEN}[2/8] 配置文件检查${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "  ${GREEN}✓ 配置文件存在${NC}"
        if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
            echo -e "  ${GREEN}✓ JSON 格式正确${NC}"
        else
            echo -e "  ${RED}✗ JSON 格式错误${NC}"; ERRORS=$((ERRORS+1))
        fi
        if python3 -c "
import json,sys
cfg = json.load(open('$CONFIG_FILE'))
for inb in cfg.get('inbounds',[]):
    if inb.get('tag') == 'api-in': continue
    pk = inb.get('streamSettings',{}).get('realitySettings',{}).get('privateKey','')
    if not pk: sys.exit(1)
" 2>/dev/null; then
            echo -e "  ${GREEN}✓ privateKey 已配置${NC}"
        else
            echo -e "  ${RED}✗ privateKey 为空或缺失${NC}"; ERRORS=$((ERRORS+1))
        fi
    else
        echo -e "  ${RED}✗ 配置文件不存在${NC}"; ERRORS=$((ERRORS+1))
    fi

    echo ""
    echo -e "${GREEN}[3/8] 端口监听检查${NC}"
    PORTS=""
    if [ -f "$CONFIG_FILE" ]; then
        PORTS=$(python3 -c "
import json
cfg = json.load(open('$CONFIG_FILE'))
for inb in cfg.get('inbounds',[]):
    if inb.get('tag') == 'api-in': continue
    print(inb.get('port',''))" 2>/dev/null || true)
        if [ -z "$PORTS" ]; then
            echo -e "  ${YELLOW}⚠ 无法解析端口列表，跳过端口监听检查${NC}"
        fi
        for PORT in $PORTS; do
            if ss -tlnp | grep -q ":${PORT} "; then
                echo -e "  ${GREEN}✓ 端口 ${PORT} 正在监听${NC}"
            else
                echo -e "  ${RED}✗ 端口 ${PORT} 未监听${NC}"; ERRORS=$((ERRORS+1))
            fi
        done
    fi

    echo ""
    echo -e "${GREEN}[4/8] 防火墙检查${NC}"
    if [ -z "${PORTS:-}" ]; then
        echo -e "  ${YELLOW}⚠ 无法解析端口列表，跳过防火墙检查${NC}"
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
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
        echo -e "  未检测到 UFW / firewalld（使用 iptables 或 nftables 兜底）"
    fi

    echo ""
    echo -e "${GREEN}[5/8] SOCKS5 落地节点连通性${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        python3 << 'PYEOF'
import json, socket
with open("/usr/local/etc/xray/config.json") as f:
    config = json.load(f)
for ob in config["outbounds"]:
    if ob.get("protocol") == "socks":
        for s in ob.get("settings",{}).get("servers",[]):
            try:
                sock = socket.create_connection((s["address"], s["port"]), timeout=5)
                sock.close()
                print(f"  ✓ {s['address']}:{s['port']} [{ob.get('tag','?')}] 连通")
            except Exception as e:
                print(f"  ✗ {s['address']}:{s['port']} [{ob.get('tag','?')}] 不通 - {e}")
PYEOF
    fi

    echo ""
    echo -e "${GREEN}[6/8] BBR 状态${NC}"
    BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$BBR" = "bbr" ]; then echo -e "  ${GREEN}✓ BBR 已启用${NC}"
    else echo -e "  ${RED}✗ BBR 未启用 (当前: ${BBR})${NC}"; ERRORS=$((ERRORS+1)); fi

    echo ""
    echo -e "${GREEN}[7/8] 系统资源${NC}"
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_PERCENT=$([ "${MEM_TOTAL:-0}" -gt 0 ] && echo $((MEM_USED * 100 / MEM_TOTAL)) || echo 0)
    DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    echo -e "  内存: ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PERCENT}%)"
    [ "$MEM_PERCENT" -gt 90 ] && { echo -e "  ${RED}⚠ 内存使用率过高！${NC}"; ERRORS=$((ERRORS+1)); }
    echo -e "  磁盘: ${DISK_PERCENT}% 已用"
    [ "$DISK_PERCENT" -gt 90 ] && { echo -e "  ${RED}⚠ 磁盘空间不足！${NC}"; ERRORS=$((ERRORS+1)); }
    echo -e "  负载: ${CPU_LOAD}"

    echo ""
    echo -e "${GREEN}[8/8] 最近错误日志${NC}"
    RECENT=$(journalctl -u xray --since "1 hour ago" --no-pager 2>/dev/null | grep -i -E "error|fail|refused" | tail -5)
    if [ -n "$RECENT" ]; then
        echo -e "  ${YELLOW}发现错误:${NC}"
        echo "$RECENT" | sed 's/^/    /'
    else
        echo -e "  ${GREEN}✓ 最近1小时无错误${NC}"
    fi

    echo ""
    echo -e "${CYAN}━━━ 诊断总结 ━━━${NC}"
    if [ $ERRORS -eq 0 ]; then echo -e "${GREEN}✓ 所有检查通过${NC}"
    else echo -e "${RED}发现 ${ERRORS} 个问题${NC}"; fi
    echo ""
}

uninstall() {
    read -rp "确认卸载 Xray？(y/n): " CONFIRM
    if [ "$CONFIRM" = "y" ]; then
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        systemctl stop xray-monitor.timer 2>/dev/null || true
        systemctl disable xray-monitor.timer 2>/dev/null || true
        run_xray_installer remove || echo -e "${YELLOW}⚠ 远程卸载脚本无法运行，仅清理本地${NC}"
        rm -f /etc/systemd/system/xray-monitor.service /etc/systemd/system/xray-monitor.timer
        rm -rf /etc/systemd/system/xray.service.d
        systemctl daemon-reload 2>/dev/null || true
        (crontab -l 2>/dev/null || true) | grep -v "xray_traffic_record" | crontab - 2>/dev/null || true
        rm -f "$CONFIG_FILE" "$INFO_FILE" "$SUB_FILE" "$SYSCTL_FILE" /root/.xray_traffic_db /root/.xray_traffic_record.sh \
              /root/.xray_monitor.conf /root/.xray_monitor.sh /root/.xray_vps_ip /root/.msmtprc \
              /tmp/.xray_node_failures /tmp/.xray_alert_lock_*
        # 配置备份保留，让用户决定是否清理
        echo -e "${YELLOW}注意：配置备份 ${CONFIG_FILE}.bak.* 已保留，如需清理请手动删除${NC}"
        sysctl --system >/dev/null 2>&1 || true
        if [ -f /swapfile ]; then
            read -rp "是否同时移除 /swapfile？(y/n): " RM_SWAP
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
        echo -e "  当前版本: ${YELLOW}$(xray version 2>/dev/null | head -1)${NC}"
    else
        echo -e "  ${RED}Xray 未安装${NC}"; return
    fi

    LATEST=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    [ -n "$LATEST" ] && echo -e "  最新版本: ${YELLOW}${LATEST}${NC}" || echo -e "  ${YELLOW}无法获取最新版本号${NC}"

    read -rp "确认更新？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "已取消"; return; }

    if ! run_xray_installer install; then
        echo -e "${RED}更新中止：无法下载安装脚本${NC}"; return
    fi

    if restart_with_rollback; then
        echo -e "${GREEN}✓ 更新成功: $(xray version 2>/dev/null | head -1)${NC}"
    fi
}

# ========== 监控报警 ==========
MONITOR_CONF="/root/.xray_monitor.conf"
MONITOR_SCRIPT="/root/.xray_monitor.sh"
MONITOR_LOG="/var/log/xray/monitor.log"

build_mail() {
    local subject="$1" body="$2" from="$3" to="$4"
    printf "Subject: %s\r\nFrom: %s\r\nTo: %s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s" \
        "$subject" "$from" "$to" "$body"
}

setup_mail() {
    echo -e "${GREEN}[配置邮件通知]${NC}"
    if ! command -v msmtp &>/dev/null; then
        echo "正在安装 msmtp..."
        if command -v apt &>/dev/null; then apt update -y && apt install -y msmtp msmtp-mta
        elif command -v dnf &>/dev/null; then dnf install -y msmtp
        elif command -v yum &>/dev/null; then yum install -y msmtp
        else echo -e "${RED}请手动安装 msmtp${NC}"; return 1
        fi
    fi

    echo -e "${CYAN}支持 Gmail / QQ邮箱 / 163 等${NC}"
    local SMTP_HOST SMTP_PORT MAIL_FROM MAIL_PASS MAIL_TO
    read -rp "SMTP 服务器: " SMTP_HOST
    read -rp "SMTP 端口 (587/465): " SMTP_PORT
    read -rp "发件邮箱: " MAIL_FROM
    read -rsp "邮箱密码/授权码: " MAIL_PASS; echo
    read -rp "收件邮箱: " MAIL_TO

    # 拒绝任何控制字符（\n \r \t 以及其他 0x00-0x1F）
    # msmtprc 是行式格式，不支持引号转义；含控制字符会破坏配置
    local v
    for v in "$SMTP_HOST" "$SMTP_PORT" "$MAIL_FROM" "$MAIL_PASS" "$MAIL_TO"; do
        if [[ "$v" =~ [[:cntrl:]] ]]; then
            echo -e "${RED}✗ 输入不能包含控制字符（换行/Tab/回车等）${NC}"
            return 1
        fi
    done
    # 端口必须是数字
    if ! [[ "$SMTP_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}✗ SMTP 端口必须是纯数字${NC}"; return 1
    fi
    # 邮箱地址简单格式（msmtp 不会做严格检查，但避免明显错误）
    if [[ ! "$MAIL_FROM" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        echo -e "${RED}✗ 发件邮箱格式可疑: $MAIL_FROM${NC}"; return 1
    fi
    if [[ ! "$MAIL_TO" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        echo -e "${RED}✗ 收件邮箱格式可疑: $MAIL_TO${NC}"; return 1
    fi

    # 用 Python 安全写入 .msmtprc，并在 Python 端再做一道控制字符防御
    SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" \
    MAIL_FROM="$MAIL_FROM" MAIL_PASS="$MAIL_PASS" \
    python3 << 'PYEOF' || { echo -e "${RED}✗ msmtprc 写入失败${NC}"; return 1; }
import os, sys, re

def sanitize(name, val):
    # 拒绝任何控制字符，Python 端二次防御
    if re.search(r'[\x00-\x1f\x7f]', val):
        print(f"ERR: {name} 含控制字符", file=sys.stderr)
        sys.exit(1)
    return val

host = sanitize("SMTP_HOST", os.environ["SMTP_HOST"])
port = sanitize("SMTP_PORT", os.environ["SMTP_PORT"])
mail_from = sanitize("MAIL_FROM", os.environ["MAIL_FROM"])
mail_pass = sanitize("MAIL_PASS", os.environ["MAIL_PASS"])

# msmtprc 不支持值带引号；如果密码或字段含空格/# 等，msmtp 解析时会出现非预期行为。
# 实测 msmtp 对 password 字段是按"行尾前所有内容"读取，空格会被保留为密码一部分；
# 但 # 在某些版本会被当成行内注释。这里采取保守策略：明确警告这些字符。
warn_chars = []
if " " in mail_pass: warn_chars.append("空格")
if "#" in mail_pass: warn_chars.append("#")
if "\\" in mail_pass: warn_chars.append("\\")
if warn_chars:
    print(f"WARN: 密码含 {','.join(warn_chars)}，部分 msmtp 版本可能解析异常", file=sys.stderr)

tls_starttls = "off" if port == "465" else "on"

content = f"""defaults
auth           on
tls            on
tls_starttls   {tls_starttls}
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account        alert
host           {host}
port           {port}
from           {mail_from}
user           {mail_from}
password       {mail_pass}

account default : alert
"""

fd = os.open("/root/.msmtprc", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(content)
PYEOF

    cat > "$MONITOR_CONF" << EOF
MAIL_TO=${MAIL_TO}
MAIL_FROM=${MAIL_FROM}
AUTO_RESTART=yes
EOF
    chmod 600 "$MONITOR_CONF"

    echo -e "${YELLOW}发送测试邮件...${NC}"
    TEST_BODY="Xray 监控报警测试
服务器: $(curl -s4 --max-time 5 ip.sb 2>/dev/null || echo unknown)
时间: $(date)"
    if build_mail "Xray Monitor Test" "$TEST_BODY" "$MAIL_FROM" "$MAIL_TO" | msmtp "$MAIL_TO" 2>/dev/null; then
        echo -e "${GREEN}✓ 测试邮件已发送${NC}"
    else
        echo -e "${RED}✗ 发送失败，请检查 SMTP 配置${NC}"
        echo -e "${YELLOW}Gmail 需应用专用密码；QQ 需授权码${NC}"
    fi
}

install_monitor() {
    if [ ! -f "$MONITOR_CONF" ]; then
        echo -e "${RED}请先配置邮件通知（选 a）${NC}"; return
    fi
    source "$MONITOR_CONF"

    cat > "$MONITOR_SCRIPT" << 'MONEOF'
#!/bin/bash
CONFIG_FILE="/usr/local/etc/xray/config.json"
MONITOR_CONF="/root/.xray_monitor.conf"
MONITOR_LOG="/var/log/xray/monitor.log"
ALERT_LOCK="/tmp/.xray_alert_lock"
source "$MONITOR_CONF"
HOSTNAME=$(hostname)
NOW=$(date "+%Y-%m-%d %H:%M:%S")

log() { echo "[$NOW] $1" >> "$MONITOR_LOG"; }

send_alert() {
    local SUBJECT="$1" BODY="$2"
    local LOCK_KEY
    LOCK_KEY=$(printf "%s" "$BODY" | sed -E 's/[0-9]+/N/g' | md5sum | cut -d' ' -f1)
    local LOCK_FILE="${ALERT_LOCK}_${LOCK_KEY}"
    if [ -f "$LOCK_FILE" ]; then
        local AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        [ "$AGE" -lt 1800 ] && return
    fi
    local VPS_IP
    VPS_IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || echo "unknown")
    local FULL="${BODY}

服务器: ${VPS_IP} (${HOSTNAME})
时间: ${NOW}"
    if printf "Subject: [Xray Alert] %s\r\nFrom: %s\r\nTo: %s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s" \
        "$SUBJECT" "$MAIL_FROM" "$MAIL_TO" "$FULL" | msmtp "$MAIL_TO" 2>/dev/null; then
        touch "$LOCK_FILE"
        log "ALERT SENT: $SUBJECT"
    else
        log "ALERT FAILED: $SUBJECT"
    fi
}

ERRORS=0; DETAILS=""

if ! systemctl is-active --quiet xray; then
    ERRORS=$((ERRORS+1))
    DETAILS="${DETAILS}
[故障] Xray 进程已停止"
    log "ERROR: Xray not running"
    if [ "$AUTO_RESTART" = "yes" ]; then
        systemctl restart xray; sleep 3
        if systemctl is-active --quiet xray; then
            DETAILS="${DETAILS}
[恢复] 已自动重启"
        else
            DETAILS="${DETAILS}
[失败] 自动重启失败"
        fi
    fi
fi

if [ -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$CONFIG_FILE" python3 << 'PYEOF'
import json, socket, os
with open(os.environ["CONFIG_FILE"]) as f:
    config = json.load(f)
fails = []
for ob in config.get("outbounds",[]):
    if ob.get("protocol") == "socks":
        for s in ob.get("settings",{}).get("servers",[]):
            try:
                sock = socket.create_connection((s["address"], s["port"]), timeout=10)
                sock.close()
            except Exception as e:
                fails.append(f"{s['address']}:{s['port']} [{ob.get('tag','?')}] - {e}")
ff = "/tmp/.xray_node_failures"
if fails:
    with open(ff,"w") as f:
        for x in fails: f.write(x+"\n")
elif os.path.exists(ff):
    os.remove(ff)
PYEOF
    if [ -f /tmp/.xray_node_failures ]; then
        ERRORS=$((ERRORS+1))
        NF=$(cat /tmp/.xray_node_failures)
        DETAILS="${DETAILS}
[故障] 落地节点不通:
${NF}"
    fi
fi

MEM=$(free | awk '/Mem:/ {if ($2>0) printf "%.0f", $3/$2*100; else print 0}')
[ "$MEM" -gt 90 ] && { ERRORS=$((ERRORS+1)); DETAILS="${DETAILS}
[警告] 内存使用率 ${MEM}%"; }
DISK=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
[ "$DISK" -gt 90 ] && { ERRORS=$((ERRORS+1)); DETAILS="${DETAILS}
[警告] 磁盘使用率 ${DISK}%"; }

if [ -f "$CONFIG_FILE" ]; then
    PORTS=$(CONFIG_FILE="$CONFIG_FILE" python3 -c "
import json,os
cfg=json.load(open(os.environ['CONFIG_FILE']))
for inb in cfg.get('inbounds',[]):
    if inb.get('tag') == 'api-in': continue
    print(inb.get('port',''))" 2>/dev/null)
    for P in $PORTS; do
        if ! ss -tlnp | grep -q ":${P} "; then
            ERRORS=$((ERRORS+1)); DETAILS="${DETAILS}
[故障] 端口 ${P} 未监听"
        fi
    done
fi

[ $ERRORS -gt 0 ] && send_alert "发现 ${ERRORS} 个问题" "$DETAILS"
[ $ERRORS -eq 0 ] && log "OK"

if [ -f "$MONITOR_LOG" ]; then
    LS=$(stat -c %s "$MONITOR_LOG" 2>/dev/null || echo 0)
    [ "$LS" -gt 10485760 ] && { tail -n 5000 "$MONITOR_LOG" > "${MONITOR_LOG}.tmp"; mv "${MONITOR_LOG}.tmp" "$MONITOR_LOG"; }
fi
MONEOF

    chmod 700 "$MONITOR_SCRIPT"

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
    echo -e "${GREEN}✓ 监控已启动（每分钟），日志: ${MONITOR_LOG}${NC}"
}

stop_monitor() {
    systemctl stop xray-monitor.timer 2>/dev/null || true
    systemctl disable xray-monitor.timer 2>/dev/null || true
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
    if systemctl is-active --quiet xray-monitor.timer 2>/dev/null; then
        echo -e "  当前状态: ${GREEN}运行中${NC}"
    else
        echo -e "  当前状态: ${RED}未启动${NC}"
    fi
    echo "  a) 配置邮件通知"
    echo "  b) 启动监控"
    echo "  c) 停止监控"
    echo "  d) 查看监控日志"
    echo "  e) 发送测试邮件"
    echo "  f) 返回主菜单"
    read -rp "  选择: " MC
    case $MC in
        a) setup_mail;;
        b) install_monitor;;
        c) stop_monitor;;
        d) show_monitor_log;;
        e)
            if [ -f "$MONITOR_CONF" ]; then
                source "$MONITOR_CONF"
                VPS_IP=$(get_ip)
                TB="测试邮件
服务器: ${VPS_IP}
时间: $(date)"
                if build_mail "Xray Monitor Test" "$TB" "$MAIL_FROM" "$MAIL_TO" | msmtp "$MAIL_TO" 2>/dev/null; then
                    echo -e "${GREEN}✓ 测试邮件已发送${NC}"
                else
                    echo -e "${RED}✗ 发送失败${NC}"
                fi
            else
                echo -e "${RED}请先配置邮件（选 a）${NC}"
            fi
            ;;
        f) return;;
    esac
}

# ========== 主菜单 ==========
main_menu() {
    print_banner
    echo "  1) 全新安装 (首次部署)"
    echo "  2) 添加节点 (住宅 SOCKS5)"
    echo "  3) 删除节点"
    echo "  4) 修改端口"
    echo "  5) 查看状态"
    echo "  6) 流量统计"
    echo "  7) 排错诊断"
    echo "  8) 更新 Xray"
    echo "  9) 重启 Xray"
    echo "  10) 监控报警"
    echo "  11) 卸载"
    echo "  12) 添加 VPS 直连节点"
    echo "  13) 批量添加住宅 SOCKS5 节点"
    echo "  0) 退出"
    echo ""
    read -rp "请选择 [0-13]: " CHOICE

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
        2)  add_node;;
        3)  delete_node;;
        4)  change_port;;
        5)  show_status;;
        6)  show_traffic;;
        7)  troubleshoot;;
        8)  update_xray;;
        9)  systemctl restart xray; echo -e "${GREEN}已重启${NC}"; systemctl status xray --no-pager;;
        10) monitor_menu;;
        11) uninstall;;
        12) add_direct_node;;
        13) add_batch_nodes;;
        0)  exit 0;;
        *)  echo -e "${RED}无效选项${NC}";;
    esac
    echo ""
    read -rp "按回车键返回主菜单..." _
}

# ========== 启动前预检 ==========
preflight_check() {
    # root 检查
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}✗ 此脚本必须以 root 运行${NC}"
        exit 1
    fi

    # systemd 检查
    if ! command -v systemctl &>/dev/null; then
        echo -e "${RED}✗ 未检测到 systemctl，本脚本仅支持 systemd 系统${NC}"
        exit 1
    fi

    # 依赖工具检查
    local missing=()
    for cmd in python3 curl ss; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠ 缺少: ${missing[*]} ，尝试自动安装...${NC}"
        if command -v apt &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt update -y >/dev/null 2>&1 || true
            apt install -y python3 curl iproute2 qrencode >/dev/null 2>&1 || true
        elif command -v dnf &>/dev/null; then
            dnf install -y python3 curl iproute qrencode >/dev/null 2>&1 || true
        elif command -v yum &>/dev/null; then
            yum install -y python3 curl iproute qrencode >/dev/null 2>&1 || true
        fi
        for cmd in python3 curl ss; do
            if ! command -v "$cmd" &>/dev/null; then
                echo -e "${RED}✗ 无法安装 $cmd${NC}"; exit 1
            fi
        done
        echo -e "${GREEN}✓ 依赖已就绪${NC}"
    fi

    # cron 不是硬依赖（仅菜单 6/10 需要），只提示不阻塞；真正用到时由 ensure_cron_installed 再装
    if ! command -v crontab &>/dev/null; then
        echo -e "${YELLOW}ℹ 未安装 cron，使用流量统计/监控报警时会自动安装${NC}"
    fi

    # 443 端口占用检查（提示性，不阻塞）
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        local who
        who=$(ss -tlnp 2>/dev/null | grep ":443 " | grep -oP 'users:\(\(\K[^)]+' | head -1)
        if [ -n "$who" ] && ! echo "$who" | grep -qi "xray"; then
            echo -e "${YELLOW}⚠ 检测到 443 端口被非 xray 进程占用: ${who}${NC}"
            echo -e "${YELLOW}  如继续部署，第一个节点将无法监听 443${NC}"
            read -rp "  按回车继续，或 Ctrl+C 退出..." _
        fi
    fi

    # 信息性：架构 / 发行版
    if [ -f /etc/os-release ]; then
        local osname
        osname=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")
        echo -e "${CYAN}ℹ 系统: ${osname} ($(uname -m))${NC}"
    fi
}

preflight_check
while true; do
    main_menu
done
