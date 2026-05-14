#!/bin/bash
# 验证 apply_firewall_port_capture / revoke_firewall_port_capture 状态链路
# 用 mock 的 apply_firewall_port 来制造各种返回码场景
set -e

# 复制脚本里的辅助函数（不依赖真实防火墙）
apply_firewall_port_capture() {
    LAST_FW_RC=0
    apply_firewall_port "$1" || LAST_FW_RC=$?
    return 0
}

format_fw_status() {
    case "${LAST_FW_RC:-0}" in
        0)  echo "GREEN_OK" ;;
        2)  echo "YELLOW_NO_BACKEND" ;;
        3)  echo "RED_FAILED" ;;
        *)  echo "YELLOW_UNKNOWN_${LAST_FW_RC}" ;;
    esac
}

revoke_firewall_port_capture() {
    LAST_FW_REVOKE_RC=0
    revoke_firewall_port "$1" || LAST_FW_REVOKE_RC=$?
    return 0
}

format_fw_revoke_status() {
    case "${LAST_FW_REVOKE_RC:-0}" in
        0)  echo "GREEN_REVOKE_OK" ;;
        2)  echo "YELLOW_REVOKE_NO_BACKEND" ;;
        3)  echo "YELLOW_REVOKE_FAILED" ;;
        *)  echo "YELLOW_REVOKE_UNKNOWN_${LAST_FW_REVOKE_RC}" ;;
    esac
}

run_case() {
    local desc="$1" mock_rc="$2" expect="$3"
    # 重新定义 mock，按需返回不同的 rc
    eval "apply_firewall_port() { return $mock_rc; }"
    apply_firewall_port_capture 12345    # 不应让 set -e 退出
    local got
    got=$(format_fw_status)
    if [ "$got" = "$expect" ]; then
        echo "  ✓ $desc (mock rc=$mock_rc) → $got"
    else
        echo "  ✗ $desc (mock rc=$mock_rc) → $got (期望 $expect)"
        exit 1
    fi
}

run_revoke_case() {
    local desc="$1" mock_rc="$2" expect="$3"
    eval "revoke_firewall_port() { return $mock_rc; }"
    revoke_firewall_port_capture 12345
    local got
    got=$(format_fw_revoke_status)
    if [ "$got" = "$expect" ]; then
        echo "  ✓ $desc (mock rc=$mock_rc) → $got"
    else
        echo "  ✗ $desc (mock rc=$mock_rc) → $got (期望 $expect)"
        exit 1
    fi
}

run_case "成功放行" 0 "GREEN_OK"
run_case "未检测到后端" 2 "YELLOW_NO_BACKEND"
run_case "nft/iptables 失败" 3 "RED_FAILED"
run_case "未知错误码" 1 "YELLOW_UNKNOWN_1"
run_case "意外大值" 99 "YELLOW_UNKNOWN_99"
run_revoke_case "成功回收旧端口" 0 "GREEN_REVOKE_OK"
run_revoke_case "旧端口无防火墙后端" 2 "YELLOW_REVOKE_NO_BACKEND"
run_revoke_case "旧端口回收失败" 3 "YELLOW_REVOKE_FAILED"

# 关键性质：set -e 下脚本不应被 mock_rc != 0 杀掉
echo "  ✓ set -e 下未被 rc!=0 的 apply_firewall_port 杀掉"

echo ""
echo "全部测试通过 ✓"
