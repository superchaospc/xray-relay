#!/bin/bash
# 验证下一个入站端口计算：正常返回可用端口，耗尽时返回非 0。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PY="$TMP_DIR/next_port.py"
CONFIG="$TMP_DIR/config.json"

awk '
    /get_next_inbound_port\(\) \{/ {fn=1; next}
    fn && /python3 << '\''PYEOF'\''/ {inside=1; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$PY"

cat > "$CONFIG" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {"tag": "vless-in-1", "port": 8443},
    {"tag": "vless-in-2", "port": 8444}
  ]
}
JSON

got="$(CONFIG_FILE="$CONFIG" python3 "$PY")"
[ "$got" = "8445" ]

python3 - "$CONFIG" <<'PY'
import json, sys
cfg = {"inbounds": [{"tag": f"vless-in-{p}", "port": p} for p in range(8443, 20001)]}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f)
PY

if CONFIG_FILE="$CONFIG" python3 "$PY" >/tmp/.next_port_out.$$ 2>&1; then
    echo "端口耗尽时仍返回成功"
    cat /tmp/.next_port_out.$$
    rm -f /tmp/.next_port_out.$$
    exit 1
fi
rm -f /tmp/.next_port_out.$$

echo "next port ok"
