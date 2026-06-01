#!/bin/bash
# 验证 show_traffic 历史聚合：按 (tag, port) 双字段匹配，已删除/换端口的旧 (tag, port) 标记为 "(已删除)"。
# 回归：v2.2.14 之前的逻辑只按 tag 聚合，导致同一个 tag 历史上用过两个端口时，两个端口显示同一份数字。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG="$TMP_DIR/config.json"
DB="$TMP_DIR/traffic_db"
SHOW_PY="$TMP_DIR/show.py"

# 从 show_traffic 里抽出 python heredoc。
# show_traffic 内 XRAY_BIN 行带 4 空格缩进；cron heredoc 里的同名行顶格，靠这个区分。
awk '
    /^    .*XRAY_BIN="\/usr\/local\/bin\/xray"/ {anchor=1; next}
    anchor && /python3 << '\''PYEOF'\''/ {capture=1; anchor=0; next}
    capture && /^PYEOF$/ {exit}
    capture {print}
' "$ROOT/xray_deploy.sh" > "$SHOW_PY"

# 安全网：确认抽出来的 python 至少包含历史聚合那段
grep -q "当前实时" "$SHOW_PY" || {
    echo "FAIL: 抽取 show_traffic python 失败"
    exit 1
}

# 当前配置：vless-in-17 已经从 8458 改到 8459，另有 vless-in-2 / vless-in-3 是干净的
cat > "$CONFIG" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {"tag": "vless-in-2", "port": 8443, "_remark": "LA-Direct"},
    {"tag": "vless-in-3", "port": 8444, "_remark": "US-Residential"},
    {"tag": "vless-in-17", "port": 8459, "_remark": "JP-Residential"}
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "socks5-out-3", "protocol": "socks",
     "settings": {"servers": [{"address": "10.1.1.3", "port": 12324}]}},
    {"tag": "socks5-out-17", "protocol": "socks",
     "settings": {"servers": [{"address": "161.77.92.87", "port": 12324}]}}
  ],
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["vless-in-2"], "outboundTag": "direct"},
      {"type": "field", "inboundTag": ["vless-in-3"], "outboundTag": "socks5-out-3"},
      {"type": "field", "inboundTag": ["vless-in-17"], "outboundTag": "socks5-out-17"}
    ]
  }
}
JSON

# 历史 DB：
#   vless-in-2 / 8443: 两条共 1000+2000 = 3000 上行 / 4000 下行
#   vless-in-17 / 8458 (旧端口): 一条 100 上行 / 200 下行
#   vless-in-17 / 8459 (当前端口): 两条共 500+700 = 1200 上行 / 800+900 = 1700 下行
NOW=$(date +%s)
cat > "$DB" <<EOF
$((NOW-1800))|vless-in-2|8443|0|0|1000|2000
$((NOW-1500))|vless-in-2|8443|0|0|2000|2000
$((NOW-1200))|vless-in-17|8458|0|0|100|200
$((NOW-900))|vless-in-17|8459|0|0|500|800
$((NOW-300))|vless-in-17|8459|0|0|700|900
EOF

# 我们只关心历史聚合那段，而不需要走 xray api stats（当前实时区块）。
# 用一个总是返回 0 的假 xray，避免阻塞。
FAKE_XRAY="$TMP_DIR/xray"
cat > "$FAKE_XRAY" <<'SH'
#!/bin/bash
echo "value: 0"
SH
chmod +x "$FAKE_XRAY"

OUT=$(CONFIG_FILE="$CONFIG" TRAFFIC_DB="$DB" XRAY_BIN="$FAKE_XRAY" python3 "$SHOW_PY")

# 抓「过去1小时」块（标题到下一个 ━━━ 块之前）
HOUR_BLOCK=$(awk '/━━━ 过去1小时 ━━━/{found=1; next} found && /━━━/{exit} found' <<< "$OUT")

echo "=== 过去1小时区块 ==="
echo "$HOUR_BLOCK"
echo "==================="

# 断言 1：8443 行存在
echo "$HOUR_BLOCK" | grep -Fq ":8443" || { echo "FAIL: 8443 行缺失"; exit 1; }

# 断言 2：当前端口行显示节点名称
echo "$HOUR_BLOCK" | grep -F ":8459" | grep -Fq "JP-Residential" || {
    echo "FAIL: :8459 没有显示节点名称 JP-Residential"
    exit 1
}

# 断言 3：8458 显示「(已删除)」（vless-in-17 当前在 8459，不在 8458）
echo "$HOUR_BLOCK" | grep -F ":8458" | grep -Fq "(已删除)" || {
    echo "FAIL: :8458 没有标 (已删除)"
    exit 1
}

# 断言 4：8459 显示当前出口 161.77.92.87
echo "$HOUR_BLOCK" | grep -F ":8459" | grep -Fq "161.77.92.87" || {
    echo "FAIL: :8459 没有显示当前出口"
    exit 1
}

# 断言 5：8458 和 8459 数字不同（v2.2.14 的回归就是它们一模一样）
LINE_8458=$(echo "$HOUR_BLOCK" | grep -F ":8458")
LINE_8459=$(echo "$HOUR_BLOCK" | grep -F ":8459")
if [ "$(echo "$LINE_8458" | awk '{print $(NF-2), $(NF-1), $NF}')" = \
     "$(echo "$LINE_8459" | awk '{print $(NF-2), $(NF-1), $NF}')" ]; then
    echo "FAIL: 8458 和 8459 数字相同（聚合还在按 tag 单字段）"
    echo "  8458: $LINE_8458"
    echo "  8459: $LINE_8459"
    exit 1
fi

# 断言 6：8458 的合计 = 100+200 = 300，8459 的合计 = 1200+1700 = 2900
# 用 B/KB 都行，简单地检查数值就够。300 B 才是 100+200。
echo "$LINE_8458" | grep -Fq "300 B" || {
    echo "FAIL: 8458 合计不是 300 B（实际: $LINE_8458）"
    exit 1
}
echo "$LINE_8459" | grep -Fq "2.8 KB" || {
    echo "FAIL: 8459 合计不是 2.8 KB（实际: $LINE_8459）"
    exit 1
}

# 断言 7：tags 的 (tag, port) 集合包含了两个 vless-in-17 项（旧 8458 + 新 8459）
COUNT_17=$(echo "$HOUR_BLOCK" | grep -E ":(8458|8459)" | wc -l | tr -d ' ')
[ "$COUNT_17" = "2" ] || {
    echo "FAIL: 期望 8458 + 8459 共 2 行，实际 $COUNT_17"
    exit 1
}

echo "traffic show split by (tag,port) ok"
