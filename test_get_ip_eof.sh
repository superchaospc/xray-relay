#!/bin/bash
# get_ip 在公网 IP 自动获取失败且 stdin EOF 时应向调用方返回失败。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HELPER="$TMP_DIR/get_ip.sh"
awk '
    /get_ip\(\) \{/ {inside=1}
    inside {print}
    inside && /^}/ {exit}
' "$ROOT/xray_deploy.sh" > "$HELPER"

cat > "$TMP_DIR/curl" << 'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMP_DIR/curl"

set +e
out="$(
    PATH="$TMP_DIR:$PATH" \
    IP_CACHE_FILE="$TMP_DIR/ip.cache" \
    IP_CACHE_TTL=3600 \
    RED="" YELLOW="" NC="" \
    bash -c "source '$HELPER'; get_ip" </dev/null 2>&1
)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "get_ip EOF 时应返回非零，实际 rc=0"
    printf '%s\n' "$out"
    exit 1
fi

if ! printf '%s\n' "$out" | grep -Fq "无法获取 VPS 公网 IP"; then
    echo "未看到 get_ip EOF 失败提示"
    printf '%s\n' "$out"
    exit 1
fi

echo "get ip eof ok"
