#!/bin/bash
# 验证首次启用流量统计时只建立 cumulative 基线，delta 不把历史累计算进去。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RECORDER="$TMP_DIR/record.sh"
CONFIG="$TMP_DIR/config.json"
DB="$TMP_DIR/traffic_db"
XRAY="$TMP_DIR/xray"

awk '
    /cat > "\$CRON_SCRIPT" << '\''CRONEOF'\''/ {inside=1; next}
    inside && /^CRONEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" \
    | sed \
        -e "s|^CONFIG_FILE=\"/usr/local/etc/xray/config.json\"|CONFIG_FILE=\"$CONFIG\"|" \
        -e "s|^TRAFFIC_DB=\"/root/.xray_traffic_db\"|TRAFFIC_DB=\"$DB\"|" \
        -e "s|^XRAY_BIN=\"/usr/local/bin/xray\"|XRAY_BIN=\"$XRAY\"|" \
        -e "s|^LOCK_FILE=\"/root/.xray_traffic_record.lock\"|LOCK_FILE=\"$TMP_DIR/traffic_record.lock\"|" \
    > "$RECORDER"
chmod +x "$RECORDER"

cat > "$CONFIG" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {"tag": "vless-in-1", "port": 443}
  ]
}
JSON

cat > "$XRAY" <<'SH'
#!/bin/bash
case "$*" in
  *uplink*) echo "value: ${XRAY_UP:-1000}" ;;
  *downlink*) echo "value: ${XRAY_DOWN:-2000}" ;;
  *) echo "value: 0" ;;
esac
SH
chmod +x "$XRAY"

PATH="$TMP_DIR:$PATH" XRAY_UP=1000 XRAY_DOWN=2000 "$RECORDER"
first_line="$(tail -n 1 "$DB")"
IFS='|' read -r _ tag port cur_up cur_down delta_up delta_down <<< "$first_line"

[ "$tag" = "vless-in-1" ]
[ "$port" = "443" ]
[ "$cur_up" = "1000" ]
[ "$cur_down" = "2000" ]
[ "$delta_up" = "0" ]
[ "$delta_down" = "0" ]

PATH="$TMP_DIR:$PATH" XRAY_UP=1300 XRAY_DOWN=2800 "$RECORDER"
second_line="$(tail -n 1 "$DB")"
IFS='|' read -r _ tag port cur_up cur_down delta_up delta_down <<< "$second_line"

[ "$tag" = "vless-in-1" ]
[ "$port" = "443" ]
[ "$cur_up" = "1300" ]
[ "$cur_down" = "2800" ]
[ "$delta_up" = "300" ]
[ "$delta_down" = "800" ]

printf '%s|vless-in-1|444|9000|9000|0|0\n' "$(date +%s)" >> "$DB"
PATH="$TMP_DIR:$PATH" XRAY_UP=1600 XRAY_DOWN=3000 "$RECORDER"
third_line="$(tail -n 1 "$DB")"
IFS='|' read -r _ tag port cur_up cur_down delta_up delta_down <<< "$third_line"

[ "$tag" = "vless-in-1" ]
[ "$port" = "443" ]
[ "$cur_up" = "1600" ]
[ "$cur_down" = "3000" ]
[ "$delta_up" = "300" ]
[ "$delta_down" = "200" ]

echo "traffic record first delta ok"
