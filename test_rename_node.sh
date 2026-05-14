#!/bin/bash
# 验证节点名称可写回 _remark，并能覆盖 INFO_FILE 中的旧名称刷新订阅链接。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG_FILE="$TMP_DIR/config.json"
INFO_FILE="$TMP_DIR/xray_nodes_info.txt"
SUB_FILE="$TMP_DIR/xray_subscription.txt"
RENAME_PY="$TMP_DIR/rename_node_update.py"
REFRESH_PY="$TMP_DIR/refresh_info.py"
FORMAT_HELPER="$TMP_DIR/format_vless_host.py"

awk '
    /rename_node\(\) \{/ {fn=1; next}
    fn && /NEW_CONFIG_FILE="\$NEW_CONFIG" IDX="\$IDX" NEW_NAME="\$SAFE_NAME" python3 << '\''PYEOF'\''/ {inside=1; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$RENAME_PY"

awk '
    /refresh_info_file_from_config\(\) \{/ {fn=1; next}
    fn && /python3 << '\''PYEOF'\''/ {count++; if (count == 2) {inside=1}; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$REFRESH_PY"

awk '
    /format_vless_host_py\(\) \{/ {fn=1; next}
    fn && /cat <<'\''PYEOF'\''/ {inside=1; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$FORMAT_HELPER"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {
      "tag": "vless-in-1",
      "port": 443,
      "protocol": "vless",
      "_remark": "LA-Direct",
      "settings": {"clients": [{"id": "ignored"}]},
      "streamSettings": {"realitySettings": {"shortIds": ["sid"]}}
    },
    {
      "tag": "vless-in-2",
      "port": 8444,
      "protocol": "vless",
      "_remark": "Old-Residential",
      "settings": {"clients": [{"id": "ignored"}]},
      "streamSettings": {"realitySettings": {"shortIds": ["sid"]}}
    }
  ],
  "outbounds": [
    {"tag": "socks5-out-2", "protocol": "socks", "settings": {"servers": [{"address": "161.77.77.5", "port": 12324}]}},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["vless-in-1"], "outboundTag": "direct"},
      {"type": "field", "inboundTag": ["vless-in-2"], "outboundTag": "socks5-out-2"}
    ]
  }
}
JSON

cat > "$INFO_FILE" <<'EOF'
=== LA-Direct ===
端口: 443
出口: VPS 直连 (38.47.118.82)
链接: vless://abc-uuid@38.47.118.82:443?encryption=none&type=tcp#LA-Direct

=== Old-Residential ===
端口: 8444
落地: 161.77.77.5:12324
链接: vless://abc-uuid@38.47.118.82:8444?encryption=none&type=tcp#Old-Residential
EOF

NEW_CONFIG_FILE="$CONFIG_FILE" IDX="2" NEW_NAME="JP-Residential-New" python3 "$RENAME_PY"

python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
inbounds = {inb["tag"]: inb for inb in config["inbounds"]}
assert inbounds["vless-in-1"]["_remark"] == "LA-Direct"
assert inbounds["vless-in-2"]["_remark"] == "JP-Residential-New"
PY

if NEW_CONFIG_FILE="$CONFIG_FILE" IDX="9" NEW_NAME="Nope" python3 "$RENAME_PY" >/dev/null 2>&1; then
    echo "无效编号不应成功"
    exit 1
fi

CONFIG_FILE="$CONFIG_FILE" \
INFO_FILE="$INFO_FILE" \
VPS_IP="38.47.118.82" \
UUID="abc-uuid" \
PUBLIC_KEY="PUBKEY" \
SHORT_ID="SID" \
CLIENT_FP="chrome" \
REALITY_SERVER_NAME="www.cloudflare.com" \
FORMAT_VLESS_HOST_PY="$(cat "$FORMAT_HELPER")" \
REFRESH_NAME_PORT="8444" \
REFRESH_NAME="JP-Residential-New" \
python3 "$REFRESH_PY"

grep -Fq "=== JP-Residential-New ===" "$INFO_FILE"
grep -Fq "#JP-Residential-New" "$INFO_FILE"
if grep -Fq "Old-Residential" "$INFO_FILE"; then
    echo "旧节点名称未被覆盖"
    exit 1
fi
grep -Fq "15) 修改节点名称" "$ROOT/xray_deploy.sh"

echo "rename node ok"
