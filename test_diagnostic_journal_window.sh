#!/bin/bash
# 验证诊断日志只扫描当前 Xray 成功启动后的日志，并在 systemd 时间不可用时回退。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DEFS="$TMP_DIR/xray_defs.sh"
awk '/^preflight_check$/ {exit} {print}' "$ROOT/xray_deploy.sh" > "$DEFS"
# shellcheck disable=SC1090
source "$DEFS"

SYSTEMD_START_VALUE="Sun 2026-06-07 23:20:16 CST"
systemctl() {
    if [ "$1" = "show" ]; then
        printf '%s\n' "$SYSTEMD_START_VALUE"
        return 0
    fi
    return 1
}

actual=$(xray_journal_since)
if [ "$actual" != "$SYSTEMD_START_VALUE" ]; then
    echo "未使用完整的 ExecMainStartTimestamp: $actual"
    exit 1
fi

SYSTEMD_START_VALUE=""
actual=$(xray_journal_since)
if [ "$actual" != "1 hour ago" ]; then
    echo "空启动时间未回退到 1 hour ago: $actual"
    exit 1
fi

SYSTEMD_START_VALUE="n/a"
actual=$(xray_journal_since)
if [ "$actual" != "1 hour ago" ]; then
    echo "n/a 启动时间未回退到 1 hour ago: $actual"
    exit 1
fi

if ! grep -Fq 'journalctl -u xray --since "$JOURNAL_SINCE"' "$ROOT/xray_deploy.sh"; then
    echo "诊断日志查询未安全引用动态时间下界"
    exit 1
fi

echo "diagnostic journal window ok"
