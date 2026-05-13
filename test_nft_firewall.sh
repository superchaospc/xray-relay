#!/bin/bash
# 验证 nftables 自动放行不会假设固定的 inet filter input 链
set -e

cd "$(dirname "$0")"

GREEN=""
YELLOW=""
RED=""
CYAN=""
NC=""

eval "$(
    awk '
        /^persist_nftables_rules\(\)/ { capture=1 }
        /^get_next_tag_num\(\)/ { capture=0 }
        capture { print }
    ' xray_deploy.sh
)"

persist_nftables_rules() {
    PERSIST_CALLED=1
    return 0
}

ufw() { return 1; }
firewall-cmd() { return 1; }
iptables() { return 1; }

run_case() {
    local name="$1" ruleset="$2" chain_json="$3" expect_rc="$4" expect_insert="$5"
    NFT_RULESET="$ruleset"
    NFT_CHAIN_JSON="$chain_json"
    NFT_INSERTS=0
    PERSIST_CALLED=0

    local rc=0 out_file
    out_file=$(mktemp /tmp/.test-nft-fw.XXXXXX)
    apply_firewall_port 443 >"$out_file" 2>&1 || rc=$?

    if [ "$rc" -ne "$expect_rc" ]; then
        echo "  ✗ $name rc=$rc，期望 $expect_rc"
        sed 's/^/    /' "$out_file"
        rm -f "$out_file"
        exit 1
    fi

    if [ "$NFT_INSERTS" -ne "$expect_insert" ]; then
        echo "  ✗ $name insert 次数=$NFT_INSERTS，期望 $expect_insert"
        sed 's/^/    /' "$out_file"
        rm -f "$out_file"
        exit 1
    fi

    rm -f "$out_file"
    echo "  ✓ $name"
}

nft() {
    case "$*" in
        "list ruleset")
            printf '%s\n' "$NFT_RULESET"
            ;;
        -j\ -a\ list\ chain*)
            printf '%s\n' "$NFT_CHAIN_JSON"
            ;;
        insert\ rule*)
            NFT_INSERTS=$((NFT_INSERTS + 1))
            ;;
        -c\ -f*)
            ;;
        *)
            echo "unexpected nft call: $*" >&2
            return 1
            ;;
    esac
}

F2B_RULESET='table inet f2b-table {
	set addr-set-sshd {
		type ipv4_addr
	}

	chain f2b-chain {
		type filter hook input priority filter - 1; policy accept;
		tcp dport { 22, 52222 } ip saddr @addr-set-sshd reject with icmp port-unreachable
	}
}'

DROP_RULESET='table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
    }
}'

EMPTY_CHAIN_JSON='{"nftables":[]}'
EXACT_443_JSON='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":5,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":443}},{"accept":null}]}}]}'
SET_443_JSON='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":6,"expr":[{"match":{"op":"in","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[443,8443]}}},{"accept":null}]}}]}'
RANGE_443_JSON='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":7,"expr":[{"match":{"op":"in","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"range":[440,450]}}},{"accept":null}]}}]}'

run_case "fail2ban accept 链无需误报失败" "$F2B_RULESET" "$EMPTY_CHAIN_JSON" 0 0
run_case "drop input 链会 insert 放行规则" "$DROP_RULESET" "$EMPTY_CHAIN_JSON" 0 1
run_case "exact dport 已放行时不重复 insert" "$DROP_RULESET" "$EXACT_443_JSON" 0 0
run_case "set 中含端口时不重复 insert" "$DROP_RULESET" "$SET_443_JSON" 0 0
run_case "端口范围不误判为精确放行" "$DROP_RULESET" "$RANGE_443_JSON" 0 1

NFT_CHAIN_JSON="$EXACT_443_JSON"
[ "$(nft_tcp_dport_accept_handles inet filter input 443 0)" = "5" ]
NFT_CHAIN_JSON="$SET_443_JSON"
if nft_tcp_dport_accept_handles inet filter input 443 0 >/dev/null; then
    echo "  ✗ 回收端口不应删除包含多个端口的 set 规则"
    exit 1
fi
NFT_CHAIN_JSON="$RANGE_443_JSON"
if nft_tcp_dport_accept_handles inet filter input 443 0 >/dev/null; then
    echo "  ✗ 回收端口不应删除端口范围规则"
    exit 1
fi

echo ""
echo "全部测试通过 ✓"
