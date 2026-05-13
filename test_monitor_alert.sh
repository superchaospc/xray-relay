#!/bin/bash
# 验证监控告警的去重 key 跟随故障详情，而不是只跟随 "发现 N 个问题" 主题。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MONITOR_SNIPPET="$(awk '
    /cat > "\$MONITOR_SCRIPT" << '\''MONEOF'\''/ {inside=1; next}
    inside && /^MONEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh")"

if ! grep -Fq 'LOCK_KEY=$(printf "%s" "$BODY" | sed -E '\''s/[0-9]+/N/g'\'' | md5sum' <<< "$MONITOR_SNIPPET"; then
    echo "告警 lock key 没有对 BODY/DETAILS 做数字归一化"
    exit 1
fi

if grep -Fq 'LOCK_KEY=$(printf "%s" "$BODY" | md5sum' <<< "$MONITOR_SNIPPET"; then
    echo "告警 lock key 仍使用原始 BODY"
    exit 1
fi

if grep -Fq 'source "$MONITOR_CONF"' <<< "$MONITOR_SNIPPET"; then
    echo "监控脚本仍直接 source 配置文件"
    exit 1
fi

if ! grep -Fq 'load_monitor_conf' <<< "$MONITOR_SNIPPET"; then
    echo "监控脚本未使用受限配置解析"
    exit 1
fi

key_a="$(printf "%s" "[警告] 内存使用率 91%" | sed -E 's/[0-9]+/N/g' | md5sum | cut -d' ' -f1)"
key_b="$(printf "%s" "[警告] 内存使用率 99%" | sed -E 's/[0-9]+/N/g' | md5sum | cut -d' ' -f1)"
key_c="$(printf "%s" "[故障] 端口 8444 未监听" | sed -E 's/[0-9]+/N/g' | md5sum | cut -d' ' -f1)"
[ "$key_a" = "$key_b" ]
[ "$key_a" != "$key_c" ]

if grep -Fq 'VPS_IP=$(curl -s4 ip.sb' <<< "$MONITOR_SNIPPET"; then
    echo "监控脚本仍在每分钟无条件请求 ip.sb"
    exit 1
fi

if ! grep -Fq 'VPS_IP=$(curl -s4 --max-time 5 ip.sb' <<< "$MONITOR_SNIPPET"; then
    echo "告警发送时未获取 VPS IP"
    exit 1
fi

echo "monitor alert lock ok"
