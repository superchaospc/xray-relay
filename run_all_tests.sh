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
run "test_prompt_read_eof.sh (交互 EOF 优雅退出)" bash test_prompt_read_eof.sh
run "test_next_port.sh (入站端口计算)" bash test_next_port.sh
run "test_public_key_and_ports.sh (public key 与业务端口)" bash test_public_key_and_ports.sh
run "test_atomic_config.sh (配置原子写入)" bash test_atomic_config.sh
run "test_info_parse.sh (INFO_FILE 解析)" bash test_info_parse.sh
run "test_subscription_file.sh (订阅文件生成)" bash test_subscription_file.sh
run "test_smtp_validate.sh (SMTP 输入校验)" bash test_smtp_validate.sh
run "test_firewall_capture.sh (防火墙 rc 链路)" bash test_firewall_capture.sh
run "test_nft_firewall.sh (nftables 链识别)" bash test_nft_firewall.sh
run "test_traffic_record.sh (流量统计首次 delta)" bash test_traffic_record.sh
run "test_monitor_alert.sh (监控告警去重)" bash test_monitor_alert.sh
run "test_config_remarks.sh (节点备注持久化)" bash test_config_remarks.sh

echo ""
echo "=== 总结 ==="
echo "  通过: $PASS  失败: $FAIL  跳过: $SKIPPED"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
