#!/bin/bash
# 测试 validate_and_install_config 在各种失败场景下都能保留原配置
set -e

# 准备隔离的测试环境
TESTDIR=$(mktemp -d)
trap "rm -rf $TESTDIR" EXIT

CONFIG_FILE="$TESTDIR/config.json"
CONFIG_BACKUP_KEEP=3

# 写一个有效的"原配置"
cat > "$CONFIG_FILE" << 'EOF'
{"inbounds":[],"outbounds":[],"original":true}
EOF

# 把 validate_and_install_config 函数从主脚本里抽出来（用 source 但屏蔽掉非函数部分）
# 简化：直接重新定义同样逻辑测试
validate_and_install_config() {
    local new_config="$1"
    if [ ! -s "$new_config" ]; then
        echo "✗ 新配置文件为空"; rm -f "$new_config"; return 1
    fi
    if ! python3 -c "import json,sys; json.load(open('$new_config'))" 2>/dev/null; then
        echo "✗ 新配置不是合法 JSON"; rm -f "$new_config"; return 1
    fi
    # 跳过 xray -test (没装 xray)
    if [ -f "$CONFIG_FILE" ]; then
        local ts backup
        ts=$(date +%Y%m%d-%H%M%S-%N)   # 加纳秒避免连续测试冲突
        backup="${CONFIG_FILE}.bak.${ts}"
        cp -a "$CONFIG_FILE" "$backup"
        chmod 600 "$backup"
        ls -1t "${CONFIG_FILE}.bak."* 2>/dev/null | tail -n +"$((CONFIG_BACKUP_KEEP+1))" | xargs -r rm -f
    fi
    mv "$new_config" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    return 0
}

assert_original_intact() {
    if grep -q '"original":true' "$CONFIG_FILE"; then
        echo "  ✓ 原配置完好"
    else
        echo "  ✗ 原配置被破坏！"; exit 1
    fi
}

assert_replaced() {
    if grep -q '"replaced":true' "$CONFIG_FILE"; then
        echo "  ✓ 已替换为新配置"
    else
        echo "  ✗ 未替换！"; exit 1
    fi
}

echo "test 1: 新配置为空文件 → 应失败，原配置不变"
> "$TESTDIR/new.json"
if validate_and_install_config "$TESTDIR/new.json"; then
    echo "  ✗ 不该成功！"; exit 1
fi
assert_original_intact

echo "test 2: 新配置 JSON 损坏 → 应失败，原配置不变"
echo "{this is not json}" > "$TESTDIR/new.json"
if validate_and_install_config "$TESTDIR/new.json"; then
    echo "  ✗ 不该成功！"; exit 1
fi
assert_original_intact

echo "test 3: 合法新配置 → 成功替换 + 备份"
echo '{"replaced":true}' > "$TESTDIR/new.json"
if ! validate_and_install_config "$TESTDIR/new.json"; then
    echo "  ✗ 应该成功！"; exit 1
fi
assert_replaced
ls "$CONFIG_FILE".bak.* >/dev/null 2>&1 && echo "  ✓ 备份已生成" || { echo "  ✗ 没有备份"; exit 1; }

echo "test 4: 备份保留上限 = $CONFIG_BACKUP_KEEP，连写 5 次只保留最近 3 份"
for i in 1 2 3 4 5; do
    sleep 0.01
    echo "{\"v\":$i}" > "$TESTDIR/new.json"
    validate_and_install_config "$TESTDIR/new.json" >/dev/null
done
COUNT=$(ls -1 "$CONFIG_FILE".bak.* 2>/dev/null | wc -l)
if [ "$COUNT" -le "$CONFIG_BACKUP_KEEP" ]; then
    echo "  ✓ 保留 $COUNT 份（上限 $CONFIG_BACKUP_KEEP）"
else
    echo "  ✗ 保留了 $COUNT 份，超过上限"
    exit 1
fi

echo ""
echo "全部测试通过 ✓"
