#!/bin/bash
# 验证 nftables 回收端口能按 JSON handle 删除，并优先只删除脚本管理的 comment 规则。
set -euo pipefail

cd "$(dirname "$0")"

GREEN=""
YELLOW=""
RED=""
CYAN=""
NC=""
NFT_MANAGED_COMMENT="xray-relay-managed"

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

NFT_RULESET='table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
    }
}'

NFT_DELETES_FILE="$(mktemp /tmp/.test-nft-deletes.XXXXXX)"
trap 'rm -f "$NFT_DELETES_FILE"' EXIT

nft() {
    case "$*" in
        "list ruleset")
            printf '%s\n' "$NFT_RULESET"
            ;;
        -j\ -a\ list\ chain*)
            printf '%s\n' "$NFT_CHAIN_JSON"
            ;;
        delete\ rule*)
            local prev="" arg
            for arg in "$@"; do
                if [ "$prev" = "handle" ]; then
                    printf '%s\n' "$arg" >> "$NFT_DELETES_FILE"
                    return 0
                fi
                prev="$arg"
            done
            echo "delete without handle: $*" >&2
            return 1
            ;;
        -c\ -f*)
            ;;
        *)
            echo "unexpected nft call: $*" >&2
            return 1
            ;;
    esac
}

run_revoke_case() {
    local name="$1" json="$2" expected="$3" mode="${4:-}"
    NFT_CHAIN_JSON="$json"
    PERSIST_CALLED=0
    : > "$NFT_DELETES_FILE"

    local rc=0 out_file got
    out_file=$(mktemp /tmp/.test-nft-revoke.XXXXXX)
    if [ -n "$mode" ]; then
        revoke_firewall_port 8444 "$mode" >"$out_file" 2>&1 || rc=$?
    else
        revoke_firewall_port 8444 >"$out_file" 2>&1 || rc=$?
    fi
    got=$(paste -sd, "$NFT_DELETES_FILE")

    if [ "$rc" -ne 0 ]; then
        echo "  ✗ $name rc=$rc，期望 0"
        sed 's/^/    /' "$out_file"
        rm -f "$out_file"
        exit 1
    fi
    if [ "$got" != "$expected" ]; then
        echo "  ✗ $name 删除 handles='$got'，期望 '$expected'"
        sed 's/^/    /' "$out_file"
        rm -f "$out_file"
        exit 1
    fi
    rm -f "$out_file"
    echo "  ✓ $name"
}

MANAGED_JSON='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":110,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":8444}},{"accept":null},{"comment":"xray-relay-managed"}]}}]}'
LEGACY_JSON='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":111,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":8444}},{"accept":null}]}}]}'
BOTH_JSON='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":120,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":8444}},{"accept":null},{"comment":"xray-relay-managed"}]}},{"rule":{"family":"inet","table":"filter","chain":"input","handle":121,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":8444}},{"accept":null}]}}]}'
SET_JSON='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":130,"expr":[{"match":{"op":"in","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[8444,8500]}}},{"accept":null},{"comment":"xray-relay-managed"}]}}]}'

run_revoke_case "managed comment 规则按 handle 删除" "$MANAGED_JSON" "110"
run_revoke_case "legacy 精确规则可兼容清理" "$LEGACY_JSON" "111"
run_revoke_case "managed 与 legacy 同端口时只删 managed" "$BOTH_JSON" "120"
run_revoke_case "managed-only 模式不删 legacy 规则" "$LEGACY_JSON" "" "managed-only"
run_revoke_case "端口集合规则不被回收误删" "$SET_JSON" ""

echo ""
echo "全部测试通过 ✓"
