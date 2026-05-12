#!/bin/bash
# 备注名应写入 config.json，INFO_FILE 丢失后仍能从 _remark 恢复。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG_FILE="$TMP_DIR/config.json"
INFO_FILE="$TMP_DIR/xray_nodes_info.txt"
REFRESH_PY="$TMP_DIR/refresh_info.py"
FORMAT_HELPER="$TMP_DIR/format_vless_host.py"

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
      "_remark": "US-Residential",
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

CONFIG_FILE="$CONFIG_FILE" \
INFO_FILE="$INFO_FILE" \
VPS_IP="38.47.118.82" \
UUID="abc-uuid" \
PUBLIC_KEY="PUBKEY" \
SHORT_ID="SID" \
CLIENT_FP="chrome" \
REALITY_SERVER_NAME="www.cloudflare.com" \
FORMAT_VLESS_HOST_PY="$(cat "$FORMAT_HELPER")" \
python3 "$REFRESH_PY"

grep -Fq "=== LA-Direct ===" "$INFO_FILE"
grep -Fq "=== US-Residential ===" "$INFO_FILE"
grep -Fq "链接: vless://abc-uuid@38.47.118.82:443" "$INFO_FILE"
grep -Fq "#LA-Direct" "$INFO_FILE"
grep -Fq "落地: 161.77.77.5:12324" "$INFO_FILE"
grep -Fq "#US-Residential" "$INFO_FILE"

echo "config remarks ok"
