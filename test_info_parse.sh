#!/bin/bash
# 验证 show_status 里的 INFO_FILE 解析能正确取出 (name, link) 对
set -e

TESTDIR=$(mktemp -d)
trap "rm -rf $TESTDIR" EXIT
INFO_FILE="$TESTDIR/info.txt"

# 写一个典型的 INFO_FILE，包含 3 类节点：
# 1. 直连起步（首次安装时写入）
# 2. 住宅 SOCKS5（add_node 追加）
# 3. 直连追加（add_direct_node 追加）
cat > "$INFO_FILE" << 'EOF'
=== LA-CMIN2 ===
端口: 443
出口: VPS 直连 (38.47.118.82)
链接: vless://abc-uuid@38.47.118.82:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=PUBKEY&sid=SID&type=tcp#LA-CMIN2


=== US-Residential ===
端口: 8444
落地: 161.77.77.5:12324
链接: vless://abc-uuid@38.47.118.82:8444?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=PUBKEY&sid=SID&type=tcp#US-Residential


=== JP-Direct ===
端口: 8445
出口: VPS 直连 (38.47.118.82)
链接: vless://abc-uuid@38.47.118.82:8445?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=PUBKEY&sid=SID&type=tcp#JP-Direct

EOF

# 直接复用 show_status 里的解析片段
names=()
links=()
cur_name=""
cur_link=""
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

echo "解析出 ${#names[@]} 个节点："
for i in "${!names[@]}"; do
    echo "  [$((i+1))] ${names[$i]}"
    echo "      ${links[$i]:0:80}..."
done

# 期望：恰好 3 个
if [ "${#names[@]}" -ne 3 ]; then
    echo "✗ 期望 3 个节点，实际 ${#names[@]}"
    exit 1
fi

# 期望顺序：LA-CMIN2 → US-Residential → JP-Direct
if [ "${names[0]}" != "LA-CMIN2" ] || [ "${names[1]}" != "US-Residential" ] || [ "${names[2]}" != "JP-Direct" ]; then
    echo "✗ 节点顺序错误: ${names[*]}"
    exit 1
fi

# 期望链接 # 后的备注与 name 一致
for i in "${!names[@]}"; do
    expected="${names[$i]}"
    link="${links[$i]}"
    fragment="${link##*#}"
    if [ "$fragment" != "$expected" ]; then
        echo "✗ 节点 $i 的链接 fragment ($fragment) 与名称 ($expected) 不符"
        exit 1
    fi
done

echo ""
echo "全部测试通过 ✓"
