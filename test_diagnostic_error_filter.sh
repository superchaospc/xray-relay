#!/bin/bash
# 验证诊断 [8/8] 的错误日志过滤：访问日志成功行（即便目标域名含 error/fail 字样）
# 不应被误报为错误，而真正的失败/错误行必须被保留。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DEFS="$TMP_DIR/xray_defs.sh"
awk '/^preflight_check$/ {exit} {print}' "$ROOT/xray_deploy.sh" > "$DEFS"
# shellcheck disable=SC1090
source "$DEFS"

SAMPLE=$(cat <<'EOF'
2026/06/12 20:10:11 from 117.136.113.29:11297 accepted tcp:errortracking.deepl.com:443 [vless-in-9 -> direct]
2026/06/12 20:10:12 from 1.2.3.4:5555 accepted tcp:failover.example.com:443 [vless-in-1 -> direct]
2026/06/12 20:11:01 [Warning] [12345] proxy/vless/outbound: failed to find available destination > dial tcp 1.1.1.1:443: connect: connection refused
2026/06/12 20:11:30 [Error] app/proxyman/inbound: failed to load config
2026/06/12 20:12:00 from 9.9.9.9:6000 accepted udp:dns.google:53 [vless-in-2 -> direct]
EOF
)

OUT=$(printf '%s\n' "$SAMPLE" | xray_filter_recent_errors)

# 误报行必须被剔除
if printf '%s\n' "$OUT" | grep -q "accepted "; then
    echo "FAIL: 访问日志成功行未被过滤"
    printf '%s\n' "$OUT"
    exit 1
fi
if printf '%s\n' "$OUT" | grep -q "errortracking.deepl.com"; then
    echo "FAIL: 域名含 error 的成功连接被误报为错误"
    exit 1
fi

# 真正的错误行必须保留
if ! printf '%s\n' "$OUT" | grep -q "connection refused"; then
    echo "FAIL: 真实 dial 失败行被丢弃"
    exit 1
fi
if ! printf '%s\n' "$OUT" | grep -q "\[Error\] app/proxyman/inbound"; then
    echo "FAIL: 真实 [Error] 行被丢弃"
    exit 1
fi

EXPECTED_COUNT=2
ACTUAL_COUNT=$(printf '%s\n' "$OUT" | grep -c .)
if [ "$ACTUAL_COUNT" -ne "$EXPECTED_COUNT" ]; then
    echo "FAIL: 期望保留 $EXPECTED_COUNT 行真实错误，实际 $ACTUAL_COUNT 行"
    printf '%s\n' "$OUT"
    exit 1
fi

echo "diagnostic error filter ok"
