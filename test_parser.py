#!/usr/bin/env python3
"""验证脚本里嵌入的 socks5 输入解析逻辑覆盖到的边界情况。"""
import os, sys, re, subprocess

# 把脚本里嵌入的解析逻辑提取出来单独测试
PARSER = r'''
import os, sys, re
from urllib.parse import urlsplit, unquote
raw = os.environ["INPUT"].strip()
def fail(m): print("ERR\t"+m); sys.exit(0)
def ok(h,p,u,w):
    try: p=int(p)
    except: fail("端口非数字")
    if not(1<=p<=65535): fail("端口范围 1-65535")
    if not h: fail("host 为空")
    if not u: fail("用户名为空")
    if not w: fail("密码为空")
    for f in (h,str(p),u,w):
        if re.search(r"[\x00-\x1f\x7f]", f):
            fail("字段含控制字符（换行/Tab/回车等）")
    print("OK\t"+"\x1f".join([h,str(p),u,w])); sys.exit(0)
if raw.startswith(("socks5://","socks://")):
    try:
        u=urlsplit(raw); h=u.hostname; po=u.port; un=u.username; pw=u.password
    except Exception as e:
        fail(f"URL 解析失败: {e}")
    if not h or not po: fail("URL 缺少 host/port")
    ok(h,po,unquote(un or ""),unquote(pw or ""))
m=re.match(r"^\[([0-9a-fA-F:]+)\]:(\d+):([^:]+):(.+)$", raw)
if m: ok(m.group(1),m.group(2),m.group(3),m.group(4))
parts=raw.split(":")
if len(parts)!=4: fail(f"格式错误：常见格式需 3 个冒号 (实际 {len(parts)-1});密码含特殊字符请用 socks5:// URL")
ok(*parts)
'''

def run(input_str):
    env = os.environ.copy()
    env["INPUT"] = input_str
    r = subprocess.run([sys.executable, "-c", PARSER], capture_output=True, text=True, env=env)
    return r.stdout.strip()

cases = [
    # 常见格式正常
    ("161.77.77.5:12324:14a0f0ecfa3d6:384cafa39d", "OK"),
    # 常见格式密码含 : -> 应该报错让用户改 URL
    ("1.2.3.4:1080:user:pass:with:colon", "ERR"),
    # URL 格式密码含 :@/ 都 OK（要先 URL 编码）
    ("socks5://user:pa%3Ass%40word@1.2.3.4:1080", "OK"),
    # URL 格式无密码
    ("socks5://user@1.2.3.4:1080", "ERR"),
    # IPv6
    ("[2001:db8::1]:1080:user:secret", "OK"),
    # IPv6 + URL
    ("socks5://user:pass@[2001:db8::1]:1080", "OK"),
    # 端口超范围
    ("1.2.3.4:99999:u:p", "ERR"),
    # 端口 0
    ("1.2.3.4:0:u:p", "ERR"),
    # 端口非数字
    ("1.2.3.4:abc:u:p", "ERR"),
    # 空字段
    ("1.2.3.4:1080::p", "ERR"),
    ("1.2.3.4:1080:u:", "ERR"),
    # 完全乱
    ("garbage", "ERR"),
    # ===== reviewer 提到的边界：URL 端口非法 =====
    # u.port getter 在端口非数字时抛 ValueError，不能让脚本退出
    ("socks5://u:p@host:abc", "ERR"),
    # u.port getter 在端口越界时也抛 ValueError
    ("socks5://u:p@host:99999", "ERR"),
    # 端口 0 在 URL 里
    ("socks5://u:p@host:0", "ERR"),
    # percent-encoded 控制字符会在 unquote 后变成真实换行/Tab，必须拒绝，不能让 bash read 截断
    ("socks5://u:pass%0Apass2@host:1080", "ERR"),
    ("socks5://u:pass%09pass2@host:1080", "ERR"),
]

ok = 0; bad = 0
for inp, expected in cases:
    got = run(inp)
    status = "OK" if got.startswith("OK") else "ERR"
    mark = "✓" if status == expected else "✗"
    if status == expected:
        ok += 1
    else:
        bad += 1
    print(f"  {mark} {inp!r:60s} → {status:3s} (expected {expected})")
    if status != expected:
        print(f"    实际输出: {got!r}")

print(f"\n{ok}/{ok+bad} 通过")
sys.exit(0 if bad == 0 else 1)
