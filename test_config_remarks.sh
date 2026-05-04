#!/bin/bash
# 备注名应写入 config.json，INFO_FILE 丢失后仍能恢复。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if ! grep -Fq '"_remark": name' "$ROOT/xray_deploy.sh"; then
    echo "全新安装生成配置时没有写入 _remark"
    exit 1
fi

if ! grep -Fq '"_remark": node_name' "$ROOT/xray_deploy.sh"; then
    echo "增量添加节点时没有写入 _remark"
    exit 1
fi

if ! grep -Fq 'name = inb.get("_remark")' "$ROOT/xray_deploy.sh"; then
    echo "刷新 INFO_FILE 时没有从 _remark 恢复备注"
    exit 1
fi

echo "config remarks ok"
