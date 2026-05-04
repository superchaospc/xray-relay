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

- 🔐 **VLESS + REALITY + XTLS-Vision** 满血配置，默认伪装目标为 `www.cloudflare.com`，可用环境变量覆盖
- 🌉 **中转架构**：VPS 入口 → 前置 SOCKS5（住宅 IP）出口，也支持纯 VPS 直连模式
- 🎯 **固定端口映射**：每个前置节点绑定独立监听端口，客户端可精确选择出口，不做负载均衡
- 🧩 **多节点管理**：菜单化添加、删除节点，修改端口
- 🛟 **安全写配置**：生成临时 JSON → `xray run -test` 校验 → 备份旧配置 → 原子替换 → 启动失败自动回滚
- 🧱 **自动防火墙放行**：依次尝试 `ufw` / `firewalld` / `nftables` / `iptables`，并尽量持久化规则，对云厂商安全组给出提醒
- 🔒 **供应链保护**：默认拒绝未确认的 Xray 官方安装脚本来源，支持固定 commit 与 sha256 校验
- ⚡ **BBR 加速**：自动开启 BBR 拥塞控制并写入内核调优参数
- 📊 **流量统计**：基于 Xray API 的累计上行/下行流量查看
- 🩺 **排错诊断**：一键检查服务、配置、端口、防火墙、前置连通性、BBR、系统资源和错误日志
- 🚨 **监控报警**：可选配置邮件告警（Gmail/QQ/163 等 SMTP），每分钟巡检，异常自动发信
- 📱 **终端二维码**：节点生成后直接在终端渲染 VLESS 二维码，主流客户端扫码即导入
- 🐧 **多发行版支持**：Debian / Ubuntu / CentOS / AlmaLinux / Rocky / Fedora

---

## 🆕 v2.1 关键改动

- 配置写入采用「临时文件 → `xray run -test` → 备份 → 原子替换 → 重启失败回滚」流程
- Xray 官方安装脚本默认不再跟随 `main`，必须显式 pin commit 或临时指定 `XRAY_INSTALL_REF=main`
- SOCKS5 支持常见 `host:port:user:pass` 与 URL 格式，并拒绝控制字符注入
- 防火墙规则支持 `ufw` / `firewalld` / `nftables` / `iptables`，nftables 与 iptables 会尝试自动持久化
- 节点备注写入配置元数据 `_remark`，修改端口或重建 `INFO_FILE` 后仍能保留原名称
- systemd drop-in 自动提升 Xray 文件描述符上限到 `65535`
- 默认只安装必要依赖，不做整机 `apt upgrade`；需要时可用 `XRAY_FULL_UPGRADE=1`
- 敏感文件统一 `600` 权限，终端输出可用 `XRAY_REDACT=1` 隐藏 UUID / 密钥中段

---

## 🧰 系统要求

- 🖥️ Linux x86_64 VPS，root 权限
- 📦 以下任一包管理器：`apt` / `dnf` / `yum`
- ⚙️ 内核 ≥ 4.9（支持 BBR，绝大多数现代发行版默认满足）
- 🌐 出站 443 可访问 GitHub（用于首次下载官方 Xray 安装脚本）

脚本会自动检测并安装依赖：`xray-core`、`python3`、`curl`、`iproute2`、`ca-certificates`、`qrencode`、`msmtp`（仅配置邮件时）。

> 注意：脚本默认只安装必要依赖，不会整机 `apt upgrade`。如果确实想顺带升级系统，可用 `XRAY_FULL_UPGRADE=1` 运行。

### 环境变量

常见用法示例：

```bash
CLIENT_FP=ios REALITY_SERVER_NAME=www.apple.com REALITY_DEST=www.apple.com:443 /root/xray_deploy.sh
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `XRAY_INSTALL_REF` | `PIN_ME` | `XTLS/Xray-install` 的 ref，推荐填固定 commit SHA；临时测试可设为 `main` |
| `XRAY_INSTALL_SHA256` | 空 | `install-release.sh` 的 sha256；设置后会强制校验 |
| `XRAY_FULL_UPGRADE` | `0` | 设为 `1` 时才执行整机升级 |
| `XRAY_REDACT` | `0` | 设为 `1` 时隐藏终端输出里的 UUID / 密钥中段 |
| `CLIENT_FP` | `chrome` | 客户端指纹；iOS / Shadowrocket 可考虑 `ios` 或 `safari` |
| `REALITY_SERVER_NAME` | `www.cloudflare.com` | VLESS 链接里的 SNI |
| `REALITY_DEST` | `${REALITY_SERVER_NAME}:443` | Xray REALITY 回源目标 |
| `IP_CACHE_TTL` | `3600` | VPS 公网 IP 缓存秒数，EIP 切换后可临时调小 |

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
4. 输入节点备注名称（回车默认 `VPS-Direct`）
5. 脚本自动完成：依赖检查 → Xray 检查/安装 → 密钥生成 → 配置校验下发 → BBR → 防火墙 → 服务启动
6. 部署完成后会输出 VLESS 链接和二维码

### 🛠️ 首次部署住宅 SOCKS5 中转

1. 运行脚本，选择 **`1) 全新安装`**
2. 按提示输入 SOCKS5 前置节点，常见推荐格式：
   - `IP:端口:用户名:密码`
   - 例如：`161.77.77.5:12324:user01:pass01`
   - 这种格式中密码不能包含 `:`
3. 如果用户名或密码有特殊字符，请使用 URL 格式：
   - `socks5://user:pass@host:port` 或 `socks://user:pass@host:port`
   - 特殊字符请按 URL 编码，例如 `:` 写成 `%3A`，`@` 写成 `%40`
   - 按 `done` 或直接回车结束录入
4. 脚本会为每个节点分配独立入口端口，客户端连接不同端口即可选择不同出口。首次安装时第 1 个节点默认监听 `443`，第 2 个开始为 `8444`、`8445`...；后续菜单添加节点会从 `8443` 起寻找空闲端口。

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
| 0 | 退出 |

---

## 🏗️ 架构说明

```mermaid
flowchart LR
    client["客户端<br/>Shadowrocket<br/>V2rayN / V2rayNG / NekoBox"]

    subgraph vps["VPS · Xray VLESS + REALITY"]
        inA["入口端口 A"] --> socks1["SOCKS5 节点 1"]
        inB["入口端口 B"] --> socks2["SOCKS5 节点 2"]
        inC["入口端口 C"] --> direct["VPS 直连出口"]
    end

    client --> inA
    client --> inB
    client --> inC

    socks1 --> home1["住宅 IP 1"]
    socks2 --> home2["住宅 IP 2"]
    direct --> dc["机房 IP"]
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
| `/root/.xray_vps_ip` | VPS 公网 IP 缓存 |
| `/etc/sysctl.d/99-xray.conf` | BBR 与内核调优参数 |
| `/etc/systemd/system/xray.service.d/limits.conf` | Xray 文件描述符上限配置 |
| `/root/.xray_monitor.conf` | 监控告警配置（如启用） |
| `/root/.xray_monitor.sh` | 监控巡检脚本 |
| `/var/log/xray/` | Xray 运行日志 |

脚本会尽量让 `/usr/local/etc/xray/config.json` 继承现有 owner/group。某些 Xray service 会以 `nobody` 用户运行，如果配置文件被写成 `root:root 600`，服务会因为 `permission denied` 无法启动；当前脚本已针对这种情况处理。

> 说明：脚本会在 Xray inbound 内写入 `_remark` 字段作为节点名称元数据。当前 Xray 会忽略未知字段；该字段只供脚本在修改端口、删除节点、重建 `/root/xray_nodes_info.txt` 时恢复节点备注使用。

---

## 🔐 安全与副作用

脚本需要 root 权限，会对系统做以下改动：

- 安装必要依赖与 Xray core；默认不执行整机升级
- 写入 `/usr/local/etc/xray/config.json`，并保留最近 5 份 `config.json.bak.*` 备份
- 写入 `/etc/sysctl.d/99-xray.conf` 开启 BBR 与网络参数优化
- 如果系统没有 swap 且不存在 `/swapfile`，会创建 1G swap
- 修改系统防火墙规则，并尽量持久化到对应后端
- 配置监控报警时会写入 `/root/.msmtprc` 与 `/root/.xray_monitor.conf`，权限为 `600`
- 启用监控时会写入 `xray-monitor.service` / `xray-monitor.timer`，timer 每分钟运行一次

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
- 入站端口计算，包括端口耗尽时返回非 0
- public key 派生失败、业务端口过滤与端口修改链接备注
- 配置原子写入与回滚流程
- 节点信息解析
- SMTP 输入校验
- 防火墙返回码捕获链路
- 流量统计首次记录 delta=0
- 监控告警按故障详情去重
- 节点备注写入配置并可恢复

在 Debian 13 VPS 上的实测结果：

```text
通过: 11  失败: 0  跳过: 1
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

A: 运行菜单 `7) 排错诊断`，会依次检查：

- Xray 服务状态与版本
- 配置文件是否存在、JSON 是否合法、业务节点是否有 privateKey
- 业务端口监听
- 防火墙放行状态
- SOCKS5 落地节点连通性
- BBR 状态
- 内存、磁盘、CPU 负载
- 最近 1 小时 Xray 错误日志

还需要确认云厂商安全组已放行对应 TCP 端口，例如 443、8443 等。脚本只能修改 VPS 系统内的防火墙，不能自动修改云厂商控制台里的安全组。

常用排查命令：

```bash
systemctl status xray --no-pager -l
journalctl -u xray -n 30 --no-pager
xray run -test -config /usr/local/etc/xray/config.json
```

如果刚改配置后启动失败，脚本会自动尝试回滚。也可以手动查看备份：

```bash
ls -1t /usr/local/etc/xray/config.json.bak.*
```

**Q: 安装 Xray 时卡在下载？**

A: 脚本依赖 GitHub 下载官方 Xray 安装脚本，国内部分机器可能被墙。解决方案：
- 给 VPS 临时配置 `8.8.8.8` / `1.1.1.1` DNS
- 使用代理：`export https_proxy=http://...` 后再运行脚本
- 或手动下载脚本后本地执行

**Q: SOCKS5 密码里有 `:` 或 `|` 怎么办？**

A: 大多数代理商给的是 `host:port:user:pass`，例如：

```text
161.77.48.218:12324:14aaddb22c3ae:8b9027e676
```

这种可以直接粘贴。只有当密码里有 `:`、`@`、`#` 等特殊字符时，才建议使用 `socks5://user:pass@host:port` 或 `socks://user:pass@host:port` 格式，并对特殊字符做 URL 编码：

- `:` → `%3A`
- `@` → `%40`
- `#` → `%23`

常见格式 `host:port:user:pass` 中，密码不能包含 `:`。

**Q: `xray run -test` 报 `Failed to get format`？**

A: 新版 Xray 对配置文件格式识别更严格，临时配置文件需要 `.json` 后缀。当前脚本已将临时配置统一写成 `/tmp/.xray_config.new.XXXXXX.json`。

**Q: 启动失败并提示 `permission denied` 读取 `config.json`？**

A: 这通常是 Xray service 以 `nobody` 等非 root 用户运行，但配置文件是 `root:root 600`。当前脚本会继承现有配置的 owner/group，并保持 `600` 权限，避免泄露配置又保证服务可读。

**Q: 如何升级到新版本脚本？**

A: 重新下载覆盖即可。现有配置（Xray config、节点信息、监控配置）均独立保存，不会丢失。

**Q: 监控、流量统计日志在哪里？**

A: 常用位置：

- 流量数据库：`/root/.xray_traffic_db`
- 流量采集脚本：`/root/.xray_traffic_record.sh`（cron 每 5 分钟运行一次）
- 监控日志：`/var/log/xray/monitor.log`
- 监控配置：`/root/.xray_monitor.conf`
- 监控脚本：`/root/.xray_monitor.sh`（systemd timer 每分钟运行一次）

同类监控告警有 30 分钟冷却时间，短时间内不会重复刷屏。

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
