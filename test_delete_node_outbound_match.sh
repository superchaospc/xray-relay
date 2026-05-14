#!/bin/bash
# 删除节点时 outbound 引用必须精确匹配，避免 socks5-out-1 命中 socks5-out-10。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if ! grep -Fq 'r.get("outboundTag") == out_tag' "$ROOT/xray_deploy.sh"; then
    echo "delete_node 未使用 outboundTag 精确匹配"
    exit 1
fi

python3 << 'PYEOF'
out_tag = "socks5-out-1"
if any(r.get("outboundTag") == out_tag for r in [{"outboundTag": "socks5-out-10"}]):
    raise SystemExit("socks5-out-1 不应匹配 socks5-out-10")
if not any(r.get("outboundTag") == out_tag for r in [{"outboundTag": "socks5-out-1"}]):
    raise SystemExit("socks5-out-1 应精确匹配自身")
PYEOF

echo "delete node outbound match ok"
