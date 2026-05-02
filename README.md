# 🚀 xray-relay

![GitHub repo size](https://img.shields.io/github/repo-size/superchaospc/xray-relay?style=flat-square)
![GitHub last commit](https://img.shields.io/github/last-commit/superchaospc/xray-relay?style=flat-square)
![GitHub License](https://img.shields.io/github/license/superchaospc/xray-relay?style=flat-square)
![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)
![Xray](https://img.shields.io/badge/Core-Xray-2F6FED?style=flat-square)

VPS 上一键部署 **Xray VLESS + REALITY** 的 Bash 脚本。既支持 **VPS 直连线路**，也支持 **VPS 入口 → 住宅 SOCKS5 出口** 的中转线路；支持多节点、固定端口→节点映射、配置自动校验回滚、流量统计、监控报警，以及生成的 VLESS 链接自动渲染终端二维码，方便 Shadowrocket / V2rayN / V2rayNG / Neobox 直接扫码导入。

> ⚠️ **免责声明**：本项目仅供学习研究网络协议与系统运维使用。请用户遵守所在国家/地区的法律法规，自行承担使用后果。作者不对使用本脚本造成的任何直接或间接损失负责。

---

## ✨ 功能特性

- 🔐 **VLESS + REALITY + XTLS-Vision** 满血配置，伪装目标为 `www.microsoft.com`
- 🌉 **中转架构**：VPS 入口 → 前置 SOCKS5（住宅 IP）出口，也支持纯 VPS 直连模式
- 🎯 **固定端口映射**：每个前置节点绑定独立监听端口，客户端可精确选择出口，不做负载均衡
- 🧩 **多节点管理**：菜单化添加、删除节点，修改端口
- 🛟 **安全写配置**：生成临时 JSON → `xray run -test` 校验 → 备份旧配置 → 原子替换 → 启动失败自动回滚
- 🧱 **自动防火墙放行**：依次尝试 `ufw` / `firewalld` / `nftables` / `iptables`，并对云厂商安全组给出提醒
- 🔒 **供应链保护**：默认拒绝未确认的 Xray 官方安装脚本来源，支持固定 commit 与 sha256 校验
- ⚡ **BBR 加速**：自动开启 BBR 拥塞控制并写入内核调优参数
- 📊 **流量统计**：基于 Xray API 的累计上行/下行流量查看
- 🩺 **排错诊断**：一键检查服务状态、端口监听、防火墙规则、前置连通性
- 🚨 **监控报警**：可选配置邮件告警（Gmail/QQ/163 等 SMTP），服务异常自动发信
- 📱 **终端二维码**：节点生成后直接在终端渲染 VLESS 二维码，主流客户端扫码即导入
- 🐧 **多发行版支持**：Debian / Ubuntu / CentOS / AlmaLinux / Rocky / Fedora

---

## 🧰 系统要求

- 🖥️ Linux x86_64 VPS，root 权限
- 📦 以下任一包管理器：`apt` / `dnf` / `yum`
- ⚙️ 内核 ≥ 4.9（支持 BBR，绝大多数现代发行版默认满足）
- 🌐 出站 443 可访问 GitHub（用于首次下载官方 Xray 安装脚本）

脚本会自动检测并安装依赖：`xray-core`、`python3`、`curl`、`iproute2`、`qrencode`（懒加载）、`msmtp`（仅配置邮件时）。

> 注意：脚本默认只安装必要依赖，不会整机 `apt upgrade`。如果确实想顺带升级系统，可用 `XRAY_FULL_UPGRADE=1` 运行。

---

## ⚡ 快速开始

### 推荐方式：下载后运行

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-relay/main/xray_deploy.sh -o /root/xray_deploy.sh
chmod +x /root/xray_deploy.sh
/root/xray_deploy.sh
```

首次选择 `1) 全新安装` 或 `8) 更新 Xray` 时，脚本会要求你明确配置 Xray 官方安装脚本来源。默认值是 `PIN_ME`，这不是错误，而是为了避免生产环境直接执行远端 `main` 分支。

### 生产安全模式

先固定 `XTLS/Xray-install` 的 commit，并可选写入 sha256：

```bash
git ls-remote https://github.com/XTLS/Xray-install.git refs/heads/main

curl -L https://raw.githubusercontent.com/XTLS/Xray-install/<COMMIT>/install-release.sh | sha256sum
```

然后编辑脚本顶部：

```bash
XRAY_INSTALL_REF_DEFAULT="<COMMIT>"
XRAY_INSTALL_SHA256_DEFAULT="<sha256>"
```

### 临时追新模式

如果只是测试，或你接受直接跟随官方安装脚本 `main` 分支：

```bash
XRAY_INSTALL_REF=main /root/xray_deploy.sh
```

也可以一行运行远端脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-relay/main/xray_deploy.sh -o /tmp/xray_deploy.sh \
  && chmod +x /tmp/xray_deploy.sh \
  && XRAY_INSTALL_REF=main /tmp/xray_deploy.sh
```

### 🛠️ 首次部署 VPS 直连

1. 运行脚本，选择 **`1) 全新安装`**
2. 在 SOCKS5 节点录入阶段输入 `done`
3. 按提示输入 `y` 创建 443 端口的 VPS 直连节点
4. 脚本自动完成：依赖检查 → Xray 检查/安装 → 密钥生成 → 配置校验下发 → BBR → 防火墙 → 服务启动
5. 部署完成后会输出 VLESS 链接和二维码

### 🛠️ 首次部署住宅 SOCKS5 中转

1. 运行脚本，选择 **`1) 全新安装`**
2. 按提示输入 SOCKS5 前置节点，推荐格式：
   - `socks5://user:pass@host:port`
   - 如果用户名或密码有特殊字符，请按 URL 编码，例如 `:` 写成 `%3A`，`@` 写成 `%40`
3. 也兼容旧格式：`IP:端口:用户名:密码`
   - 例如：`161.77.77.5:12324:user01:pass01`
   - 旧格式中密码不能包含 `:`
   - 按 `done` 或直接回车结束录入
4. 脚本会为每个节点分配独立入口端口，客户端连接不同端口即可选择不同出口

### 📲 导入客户端

脚本在每个节点生成完毕后会自动打印二维码。扫码方式：

- 🍎 **Shadowrocket (iOS)** — 首页右上角扫一扫
- 🪟 **V2rayN (Windows)** — `Ctrl+Shift+Alt+S` 从屏幕扫码，或从剪贴板导入
- 🤖 **V2rayNG (Android)** — 加号 → 扫描二维码（对着另一台屏幕）
- 📦 **Neobox (Android)** — 导入配置 → 扫描屏幕二维码

> 💡 扫码成功率与终端背景相关。白底或纯色主题最佳，避免透明/渐变背景。

---

## 🧭 菜单功能

| 选项 | 功能 |
| --- | --- |
| 1 | 全新安装（首次部署完整流程） |
| 2 | 添加住宅 SOCKS5 节点 |
| 3 | 删除节点 |
| 4 | 修改节点监听端口 |
| 5 | 查看状态（Xray 运行状态 / BBR / 节点信息） |
| 6 | 流量统计（基于 Xray API） |
| 7 | 排错诊断 |
| 8 | 更新 Xray 到最新版 |
| 9 | 重启 Xray |
| 10 | 监控报警（邮件通知配置） |
| 11 | 卸载 |
| 12 | 添加 VPS 直连节点（不经住宅 IP） |

---

## 🏗️ 架构说明

```
                       ┌────────────────────────────────┐
                       │   VPS (Xray VLESS+REALITY)     │
客户端                   │                                │
Shadowrocket    ──────▶│  入口端口 A ──▶ SOCKS5 节点 1   │──▶ 住宅 IP 1
V2rayN / NG            │  入口端口 B ──▶ SOCKS5 节点 2   │──▶ 住宅 IP 2
                       │  入口端口 C ──▶ VPS 直连出口    │──▶ 机房 IP
                       └────────────────────────────────┘
```

- 每个入口端口对应一个出口（一对一固定映射），客户端通过连接不同端口选择出口节点
- 前端 VLESS+REALITY 保证中转链路不被 GFW 识别
- 后端 SOCKS5 可接入任意住宅 IP 提供商（支持带账号密码认证）

---

## 📁 配置文件位置

| 文件 | 用途 |
| --- | --- |
| `/usr/local/etc/xray/config.json` | Xray 主配置 |
| `/root/xray_nodes_info.txt` | 所有节点的 VLESS 链接备份 |
| `/etc/sysctl.d/99-xray.conf` | BBR 与内核调优参数 |
| `/root/.xray_monitor.conf` | 监控告警配置（如启用） |
| `/var/log/xray/` | Xray 运行日志 |

脚本会尽量让 `/usr/local/etc/xray/config.json` 继承现有 owner/group。某些 Xray service 会以 `nobody` 用户运行，如果配置文件被写成 `root:root 600`，服务会因为 `permission denied` 无法启动；当前脚本已针对这种情况处理。

---

## 🧪 测试

仓库内置轻量测试套件：

```bash
bash run_all_tests.sh
```

当前覆盖：

- `bash -n xray_deploy.sh`
- `shellcheck -S error xray_deploy.sh`（未安装则跳过）
- SOCKS5 输入解析，包括 URL 端口非法、IPv6、密码特殊字符
- 配置原子写入与回滚流程
- 节点信息解析
- SMTP 输入校验
- 防火墙返回码捕获链路

在 Debian 13 VPS 上的实测结果：

```text
通过: 6  失败: 0  跳过: 1
```

跳过项为未安装 `shellcheck`。

---

## ❓ 常见问题

**Q: 脚本提示 `Xray 安装脚本来源未配置`，是不是坏了？**

A: 不是。脚本默认 `XRAY_INSTALL_REF_DEFAULT="PIN_ME"`，是为了避免直接执行远端 `main` 分支。生产环境建议固定 `XTLS/Xray-install` 的 commit 和 sha256；临时测试可用：

```bash
XRAY_INSTALL_REF=main /root/xray_deploy.sh
```

**Q: 部署后客户端连不上？**

A: 运行菜单 `7) 排错诊断`，会依次检查 Xray 服务状态、端口监听、防火墙、前置 SOCKS5 连通性。

还需要确认云厂商安全组已放行对应 TCP 端口，例如 443、8443 等。脚本只能修改 VPS 系统内的防火墙，不能自动修改云厂商控制台里的安全组。

**Q: 安装 Xray 时卡在下载？**

A: 脚本依赖 GitHub 下载官方 Xray 安装脚本，国内部分机器可能被墙。解决方案：
- 给 VPS 临时配置 `8.8.8.8` / `1.1.1.1` DNS
- 使用代理：`export https_proxy=http://...` 后再运行脚本
- 或手动下载脚本后本地执行

**Q: SOCKS5 密码里有 `:` 或 `|` 怎么办？**

A: 推荐使用 `socks5://user:pass@host:port` 格式，并对特殊字符做 URL 编码：

- `:` → `%3A`
- `@` → `%40`
- `#` → `%23`

旧格式 `host:port:user:pass` 中，密码不能包含 `:`。

**Q: `xray run -test` 报 `Failed to get format`？**

A: 新版 Xray 对配置文件格式识别更严格，临时配置文件需要 `.json` 后缀。当前脚本已将临时配置统一写成 `/tmp/.xray_config.new.$$.json`。

**Q: 启动失败并提示 `permission denied` 读取 `config.json`？**

A: 这通常是 Xray service 以 `nobody` 等非 root 用户运行，但配置文件是 `root:root 600`。当前脚本会继承现有配置的 owner/group，并保持 `600` 权限，避免泄露配置又保证服务可读。

**Q: 如何升级到新版本脚本？**

A: 重新下载覆盖即可。现有配置（Xray config、节点信息、监控配置）均独立保存，不会丢失。

---

## 🙏 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — 核心代理引擎
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install) — 官方安装脚本

---

## 📄 License

MIT

---

## ⚠️ 免责声明（再次强调）

本工具仅用于学习网络协议、系统运维与安全研究。使用者应对自己的行为负全部责任，并遵守所在国家/地区的相关法律法规。严禁用于任何违反当地法律的用途。作者不对使用本脚本导致的任何后果负责。
