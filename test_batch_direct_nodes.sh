#!/bin/bash
# 验证批量 VPS 直连节点会写入 _remark、direct 路由和菜单入口。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG_FILE="$TMP_DIR/config.json"
BATCH_PY="$TMP_DIR/batch_direct.py"

awk '
    /add_batch_direct_nodes\(\) \{/ {fn=1; next}
    fn && /python3 << '\''PYEOF'\''/ {inside=1; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$BATCH_PY"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {"tag": "vless-in-5", "port": 8443, "protocol": "vless"}
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["vless-in-5"], "outboundTag": "direct"}
    ]
  }
}
JSON

SEP=$'\x1f'
BATCH_DIRECT_DATA="6${SEP}8444${SEP}VPS-Direct-1
7${SEP}8445${SEP}VPS-Direct-2"

NEW_CONFIG_FILE="$CONFIG_FILE" \
UUID="abc-uuid" \
PRIVATE_KEY="priv" \
SHORT_ID="sid" \
REALITY_DEST="www.cloudflare.com:443" \
REALITY_SERVER_NAME="www.cloudflare.com" \
BATCH_DIRECT_DATA="$BATCH_DIRECT_DATA" \
python3 "$BATCH_PY"

python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    config = json.load(f)

inbounds = {item.get("tag"): item for item in config.get("inbounds", [])}
assert inbounds["vless-in-6"]["port"] == 8444
assert inbounds["vless-in-6"]["_remark"] == "VPS-Direct-1"
assert inbounds["vless-in-7"]["port"] == 8445
assert inbounds["vless-in-7"]["_remark"] == "VPS-Direct-2"

direct_outbounds = [ob for ob in config.get("outbounds", []) if ob.get("tag") == "direct"]
assert len(direct_outbounds) == 1

routes = {
    tuple(rule.get("inboundTag", [])): rule.get("outboundTag")
    for rule in config.get("routing", {}).get("rules", [])
}
assert routes[("vless-in-6",)] == "direct"
assert routes[("vless-in-7",)] == "direct"
PY

grep -Fq "14) 批量添加 VPS 直连节点" "$ROOT/xray_deploy.sh"
grep -Fq "请选择 [0-14]" "$ROOT/xray_deploy.sh"
grep -Fq "XRAY_PRINT_SUB_DATA_URL=1 print_subscription_info" "$ROOT/xray_deploy.sh"

echo "batch direct nodes ok"
