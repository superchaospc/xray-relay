#!/bin/bash
# 验证 INFO_FILE 里的链接会生成标准 base64 订阅内容。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INFO_FILE="$TMP_DIR/xray_nodes_info.txt"
SUB_FILE="$TMP_DIR/xray_subscription.txt"
SUB_PY="$TMP_DIR/subscription.py"

awk '
    /refresh_subscription_file_from_info\(\) \{/ {fn=1; next}
    fn && /python3 << '\''PYEOF'\''/ {inside=1; next}
    inside && /^PYEOF$/ {exit}
    inside {print}
' "$ROOT/xray_deploy.sh" > "$SUB_PY"

cat > "$INFO_FILE" <<'EOF'
=== 192.204.3.26 ===
端口: 8443
落地: 192.204.3.26:12324
链接: vless://uuid@example.com:8443?encryption=none&type=tcp#192.204.3.26

=== 192.204.0.126 ===
端口: 8444
落地: 192.204.0.126:12324
链接: vless://uuid@example.com:8444?encryption=none&type=tcp#192.204.0.126
EOF

INFO_FILE="$INFO_FILE" SUB_FILE="$SUB_FILE" python3 "$SUB_PY"

decoded="$(python3 - "$SUB_FILE" <<'PY'
import base64
import sys
print(base64.b64decode(open(sys.argv[1], "rb").read()).decode("utf-8"), end="")
PY
)"
expected=$'vless://uuid@example.com:8443?encryption=none&type=tcp#192.204.3.26\nvless://uuid@example.com:8444?encryption=none&type=tcp#192.204.0.126'

if [ "$decoded" != "$expected" ]; then
    echo "订阅内容不匹配"
    echo "got:"
    printf '%s\n' "$decoded"
    exit 1
fi

if [ "$(stat -f '%Lp' "$SUB_FILE" 2>/dev/null || stat -c '%a' "$SUB_FILE")" != "600" ]; then
    echo "订阅文件权限不是 600"
    exit 1
fi

: > "$INFO_FILE"
INFO_FILE="$INFO_FILE" SUB_FILE="$SUB_FILE" python3 "$SUB_PY"
decoded="$(python3 - "$SUB_FILE" <<'PY'
import base64
import sys
print(base64.b64decode(open(sys.argv[1], "rb").read()).decode("utf-8"), end="")
PY
)"
if [ -n "$decoded" ]; then
    echo "空 INFO_FILE 应生成空订阅"
    exit 1
fi

echo "subscription file ok"
