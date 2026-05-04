#!/bin/bash
# 验证监控告警的去重 key 跟随故障详情，而不是只跟随 "发现 N 个问题" 主题。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MONITOR_SNIPPET="$(awk '
    /cat > "\$MONITOR_SCRIPT" << '\''MONEOF'\''/ {inside=1; next}
    inside && /^MONEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh")"

if ! grep -Fq 'LOCK_KEY=$(printf "%s" "$BODY" | md5sum' <<< "$MONITOR_SNIPPET"; then
    echo "告警 lock key 没有使用 BODY/DETAILS"
    exit 1
fi

if grep -Fq 'LOCK_KEY=$(echo "$SUBJECT"' <<< "$MONITOR_SNIPPET"; then
    echo "告警 lock key 仍使用 SUBJECT"
    exit 1
fi

if grep -Fq 'VPS_IP=$(curl -s4 ip.sb' <<< "$MONITOR_SNIPPET"; then
    echo "监控脚本仍在每分钟无条件请求 ip.sb"
    exit 1
fi

if ! grep -Fq 'VPS_IP=$(curl -s4 --max-time 5 ip.sb' <<< "$MONITOR_SNIPPET"; then
    echo "告警发送时未获取 VPS IP"
    exit 1
fi

echo "monitor alert lock ok"
