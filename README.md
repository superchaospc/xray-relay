# xray-relay

VPS 上一键部署 **Xray VLESS + REALITY** 中转到住宅 SOCKS5 出口节点的 Bash 脚本。支持多节点、固定端口→节点映射、开机自启、流量统计、监控报警，以及生成的 VLESS 链接自动渲染终端二维码，方便 Shadowrocket / V2rayN / V2rayNG / Neobox 直接扫码导入。

> ⚠️ **免责声明**：本项目仅供学习研究网络协议与系统运维使用。请用户遵守所在国家/地区的法律法规，自行承担使用后果。作者不对使用本脚本造成的任何直接或间接损失负责。

---

## 功能特性

- **VLESS + REALITY + XTLS-Vision** 满血配置，伪装目标为 `www.microsoft.com`
- **中转架构**：VPS 入口 → 前置 SOCKS5（住宅 IP）出口，也支持纯 VPS 直连模式
- **固定端口映射**：每个前置节点绑定独立监听端口，客户端可精确选择出口，不做负载均衡
- **多节点管理**：菜单化添加、删除节点，修改端口
- **自动防火墙放行**：依次尝试 `ufw` / `firewalld` / `iptables`，跨发行版通吃
- **BBR 加速**：自动开启 BBR 拥塞控制并写入内核调优参数
- **流量统计**：基于 Xray API 的累计上行/下行流量查看
- **排错诊断**：一键检查服务状态、端口监听、防火墙规则、前置连通性
- **监控报警**：可选配置邮件告警（Gmail/QQ/163 等 SMTP），服务异常自动发信
- **终端二维码**：节点生成后直接在终端渲染 VLESS 二维码，主流客户端扫码即导入
- **多发行版支持**：Debian / Ubuntu / CentOS / AlmaLinux / Rocky / Fedora

---

## 系统要求

- Linux x86_64 VPS，root 权限
- 以下任一包管理器：`apt` / `dnf` / `yum`
- 内核 ≥ 4.9（支持 BBR，绝大多数现代发行版默认满足）
- 出站 443 可访问 GitHub（用于首次下载官方 Xray 安装脚本）

脚本会自动检测并安装依赖：`xray-core`、`python3`、`curl`、`iproute2`、`qrencode`（懒加载）、`msmtp`（仅配置邮件时）。

---

## 快速开始

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-relay/main/xray_deploy.sh)
```

或下载到本地后运行（推荐，便于后续反复调用）：

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-relay/main/xray_deploy.sh -o /root/xray_deploy.sh
chmod +x /root/xray_deploy.sh
/root/xray_deploy.sh
```

### 首次部署

1. 运行脚本，选择 **`1) 全新安装`**
2. 按提示输入 SOCKS5 前置节点，格式：`IP:端口:用户名:密码`
   - 例如：`161.77.77.5:12324:user01:pass01`
   - 按 `done` 或直接回车结束录入
   - 如果暂时没有住宅节点，可创建一个 443 端口的 VPS 直连节点作为起点
3. 脚本自动完成：Xray 安装 → 密钥生成 → 配置下发 → BBR 开启 → 防火墙放行 → 服务启动
4. 部署完成后，每个节点的 VLESS 链接 + 终端二维码会直接显示在屏幕上

### 导入客户端

脚本在每个节点生成完毕后会自动打印二维码。扫码方式：

- **Shadowrocket (iOS)** — 首页右上角扫一扫
- **V2rayN (Windows)** — `Ctrl+Shift+Alt+S` 从屏幕扫码，或从剪贴板导入
- **V2rayNG (Android)** — 加号 → 扫描二维码（对着另一台屏幕）
- **Neobox (Android)** — 导入配置 → 扫描屏幕二维码

> 💡 扫码成功率与终端背景相关。白底或纯色主题最佳，避免透明/渐变背景。

---

## 菜单功能

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

## 架构说明

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

## 配置文件位置

| 文件 | 用途 |
| --- | --- |
| `/usr/local/etc/xray/config.json` | Xray 主配置 |
| `/root/xray_nodes_info.txt` | 所有节点的 VLESS 链接备份 |
| `/etc/sysctl.d/99-xray.conf` | BBR 与内核调优参数 |
| `/root/.xray_monitor.conf` | 监控告警配置（如启用） |
| `/var/log/xray/` | Xray 运行日志 |

---

## 常见问题

**Q: 部署后客户端连不上？**
A: 运行菜单 `7) 排错诊断`，会依次检查 Xray 服务状态、端口监听、防火墙、前置 SOCKS5 连通性。

**Q: 安装 Xray 时卡在下载？**
A: 脚本依赖 GitHub 下载官方 Xray 安装脚本，国内部分机器可能被墙。解决方案：
- 给 VPS 临时配置 `8.8.8.8` / `1.1.1.1` DNS
- 使用代理：`export https_proxy=http://...` 后再运行脚本
- 或手动下载脚本后本地执行

**Q: SOCKS5 密码里有 `:` 或 `|` 怎么办？**
A: 脚本内部使用 ASCII Unit Separator (`\x1f`) 作为分隔符，常见密码字符都能正常处理。但输入时仍需注意 `:` 是字段分隔符，请确保密码中不含 `:`。

**Q: 如何升级到新版本脚本？**
A: 重新下载覆盖即可。现有配置（Xray config、节点信息、监控配置）均独立保存，不会丢失。

---

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — 核心代理引擎
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install) — 官方安装脚本

---

## License

MIT

---

## 免责声明（再次强调）

本工具仅用于学习网络协议、系统运维与安全研究。使用者应对自己的行为负全部责任，并遵守所在国家/地区的相关法律法规。严禁用于任何违反当地法律的用途。作者不对使用本脚本导致的任何后果负责。
