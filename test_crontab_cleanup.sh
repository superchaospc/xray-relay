#!/bin/bash
# 验证卸载清理 cron 时，只有存在 xray_traffic_record 项才重写 crontab。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HELPER="$TMP_DIR/remove_traffic_cron.sh"
awk '
    /remove_traffic_cron\(\) \{/ {inside=1}
    inside {print}
    inside && /^}/ {exit}
' "$ROOT/xray_deploy.sh" > "$HELPER"

CRON_SRC="$TMP_DIR/current"
CRON_DST="$TMP_DIR/written"

crontab() {
    case "${1:-}" in
        -l)
            [ -f "$CRON_SRC" ] || return 1
            cat "$CRON_SRC"
            ;;
        -)
            cat > "$CRON_DST"
            ;;
        *)
            return 1
            ;;
    esac
}

source "$HELPER"

rm -f "$CRON_SRC" "$CRON_DST"
remove_traffic_cron
[ ! -f "$CRON_DST" ] || { echo "无 crontab 时不应写入空 crontab"; exit 1; }

printf '%s\n' '0 1 * * * /root/backup.sh' > "$CRON_SRC"
remove_traffic_cron
[ ! -f "$CRON_DST" ] || { echo "无 xray_traffic_record 时不应重写 crontab"; exit 1; }

cat > "$CRON_SRC" <<'EOF'
0 1 * * * /root/backup.sh
*/5 * * * * /root/.xray_traffic_record.sh # xray_traffic_record
EOF
remove_traffic_cron

if [ ! -f "$CRON_DST" ]; then
    echo "存在 xray_traffic_record 时应重写 crontab"
    exit 1
fi
if grep -q "xray_traffic_record" "$CRON_DST"; then
    echo "xray_traffic_record 未被移除"
    exit 1
fi
grep -q "/root/backup.sh" "$CRON_DST"

echo "crontab cleanup ok"
