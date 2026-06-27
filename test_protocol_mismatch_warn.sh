#!/bin/bash
# 验证协议混用提示：本脚本是 Vision 版，配置里出现 xhttp 线路时应打印警告；
# 纯 vision 配置或配置缺失时静默无输出。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PY="$TMP_DIR/check.py"

# 抽取 check_protocol_mismatch() 里的 python 体，单独运行
awk '
    /check_protocol_mismatch\(\) \{/ {fn=1; next}
    fn && /python3 << '\''PYEOF'\''/ {inside=1; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$PY"

[ -s "$PY" ] || { echo "未能从脚本中抽取 check_protocol_mismatch 的 python 体"; exit 1; }

# 场景 1：含 xhttp 入站 -> 应警告，且点名端口
CONFIG_XHTTP="$TMP_DIR/xhttp.json"
cat > "$CONFIG_XHTTP" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {"tag": "vless-in-1", "port": 8442, "streamSettings": {"network": "tcp"}},
    {"tag": "vless-in-5", "port": 8443, "_remark": "yft-us-la",
     "streamSettings": {"network": "xhttp"}}
  ]
}
JSON
out="$(CONFIG_FILE="$CONFIG_XHTTP" python3 "$PY")"
echo "$out" | grep -q "xhttp" || { echo "FAIL: xhttp 配置未触发警告"; echo "$out"; exit 1; }
echo "$out" | grep -q "8443" || { echo "FAIL: 警告未点名端口 8443"; echo "$out"; exit 1; }

# 场景 2：纯 vision 入站 -> 无输出
CONFIG_VISION="$TMP_DIR/vision.json"
cat > "$CONFIG_VISION" <<'JSON'
{
  "inbounds": [
    {"tag": "api-in", "port": 10085},
    {"tag": "vless-in-1", "port": 8442, "streamSettings": {"network": "tcp"}},
    {"tag": "vless-in-2", "port": 8444, "streamSettings": {"network": "tcp"}}
  ]
}
JSON
out="$(CONFIG_FILE="$CONFIG_VISION" python3 "$PY")"
[ -z "$out" ] || { echo "FAIL: 纯 vision 配置不应有输出"; echo "$out"; exit 1; }

# 场景 3：配置缺失/无法解析 -> 静默退出 0，无输出
out="$(CONFIG_FILE="$TMP_DIR/nope.json" python3 "$PY")"
[ -z "$out" ] || { echo "FAIL: 缺失配置不应有输出"; echo "$out"; exit 1; }

echo "protocol mismatch warn ok"
