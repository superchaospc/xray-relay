#!/bin/bash
# 验证 public key 派生失败会返回非 0，并且诊断端口列表过滤 api-in。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HELPER="$TMP_DIR/derive_public_key.sh"
awk '
    /derive_public_key\(\) \{/ {inside=1}
    inside {print}
    inside && /^}/ {exit}
' "$ROOT/xray_deploy.sh" > "$HELPER"

cat > "$TMP_DIR/xray" <<'SH'
#!/bin/bash
case "$XRAY_FAKE_MODE" in
  ok)
    echo "Private key: PRIV"
    echo "Public key: PUBKEY"
    ;;
  fail)
    exit 1
    ;;
  empty)
    echo "nothing useful here"
    ;;
esac
SH
chmod +x "$TMP_DIR/xray"

PATH="$TMP_DIR:$PATH" RED="" NC="" XRAY_FAKE_MODE=ok bash -c "source '$HELPER'; got=\$(derive_public_key PRIV); [ \"\$got\" = PUBKEY ]"
PATH="$TMP_DIR:$PATH" RED="" NC="" XRAY_FAKE_MODE=fail bash -c "source '$HELPER'; ! derive_public_key PRIV >/dev/null"
PATH="$TMP_DIR:$PATH" RED="" NC="" XRAY_FAKE_MODE=empty bash -c "source '$HELPER'; ! derive_public_key PRIV >/dev/null"

PORT_SNIPPETS="$(awk '
    /PORTS=.*python3 -c "/ {inside=1}
    inside {print}
    inside && /2>\/dev\/null/ {inside=0}
' "$ROOT/xray_deploy.sh")"

count="$(grep -c "if inb.get('tag') == 'api-in': continue" <<< "$PORT_SNIPPETS")"
[ "$count" -ge 2 ]

grep -Fq 'NEW_LINK="vless://${UUID}@${VPS_IP}:${NEW_PORT}' "$ROOT/xray_deploy.sh"
grep -Fq 'type=tcp#${NODE_NAME}"' "$ROOT/xray_deploy.sh"

echo "public key and port filtering ok"
