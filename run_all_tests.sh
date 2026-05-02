#!/bin/bash
# 一键运行所有测试 + 主脚本静态检查
# 用法: bash run_all_tests.sh
set -u

cd "$(dirname "$0")"

PASS=0
FAIL=0
SKIPPED=0

run() {
    local name="$1"
    shift
    if "$@" >/tmp/.test_out.$$ 2>&1; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        sed 's/^/      /' /tmp/.test_out.$$
        FAIL=$((FAIL + 1))
    fi
    rm -f /tmp/.test_out.$$
}

skip() {
    echo "  - $1 (跳过: $2)"
    SKIPPED=$((SKIPPED + 1))
}

echo "=== 静态检查 ==="
run "bash -n xray_deploy.sh" bash -n xray_deploy.sh
if command -v shellcheck >/dev/null 2>&1; then
    run "shellcheck (error 级)" shellcheck -S error xray_deploy.sh
else
    skip "shellcheck" "未安装"
fi

echo ""
echo "=== 单元测试 ==="
run "test_parser.py (SOCKS5 输入解析)" python3 test_parser.py
run "test_atomic_config.sh (配置原子写入)" bash test_atomic_config.sh
run "test_info_parse.sh (INFO_FILE 解析)" bash test_info_parse.sh
run "test_smtp_validate.sh (SMTP 输入校验)" bash test_smtp_validate.sh
run "test_firewall_capture.sh (防火墙 rc 链路)" bash test_firewall_capture.sh

echo ""
echo "=== 总结 ==="
echo "  通过: $PASS  失败: $FAIL  跳过: $SKIPPED"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
