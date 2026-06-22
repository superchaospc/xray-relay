#!/bin/bash
# 验证 REALITY 回落滥用防护 (nftables guard)：
#   - build_reality_guard_ruleset 生成的规则文本结构正确、可被 nft -c 校验
#   - reality_guard_business_ports 只取对外 REALITY 端口（排除 api-in / 本地 dest / 127.0.0.1）
#   - reality_guard_blocklist_elements 正确按 v4/v6 拆分黑名单
set -u

cd "$(dirname "$0")"

GREEN=""; YELLOW=""; RED=""; CYAN=""; NC=""
NFT_MANAGED_COMMENT="xray-relay-managed"
NFTABLES_CONF="/tmp/.test-nftables.conf"
XRAY_GUARD_TABLE="xray_guard"
XRAY_GUARD_CONN_MAX="600"
XRAY_GUARD_RATE="50"
XRAY_GUARD_BURST="100"

# 抽取 guard 相关函数定义（从 business_ports 到 setup_firewall 之前）
eval "$(
    awk '
        /^reality_guard_business_ports\(\) \{/ { capture=1 }
        /^setup_firewall\(\) \{/ { capture=0 }
        capture { print }
    ' xray_deploy.sh
)"

FAIL=0
check() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name —— 期望包含: $needle"
        FAIL=1
    fi
}
check_absent() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  ✗ $name —— 不应包含: $needle"
        FAIL=1
    else
        echo "  ✓ $name"
    fi
}

echo "=== build_reality_guard_ruleset（有端口 + v4/v6 黑名单）==="
RULES=$(build_reality_guard_ruleset "443,8443,8452" "1.2.3.4, 5.6.7.8" "2001:db8::1")
check "自带 add table 前缀" "$RULES" "add table inet xray_guard"
check "自带 delete table 前缀（可重复加载）" "$RULES" "delete table inet xray_guard"
check "端口集合格式化正确" "$RULES" "tcp dport { 443, 8443, 8452 }"
check "并发上限规则" "$RULES" "ct count over 600"
check "速率限制规则" "$RULES" "limit rate over 50/second burst 100 packets"
check "IPv4 黑名单 drop" "$RULES" "ip saddr @blocklist4 drop"
check "IPv6 黑名单 drop" "$RULES" "ip6 saddr @blocklist6 drop"
check "v4 黑名单元素写入" "$RULES" "1.2.3.4, 5.6.7.8"
check "v6 黑名单元素写入" "$RULES" "2001:db8::1"
check "覆盖 ipv4 与 ipv6 两族" "$RULES" "meta nfproto ipv6"

echo "=== build_reality_guard_ruleset（无端口，仅黑名单）==="
RULES_NOPORT=$(build_reality_guard_ruleset "" "9.9.9.9" "")
check "仍写入黑名单元素" "$RULES_NOPORT" "9.9.9.9"
check_absent "无端口时不产生 tcp dport 规则" "$RULES_NOPORT" "tcp dport"

echo "=== nft 语法校验（无 nft 则跳过）==="
if command -v nft >/dev/null 2>&1; then
    if printf '%s\n' "$RULES" | nft -c -f - >/dev/null 2>&1; then
        echo "  ✓ nft -c 校验通过"
    else
        echo "  ✗ nft -c 校验失败"
        printf '%s\n' "$RULES" | nft -c -f - 2>&1 | sed 's/^/      /'
        FAIL=1
    fi
else
    echo "  - 跳过（本机无 nft）"
fi

echo "=== reality_guard_business_ports（排除内部 inbound）==="
TMPCFG=$(mktemp /tmp/.test-guard-cfg.XXXXXX)
cat > "$TMPCFG" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085, "listen": "127.0.0.1"},
    {"tag": "reality-dest-local", "port": 9443, "listen": "127.0.0.1"},
    {"tag": "vless-in-1", "port": 443},
    {"tag": "vless-in-2", "port": 8452},
    {"tag": "vless-in-3", "port": 9000, "listen": "127.0.0.1"}
  ]
}
JSON
PORTS=$(reality_guard_business_ports "$TMPCFG")
if [ "$PORTS" = "443,8452" ]; then
    echo "  ✓ 只取对外业务端口并排序: $PORTS"
else
    echo "  ✗ 端口枚举错误: 期望 443,8452 实得 '$PORTS'"
    FAIL=1
fi
rm -f "$TMPCFG"

echo "=== reality_guard_blocklist_elements（v4/v6 拆分 + 去重）==="
TMPBL=$(mktemp /tmp/.test-guard-bl.XXXXXX)
printf '%s\n' "# comment" "1.1.1.1" "2606:4700::1" "1.1.1.1" "" > "$TMPBL"
ELEMS=$(XRAY_GUARD_BLOCK_IPS="8.8.8.8" reality_guard_blocklist_elements "$TMPBL" "8.8.8.8")
B4=$(printf '%s\n' "$ELEMS" | sed -n '1p')
B6=$(printf '%s\n' "$ELEMS" | sed -n '2p')
check "v4 行含文件内 IP" "$B4" "1.1.1.1"
check "v4 行含 env 追加 IP" "$B4" "8.8.8.8"
check "v6 行含 IPv6" "$B6" "2606:4700::1"
case ",$B4," in
    *"1.1.1.1"*"1.1.1.1"*) echo "  ✗ 未对重复 IP 去重"; FAIL=1 ;;
    *) echo "  ✓ 重复 IP 已去重" ;;
esac
rm -f "$TMPBL"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "全部测试通过 ✓"
else
    echo "存在失败用例 ✗"
    exit 1
fi
