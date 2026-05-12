#!/bin/bash
# 非交互 stdin EOF 时，交互提示应优雅退出 0，避免 set -e 把脚本变成失败。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HELPER="$TMP_DIR/prompt_read.sh"
awk '
    /prompt_read\(\) \{/ {inside=1}
    inside {print}
    inside && /^}/ {exit}
' "$ROOT/xray_deploy.sh" > "$HELPER"

set +e
out="$(YELLOW="" NC="" bash -c "source '$HELPER'; prompt_read ANSWER -rp '请输入: '" </dev/null 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
    echo "EOF 时 prompt_read 应退出 0，实际 rc=$rc"
    printf '%s\n' "$out"
    exit 1
fi

if ! printf '%s\n' "$out" | grep -Fq "输入流已结束，操作取消。"; then
    echo "未看到 EOF 取消提示"
    printf '%s\n' "$out"
    exit 1
fi

echo "prompt read eof ok"
