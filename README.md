# 🚀 xray-relay - Xray VLESS+REALITY 一键部署中转脚本

> One-click Xray VLESS+REALITY deployment with residential SOCKS5 multi-hop relay support

![GitHub repo size](https://img.shields.io/github/repo-size/superchaospc/xray-relay?style=flat-square)
![GitHub last commit](https://img.shields.io/github/last-commit/superchaospc/xray-relay?style=flat-square)
![GitHub License](https://img.shields.io/github/license/superchaospc/xray-relay?style=flat-square)
![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)
![Xray](https://img.shields.io/badge/Core-Xray-2F6FED?style=flat-square)

VPS 上一键部署 **Xray VLESS + REALITY** 的 Bash 脚本。既支持 **VPS 直连线路**，也支持 **VPS 入口 → 住宅 SOCKS5 出口** 的中转线路；支持单条添加、批量生成住宅 SOCKS5 中转节点、批量生成 VPS 直连节点、固定端口→节点映射、配置自动校验回滚、流量统计、监控报警，以及生成的 VLESS 链接自动渲染终端二维码，方便 Shadowrocket / V2rayN / V2rayNG / Neobox 直接扫码导入。

> ⚠️ **免责声明**：本项目仅供学习研究网络协议与系统运维使用。请用户遵守所在国家/地区的法律法规，自行承担使用后果。作者不对使用本脚本造成的任何直接或间接损失负责。

---

## ✨ 功能特性

- 🔐 **VLESS + REALITY + XTLS-Vision** 满血配置，默认伪装目标为 `www.cloudflare.com`，可用环境变量覆盖
- 🌉 **中转架构**：VPS 入口 → 前置 SOCKS5（住宅 IP）出口，也支持纯 VPS 直连模式
- 🎯 **固定端口映射**：每个前置节点绑定独立监听端口，客户端可精确选择出口，不做负载均衡
- 🧩 **多节点管理**：菜单化添加、删除节点，修改端口和节点名称
- 🏘️ **批量住宅节点**：一次最多导入 20 个住宅 SOCKS5 节点，自动生成端口、线路名称、链接和二维码
- 🚀 **批量直连节点**：一次最多生成 30 个 VPS 直连节点，自动命名为 `VPS-Direct-1` 起并刷新订阅
- 🛟 **安全写配置**：生成临时 JSON → `xray run -test` 校验 → 备份旧配置 → 原子替换 → 启动失败自动回滚
- 🧱 **自动防火墙放行**：依次尝试 `ufw` / `firewalld` / `nftables` / `iptables`，nftables 会识别真实 input 链，尽量持久化规则，并对云厂商安全组给出提醒
- 🔒 **供应链保护**：默认固定 Xray 官方安装脚本 commit 并校验 sha256，也支持显式切回 `main`
- ⚡ **BBR 加速**：自动开启 BBR 拥塞控制并写入内核调优参数
- 📊 **流量统计**：基于 Xray API 的累计上行/下行流量查看
- 🩺 **排错诊断**：一键检查服务、配置、端口、防火墙、前置连通性、BBR、系统资源和错误日志
- 🚨 **监控报警**：可选配置邮件告警（Gmail/QQ/163 等 SMTP），每分钟巡检，异常自动发信
- 📱 **终端二维码**：节点生成后直接在终端渲染 VLESS 二维码，主流客户端扫码即导入
- 🐧 **多发行版支持**：Debian / Ubuntu / CentOS / AlmaLinux / Rocky / Fedora

---

## 🆕 v2.2.17 关键改动

- 新增 `16) 批量删除节点`：可一次选择多个住宅 SOCKS5 或 VPS 直连节点删除，支持 `1,3,5-7` 这类编号输入
- 批量删除继续走「写临时文件 → `xray run -test` 校验 → 原子替换 → 重启失败回滚」流程，并在成功后逐个回收被删节点端口的防火墙规则
- 删除后自动刷新 `/root/xray_nodes_info.txt` 与 `/root/xray_subscription.txt`
- 新增 `test_batch_delete_nodes.sh`，覆盖批量选择解析、共享 outbound 保留、未引用 outbound 删除和菜单入口

---

## 🆕 v2.2.16 关键改动

- 修复菜单 `6) 流量统计` 手动触发记录与 5 分钟 cron 同时运行时的竞态：记录脚本新增 `flock` 非阻塞锁，避免两个进程同时 append / truncate / rewrite `/root/.xray_traffic_db` 导致历史行丢失
- 流量记录 delta 基线同步改为按 `(tag, port)` 记录，和 v2.2.15 的历史展示聚合口径保持一致，避免同 tag 改端口后的历史行影响当前端口 delta
- 注意：节点改端口后，新 `(tag, port)` 的首个 5 分钟记录周期会先建立基线，期间流量不计入历史；这是为了优先保证旧端口历史不会污染新端口
- 增强 `test_traffic_record.sh`，覆盖同 tag 不同端口历史行不会干扰当前端口增量计算

## 🆕 v2.2.15 关键改动

- 修复菜单 `6) 流量统计` 历史区段（过去 1 小时 / 今天 / 过去 7 天 / 过去 30 天）的聚合错误：原来按 `tag` 单字段累加，若曾经用菜单 4 改过端口，旧端口和新端口共享同一个 `vless-in-N` tag，会显示两行一模一样的数字，并且旧端口被错误地标上「当前出口 IP」
- 改为按 `(tag, port)` 双字段聚合；不在当前 `inbounds` 里的 `(tag, port)` 标记为「(已删除)」，保留历史可追溯
- 新增 `test_traffic_show.sh` 覆盖改端口后的历史聚合场景

---

## 🆕 v2.2.14 关键改动

- 修复菜单 `7) 排错诊断` 第 `[8/8]` 步：journal 里发现 `error/fail/refused` 时未累加 `ERRORS`，导致总结行可能在屏幕已显示「发现错误」的情况下仍打印 `✓ 所有检查通过`
- 同步菜单顶部横幅版本号到 v2.2.14（v2.2.13 release 包内仍显示 v2.2.12 的小瑕疵）

---

## 🆕 v2.2.13 关键改动

- 新增 `15) 修改节点名称`：菜单 1-14 编号保持不变，可选择任意住宅 SOCKS5 或 VPS 直连节点并更新 `_remark`、`/root/xray_nodes_info.txt` 与 `/root/xray_subscription.txt`，无需重启 Xray
- 改名走「写临时文件 → `xray run -test` 校验 → 原子替换」流程，编号非法或参数错误会自动放弃改动并保留原配置
- 节点列表统一显示业务节点（住宅 SOCKS5 与 VPS 直连），便于在多节点环境下精确选择
- 新增 `test_rename_node.sh`，覆盖住宅 / 直连节点 `_remark` 改名以及旧 `INFO_FILE` 名称的覆盖刷新

---

## 🆕 v2.2.12 关键改动

- 修复 `prompt_read` 在 v2.2.11 中保留首尾空白的回归，菜单编号、数字输入和 `y/n` 确认会重新按原行为自动修剪空白
- 卸载时同步清理 `/root/.xray_public_key`，避免 public key 缓存残留
- 为批量防火墙延迟持久化状态补充全局变量注释和显式声明，降低后续维护误改风险
- 新增 `test_prompt_read_trim.sh`，覆盖带首尾空白的交互输入

---

## 🆕 v2.2.11 关键改动

- 统一单条 VPS 直连和批量 VPS 直连的端口占用检查，都会同时避开系统占用端口和现有配置端口
- 批量 VPS 直连添加端口时，nftables / iptables 规则改为批量结束后统一持久化，减少重复落盘
- Reality public key 会缓存到 `/root/.xray_public_key`，后续刷新订阅/添加节点优先读取缓存，减少重复派生
- 清理 shellcheck 质量问题：`prompt_read` 固定 `read -r`、移除未使用变量、备份清理不再使用 `ls | tail`
- 统一更多 Python 片段通过 `CONFIG_FILE` 环境变量读取配置，便于测试和自定义路径

---

## 🆕 v2.2.10 关键改动

- 新增批量添加 VPS 直连节点：输入数量后自动创建 `VPS-Direct-1` 起的直连线路，最多一次 30 个
- 批量直连成功后会逐条输出 VLESS 链接和终端二维码，并自动刷新 `/root/xray_subscription.txt`
- 批量直连操作会直接打印订阅 Data URL，方便客户端一次性导入
- 新增 `test_batch_direct_nodes.sh`，覆盖批量直连配置写入、direct 路由和菜单入口

---

## 🆕 v2.2.9 关键改动

- 修复 nftables 回收旧端口时 handle 提取接口不匹配的问题，改端口/删节点会正确删除旧端口规则
- nftables 新增规则会写入 `xray-relay-managed` comment，回收时优先只删除脚本管理的规则
- 兼容清理 v2.2.8 及更早版本创建的 legacy 精确端口规则；若同端口存在 managed 规则，则不会碰 legacy 规则
- 卸载时会从当前配置读取端口，并尝试回收带 managed comment 的脚本管理防火墙规则
- 新增 `test_nft_firewall_revoke.sh`，覆盖 managed/legacy handle 删除、同端口防误删和端口集合防误删

---

## 🆕 v2.2.8 关键改动

- SMTP 密码/授权码明文保存提醒前移到密码输入之前，用户可在输入敏感信息前决定是否继续
- `config.json` 权限归一化失败时会明确报错并中止安装/回滚流程，避免脚本误判成功
- apt/apt-get 依赖安装统一添加 `--no-install-recommends`，减少推荐包体积
- 新增 SMTP 明文提醒顺序回归测试

---

## 🆕 v2.2.7 关键改动

- 修复回滚后 `config.json` 从备份恢复为 `600 root:root`，导致非 root Xray 无法读取配置的问题
- `systemctl restart xray` 直接返回非零时仍会继续进入回滚流程，不再被 `set -e` 提前打断
- 监控邮件的 `tls_trust_file` 会自动探测 Debian/RHEL/Fedora 常见 CA bundle 路径
- SMTP 端口会去掉前导零并校验 `1-65535` 范围，`0465` 会按 `465` 正确生成 `tls_starttls off`
- msmtp 安装失败会立即中止配置流程，并明确提示 SMTP 密码/授权码会明文保存在 `/root/.msmtprc`（权限 `600`）
- 新增回滚权限恢复和跨发行版 CA bundle 回归测试

---

## 🆕 v2.2.6 关键改动

- `config.json` 改为 `root:<Xray 服务用户主组>` + `640`，避免本地非服务用户读取 UUID/REALITY 私钥
- 监控邮件配置不再直接 `source`，改用受限 `KEY=VALUE` 解析，并收紧邮箱字符集以阻断 shell 注入
- nftables 默认不再覆盖既有 `/etc/nftables.conf`；如确认需要用当前 ruleset 覆盖，可设置 `XRAY_NFTABLES_OVERWRITE=1`
- 卸载清理 cron 前会先确认存在 `xray_traffic_record`，避免无匹配项时写入空 crontab
- `get_ip` 会校验自动获取和缓存内容必须是合法 IP，避免 HTML/错误页进入 VLESS 链接
- UFW 放行改为显式 `${port}/tcp`
- Xray 官方安装脚本默认值从 `main` 改为固定 commit + sha256 校验
- 新增 SMTP 注入、非法公网 IP、卸载 cron 清理等回归测试

---

## 🆕 v2.2.5 关键改动

- 修复删除节点时 `socks5-out-1` 会误匹配 `socks5-out-10` 的问题，避免产生孤儿 outbound
- nftables 端口规则检测改用 `nft -j -a` JSON 解析，避免 `tcp dport 80-90 accept` 被误判为某个单端口已放行
- nftables 旧端口回收同样使用精确解析，避免误删端口集合或端口范围规则
- `update_system` 对临时软件源抖动更宽容，依赖安装失败不会立刻打断脚本；仍会硬校验必需的 `python3`
- `update_xray` 查询 GitHub 最新版本增加 10 秒超时，并改用 JSON 解析 `tag_name`
- `generate_config` 生成失败时会清理临时配置文件
- `get_ip` 在自动获取失败且 stdin EOF 时会返回失败，调用方不再带着空 `VPS_IP` 继续生成链接
- 新增删除节点 outbound 精确匹配、`get_ip` EOF、nftables 端口范围误判回归测试

---

## 🆕 v2.2.4 关键改动

- 所有面向用户的交互提示在 stdin EOF 时都会优雅取消并退出 0，避免非交互管道触发 `set -e` 退出 1
- 新增 `test_prompt_read_eof.sh` 覆盖 EOF 取消路径
- 历史防火墙孤儿规则不在全新安装时自动扫描删除，避免误删用户手工规则；仍可通过修改端口/删除节点路径做针对性回收

---

## 🆕 v2.2.3 关键改动

- 批量添加成功后输出链接时，`format_vless_host` 只执行一次，避免最多 20 次重复启动 `python3`
- 修改端口时如果新旧端口相同，会提示“无需修改”，不再因为当前监听端口被占用而误报
- firewalld 回收旧端口前会先查询规则是否存在；不存在时提示无需回收，不再报失败
- 给 `FORMAT_VLESS_HOST_PY` 的 `exec` 契约补充注释，避免未来误传用户输入

---

## 🆕 v2.2.2 关键改动

- 修改节点端口后会尽量回收旧端口的 `ufw` / `firewalld` / `nftables` / `iptables` 放行规则
- 删除节点后会尽量回收被删除节点的防火墙端口规则，减少长期运行后的失效规则堆积
- 订阅文件改为临时文件 + 原子替换写入，避免静态 Web 服务读到截断内容
- `format_vless_host` 的 IPv6 包裹逻辑统一由同一段 Python helper 提供，避免 Bash / Python 双份实现漂移
- 空订阅不再打印空 Data URL
- `test_public_key_and_ports.sh` 使用 `XRAY_BIN` 指向 fake xray，macOS 未安装真实 xray 时也能稳定测试

---

## 🆕 v2.2.1 关键改动

- 修复订阅文件只在批量添加时刷新导致的配置漂移；首次安装、单条添加、直连添加、改端口、删节点、查看状态都会同步刷新 `/root/xray_subscription.txt`
- 卸载时同步清理 `/root/xray_subscription.txt`
- 防火墙端口放行调整到 Xray 重启成功后执行，避免回滚时留下新端口规则
- 批量粘贴时空行只会被忽略，不再提前结束录入；请用 `done` 结束
- 默认不再打印超长 Data URL；如确需终端输出，可设置 `XRAY_PRINT_SUB_DATA_URL=1`
- 新增订阅文件生成测试，测试套件覆盖到批量订阅相关代码

---

## 🆕 v2.2.0 关键改动

- 新增 **批量添加住宅 SOCKS5 节点** 菜单，一次最多导入 20 个 `host:port:user:pass` 节点
- 批量导入时线路名称自动使用 IP/host，无需逐条输入备注
- 批量添加成功后自动逐条输出 VLESS 链接和终端二维码
- 自动生成 base64 订阅内容到 `/root/xray_subscription.txt`
- 首次部署与菜单添加共用同一套 SOCKS5 解析逻辑，减少格式校验分叉

---

## 🆕 v2.1.1 关键改动

- 修复 nftables 只存在 fail2ban 表/链时被误判为「端口未放行」的问题
- nftables 不再硬编码 `inet filter input`，会自动扫描实际存在的 input base chain
- 当 nftables input 链默认策略为 `accept` 时，脚本会提示无需额外放行；只有默认 `drop` / `reject` 时才自动插入端口放行规则
- 新增 nftables 防火墙识别测试，覆盖 fail2ban `f2b-table/f2b-chain` 与默认 drop 链场景

---

## 🆕 v2.1 关键改动

- 配置写入采用「临时文件 → `xray run -test` → 备份 → 原子替换 → 重启失败回滚」流程
- Xray 官方安装脚本默认跟随 `main`，新 VPS 可直接一键部署；生产环境仍建议显式 pin commit 和 sha256
- SOCKS5 支持常见 `host:port:user:pass` 与 URL 格式，并拒绝控制字符注入
- 防火墙规则支持 `ufw` / `firewalld` / `nftables` / `iptables`，nftables 与 iptables 会尝试自动持久化
- 节点备注写入配置元数据 `_remark`，修改端口或重建 `INFO_FILE` 后仍能保留原名称
- systemd drop-in 自动提升 Xray 文件描述符上限到 `65535`
- 默认只安装必要依赖，不做整机 `apt upgrade`；需要时可用 `XRAY_FULL_UPGRADE=1`
- 敏感文件统一 `600` 权限，终端输出可用 `XRAY_REDACT=1` 隐藏 UUID / 密钥中段
- `config.json` 写入后强制 `644 root:root`，避免老文件错误权限被新写入继承导致 Xray (nobody) 启动失败

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
| `XRAY_INSTALL_REF` | `e741a4f56d368afbb9e5be3361b40c4552d3710d` | `XTLS/Xray-install` 的 ref；默认固定 commit，需要追新可显式设为 `main` |
| `XRAY_INSTALL_SHA256` | `7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555` | `install-release.sh` 的 sha256；设置后会强制校验，追新 `main` 时需显式置空 |
| `XRAY_FULL_UPGRADE` | `0` | 设为 `1` 时才执行整机升级 |
| `XRAY_REDACT` | `0` | 设为 `1` 时隐藏终端输出里的 UUID / 密钥中段 |
| `XRAY_PRINT_SUB_DATA_URL` | `0` | 设为 `1` 时在终端打印订阅 Data URL |
| `XRAY_NFTABLES_OVERWRITE` | `0` | 设为 `1` 时允许用当前 ruleset 覆盖既有 `NFTABLES_CONF` |
| `NFTABLES_CONF` | `/etc/nftables.conf` | nftables 持久化配置文件路径，通常无需修改 |
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

首次选择 `1) 全新安装` 或 `8) 更新 Xray` 时，脚本默认使用已固定的 Xray 官方安装脚本 commit，并校验 `install-release.sh` 的 sha256，降低上游脚本变化带来的供应链风险。

### 生产安全模式

默认已经采用固定 commit + sha256。需要升级固定版本时，可先查询 `XTLS/Xray-install` 的新 commit，并计算对应 sha256：

```bash
git ls-remote https://github.com/XTLS/Xray-install.git refs/heads/main

curl -L https://raw.githubusercontent.com/XTLS/Xray-install/<COMMIT>/install-release.sh | sha256sum
```

然后编辑脚本顶部，替换默认值：

```bash
XRAY_INSTALL_REF_DEFAULT="<COMMIT>"
XRAY_INSTALL_SHA256_DEFAULT="<sha256>"
```

### 显式追新模式

如需主动跟随官方安装脚本 `main` 分支，可在运行时显式覆盖 ref，并把 sha256 校验置空：

```bash
XRAY_INSTALL_REF=main XRAY_INSTALL_SHA256= /root/xray_deploy.sh
```

也可以一行运行远端脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-relay/main/xray_deploy.sh -o /tmp/xray_deploy.sh \
  && chmod +x /tmp/xray_deploy.sh \
  && XRAY_INSTALL_REF=main XRAY_INSTALL_SHA256= /tmp/xray_deploy.sh
```

### 🛠️ 首次部署 VPS 直连

1. 运行脚本，选择 **`1) 全新安装`**
2. 在 SOCKS5 节点录入阶段输入 `done`
3. 按提示输入 `y` 创建 443 端口的 VPS 直连节点
4. 输入节点备注名称（回车默认 `VPS-Direct`）
5. 脚本自动完成：依赖检查 → Xray 检查/安装 → 密钥生成 → 配置校验下发 → BBR → 防火墙 → 服务启动
6. 部署完成后会输出 VLESS 链接和二维码

### 🛠️ 批量添加 VPS 直连

已有配置后运行脚本，选择 **`14) 批量添加 VPS 直连节点`**，再输入要搭建的数量即可。单次最多 30 个，脚本会自动从当前可用端口继续分配，并按 `VPS-Direct-1`、`VPS-Direct-2`、`VPS-Direct-3` 的格式命名。

批量直连添加成功后，脚本会逐条输出 VLESS 链接和二维码，同时刷新 `/root/xray_subscription.txt` 并打印订阅 Data URL。

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

### 📦 批量添加住宅 SOCKS5

菜单选择 **`13) 批量添加住宅 SOCKS5 节点`**，每行粘贴一个节点，最多 20 个：

```text
192.204.3.26:12324:14ae356118cc6:cb67514644
192.204.0.126:12324:14ae356118cc6:cb67514644
168.158.45.45:12324:14ae356118cc6:cb67514644
```

粘贴完成后输入 `done` 结束。空行会被忽略，避免复制时多余换行提前终止录入。脚本会自动用 IP/host 作为线路名称，批量写入配置，重启成功后逐条输出 VLESS 链接和二维码，并生成 base64 订阅内容到 `/root/xray_subscription.txt`。

如果你确实需要在终端直接打印 Data URL，可这样运行：

```bash
XRAY_PRINT_SUB_DATA_URL=1 bash xray_deploy.sh
```

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
| 13 | 批量添加住宅 SOCKS5 节点（最多 20 个） |
| 14 | 批量添加 VPS 直连节点（最多 30 个） |
| 15 | 修改节点名称（住宅 SOCKS5 / VPS 直连均支持） |
| 16 | 批量删除节点（支持逗号 / 空格 / 范围选择） |
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
| `/root/xray_subscription.txt` | base64 订阅内容 |
| `/root/.xray_vps_ip` | VPS 公网 IP 缓存 |
| `/root/.xray_traffic_db` | 流量统计数据库 |
| `/root/.xray_traffic_record.sh` | 流量采集脚本（cron 每 5 分钟运行一次） |
| `/etc/sysctl.d/99-xray.conf` | BBR 与内核调优参数 |
| `/etc/systemd/system/xray.service.d/limits.conf` | Xray 文件描述符上限配置 |
| `/root/.xray_monitor.conf` | 监控告警配置（如启用） |
| `/root/.xray_monitor.sh` | 监控巡检脚本 |
| `/root/.msmtprc` | msmtp 邮件发送配置（如启用监控邮件） |
| `/var/log/xray/` | Xray 运行日志 |

`/usr/local/etc/xray/config.json` 由脚本写入或回滚后会强制设置为 `640 root:<Xray 服务用户主组>`。这样可以避免 `600 root:root` 导致非 root Xray 服务用户读取失败，也避免 `644` 让本地非服务用户读取 UUID/REALITY 私钥。

> 说明：脚本会在 Xray inbound 内写入 `_remark` 字段作为节点名称元数据。当前 Xray 会忽略未知字段；该字段只供脚本在修改节点名称、修改端口、删除节点、重建 `/root/xray_nodes_info.txt` 时恢复节点备注使用。

---

## 🔐 安全与副作用

脚本需要 root 权限，会对系统做以下改动：

- 安装必要依赖与 Xray core；默认不执行整机升级
- 写入 `/usr/local/etc/xray/config.json`，并保留最近 5 份 `config.json.bak.*` 备份
- 写入 `/etc/sysctl.d/99-xray.conf` 开启 BBR 与网络参数优化
- 如果系统没有 swap 且不存在 `/swapfile`，会创建 1G swap
- 修改系统防火墙规则，并尽量持久化到对应后端
- 配置监控报警时会写入 `/root/.msmtprc` 与 `/root/.xray_monitor.conf`，权限为 `600`；SMTP 密码/授权码会以明文保存在 `/root/.msmtprc`
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
- `test_parser.py`：SOCKS5 输入解析，包括 URL 端口非法、IPv6、密码特殊字符
- `test_prompt_read_eof.sh`：交互提示在 stdin EOF 时优雅退出
- `test_prompt_read_trim.sh`：交互输入自动修剪首尾空白
- `test_get_ip_eof.sh`：公网 IP 获取在 EOF 场景下返回失败
- `test_next_port.sh`：入站端口计算，包括端口耗尽时返回非 0
- `test_public_key_and_ports.sh`：public key 派生失败、业务端口过滤与端口修改链接备注
- `test_atomic_config.sh`：配置原子写入与回滚流程
- `test_restart_rollback_permissions.sh`：重启失败回滚后恢复 `config.json` 权限
- `test_info_parse.sh`：节点信息解析
- `test_subscription_file.sh`：订阅文件生成与刷新
- `test_smtp_validate.sh`：SMTP 输入校验
- `test_firewall_capture.sh`：防火墙返回码捕获链路
- `test_nft_firewall.sh`：nftables input 链识别，包括 fail2ban 默认 accept 链与默认 drop 链
- `test_nft_firewall_revoke.sh`：nftables managed/legacy 端口规则回收与防误删
- `test_crontab_cleanup.sh`：卸载时清理流量统计 cron
- `test_delete_node_outbound_match.sh`：删除节点时 outbound 精确匹配
- `test_traffic_record.sh`：流量统计首次记录 delta=0
- `test_monitor_alert.sh`：监控告警按故障详情去重
- `test_config_remarks.sh`：节点备注写入配置并可恢复
- `test_rename_node.sh`：住宅与直连节点名称可修改并刷新订阅
- `test_batch_direct_nodes.sh`：批量 VPS 直连节点写入与菜单入口
- `test_batch_delete_nodes.sh`：批量删除节点选择解析、路由和 outbound 清理

当前测试结果：

```text
通过: 25  失败: 0  跳过: 0
```

如果系统未安装 `shellcheck`，静态检查会自动跳过该项。

---

## ❓ 常见问题

**Q: 脚本提示 `Xray 安装脚本来源未配置`，是不是坏了？**

A: 通常是你手动把脚本里的安装来源改成了空值。当前脚本默认固定 `XTLS/Xray-install` 的 commit 并校验 sha256，新 VPS 可直接安装。如需主动追新，也可以显式使用：

```bash
XRAY_INSTALL_REF=main XRAY_INSTALL_SHA256= /root/xray_deploy.sh
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

如果系统使用 nftables，脚本会自动识别实际 input 链名。像 fail2ban 创建的 `f2b-table/f2b-chain` 且默认策略为 `accept` 的场景，不需要额外添加 `inet filter input` 规则；真正默认 `drop` / `reject` 的 input 链才需要插入端口放行规则。

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

A: 这通常是 Xray service 以 `nobody` 等非 root 用户运行，但配置文件被写成了 `root:root 600`。当前脚本会强制把新写入或回滚恢复的 `config.json` 设为 `640 root:<Xray 服务用户主组>`，确保 Xray 服务用户可读，同时避免本地其他用户读取 UUID/REALITY 私钥。

历史教训：早期版本曾尝试「继承现有文件 owner/group」，但一旦初始文件意外是 `600 root:root`（比如 root umask 077 下用 Python `open('w')` 写出来的），后续每次写新配置都会延续这个错误，nobody 永远读不到。详见 [commit f28238c](https://github.com/superchaospc/xray-relay/commit/f28238c)。

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
