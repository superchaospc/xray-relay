#!/bin/bash
# 验证 prompt_read 保持旧 read 语义：自动修剪首尾 IFS 空白。
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

out="$(printf '  14  \n' | YELLOW="" NC="" bash -c "source '$HELPER'; prompt_read CHOICE -rp ''; printf '[%s]\n' \"\$CHOICE\"")"
if [ "$out" != "[14]" ]; then
    echo "expected trimmed [14], got $out"
    exit 1
fi

out="$(printf '\t y \t\n' | YELLOW="" NC="" bash -c "source '$HELPER'; prompt_read CONFIRM -rp ''; printf '[%s]\n' \"\$CONFIRM\"")"
if [ "$out" != "[y]" ]; then
    echo "expected trimmed [y], got $out"
    exit 1
fi

echo "prompt read trim ok"
