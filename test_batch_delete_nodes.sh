#!/bin/bash
# 验证批量删除节点支持逗号/范围选择，并只移除不再被引用的 outbound。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG_FILE="$TMP_DIR/config.json"
PORTS_FILE="$TMP_DIR/delete_ports.txt"
BATCH_DELETE_PY="$TMP_DIR/batch_delete.py"
BATCH_DELETE_OUT="$TMP_DIR/batch_delete.out"

awk '
    /batch_delete_nodes\(\) \{/ {fn=1; next}
    fn && /NEW_CONFIG_FILE="\$NEW_CONFIG" DELETE_SELECTION="\$DELETE_SELECTION" DELETE_PORTS_FILE="\$DELETE_PORTS_FILE" python3 << '\''PYEOF'\''/ {inside=1; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$BATCH_DELETE_PY"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {"tag": "vless-in-1", "port": 443, "_remark": "LA-Direct"},
    {"tag": "vless-in-2", "port": 8444, "_remark": "JP-Residential"},
    {"tag": "vless-in-3", "port": 8445, "_remark": "US-Residential"},
    {"tag": "vless-in-4", "port": 8446, "_remark": "SG-Residential"}
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"},
    {"tag": "socks5-out-2", "protocol": "socks", "settings": {"servers": [{"address": "161.77.77.5", "port": 12324}]}},
    {"tag": "socks5-out-shared", "protocol": "socks", "settings": {"servers": [{"address": "161.77.88.6", "port": 12324}]}}
  ],
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["vless-in-1"], "outboundTag": "direct"},
      {"type": "field", "inboundTag": ["vless-in-2"], "outboundTag": "socks5-out-2"},
      {"type": "field", "inboundTag": ["vless-in-3", "vless-in-4"], "outboundTag": "socks5-out-shared"}
    ]
  }
}
JSON

NEW_CONFIG_FILE="$CONFIG_FILE" \
DELETE_SELECTION="1,2,3-3" \
DELETE_PORTS_FILE="$PORTS_FILE" \
python3 "$BATCH_DELETE_PY" >"$BATCH_DELETE_OUT"

python3 - "$CONFIG_FILE" "$PORTS_FILE" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
ports = open(sys.argv[2]).read().splitlines()

assert ports == ["443", "8444", "8445"], ports
inbound_tags = [inb["tag"] for inb in config["inbounds"]]
assert inbound_tags == ["api-in", "vless-in-4"], inbound_tags
outbound_tags = [ob["tag"] for ob in config["outbounds"]]
assert "socks5-out-2" not in outbound_tags
assert "socks5-out-shared" in outbound_tags
assert "direct" in outbound_tags
rules = config["routing"]["rules"]
assert rules == [
    {"type": "field", "inboundTag": ["vless-in-4"], "outboundTag": "socks5-out-shared"}
], rules
PY

if NEW_CONFIG_FILE="$CONFIG_FILE" DELETE_SELECTION="2-1" DELETE_PORTS_FILE="$PORTS_FILE" python3 "$BATCH_DELETE_PY" >/dev/null 2>&1; then
    echo "倒序范围不应成功"
    exit 1
fi

grep -Fq "16) 批量删除节点" "$ROOT/xray_deploy.sh"
grep -Fq "请选择 [0-17]" "$ROOT/xray_deploy.sh"

echo "batch delete nodes ok"
