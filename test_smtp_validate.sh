#!/bin/bash
# 验证 setup_mail 的输入校验能拒绝控制字符 / 非数字端口 / 错误邮箱格式
set -e

# 内联校验函数（与脚本里 setup_mail 中的逻辑一致）
validate_email_addr() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]
}

validate_smtp_inputs() {
    local SMTP_HOST="$1" SMTP_PORT="$2" MAIL_FROM="$3" MAIL_PASS="$4" MAIL_TO="$5"
    local v
    for v in "$SMTP_HOST" "$SMTP_PORT" "$MAIL_FROM" "$MAIL_PASS" "$MAIL_TO"; do
        if [[ "$v" =~ [[:cntrl:]] ]]; then
            echo "REJECT: 控制字符"; return 1
        fi
    done
    if ! [[ "$SMTP_PORT" =~ ^[0-9]+$ ]]; then
        echo "REJECT: 端口非数字"; return 1
    fi
    if ! validate_email_addr "$MAIL_FROM"; then
        echo "REJECT: 发件邮箱"; return 1
    fi
    if ! validate_email_addr "$MAIL_TO"; then
        echo "REJECT: 收件邮箱"; return 1
    fi
    echo "OK"
    return 0
}

run_case() {
    local desc="$1" expect="$2"
    shift 2
    local got
    got=$(validate_smtp_inputs "$@" 2>&1) || true
    local status="ACCEPT"
    [[ "$got" == REJECT* ]] && status="REJECT"
    if [ "$status" = "$expect" ]; then
        echo "  ✓ $desc → $got"
    else
        echo "  ✗ $desc → $got (期望 $expect)"
        exit 1
    fi
}

# 正常输入
run_case "正常 Gmail" "ACCEPT" "smtp.gmail.com" "587" "me@gmail.com" "secret-pass" "you@example.com"
run_case "正常 465" "ACCEPT" "smtp.qq.com" "465" "me@qq.com" "auth-code-here" "you@163.com"

# 端口非数字
run_case "端口非数字" "REJECT" "smtp.gmail.com" "abc" "me@gmail.com" "pwd" "you@example.com"
# 邮箱格式
run_case "发件无 @" "REJECT" "smtp.gmail.com" "587" "no-at-sign" "pwd" "you@example.com"
run_case "收件无 .com" "REJECT" "smtp.gmail.com" "587" "me@gmail.com" "pwd" "you@example"
run_case "收件含命令替换" "REJECT" "smtp.gmail.com" "587" "me@gmail.com" "pwd" 'a$(touch /tmp/pwn).b@example.com'
run_case "收件含反引号" "REJECT" "smtp.gmail.com" "587" "me@gmail.com" "pwd" 'a`touch /tmp/pwn`.b@example.com'
run_case "收件含分号" "REJECT" "smtp.gmail.com" "587" "me@gmail.com" "pwd" 'a;b@example.com'

# 控制字符 - 这些 case 用 $'...' 显式构造
run_case "host 含 \\n" "REJECT" $'smtp\ngmail.com' "587" "me@gmail.com" "pwd" "you@example.com"
run_case "密码含 \\r" "REJECT" "smtp.gmail.com" "587" "me@gmail.com" $'pa\rss' "you@example.com"
run_case "密码含 \\t" "REJECT" "smtp.gmail.com" "587" "me@gmail.com" $'pa\tss' "you@example.com"

# 边界：密码含空格、#（应该接受但 Python 端会 WARN）
run_case "密码含空格 (接受+警告)" "ACCEPT" "smtp.gmail.com" "587" "me@gmail.com" "pa ss" "you@example.com"
run_case "密码含 # (接受+警告)" "ACCEPT" "smtp.gmail.com" "587" "me@gmail.com" "pa#ss" "you@example.com"

echo ""
echo "全部测试通过 ✓"
