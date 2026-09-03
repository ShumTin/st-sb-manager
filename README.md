# ST-SB Manager

基于 sing-box 的多协议代理节点管理脚本，提供按需启用协议、独立用户套餐、流量统计、到期控制、订阅生成和 7 天域名/IP 访问审计。

首次安装不会启用任何代理协议。安装完成后，可通过交互式菜单逐个添加或删除协议；协议变更会应用到所有用户，已有订阅地址保持不变。

ps：个人自用，因此有一些个性化代码和设置，有需求可自行修改。

## 功能

- 支持六种可选协议：
  - VLESS + REALITY
  - AnyTLS
  - Hysteria2
  - Shadowsocks 2022
  - TUIC v5
  - Trojan TLS
- 为每个用户独立设置流量额度、到期日期和自动续期策略
> **⚠️ 流量额度按服务商双向流量（入站 + 出站）口径统计。**
- 流量用尽或到期后自动停用用户
- 自动生成 Base64、Mihomo 和 Quantumult X 订阅
- 记录用户、协议、目标域名/IP、端口、网络类型和时间，滚动保留 7 天
- 自动申请和续期 Let's Encrypt 证书
- 自动配置 UFW，并保留当前 SSH 端口
- 可在管理菜单中检测并持久化开启 BBR
- 支持交互式在线更新和更新失败回滚
- 支持带备份的安全卸载

## 系统要求

- Debian 或 Ubuntu
- root 权限
- 首次安装时根分区至少约 3 GiB 可用空间（用于临时编译 sing-box）
- 一个已解析到 VPS 公网 IPv4 地址的域名
- TCP 80 和 TCP 443 可从公网访问
- 云服务商安全组允许当前 SSH 端口

如果启用了云服务商安全组，还需要在添加协议后手动放行脚本生成的随机端口。可在 `proxy` 菜单的“节点信息”中查看端口和传输类型。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ShumTin/st-sb-manager/master/install.sh)
```

安装程序会要求输入：

- 节点域名
- Let's Encrypt 邮箱
- VPS 标称带宽
- SSH 端口
- 可选的 KiwiVM VEID 和 API Key（用于调用 BandwagonHost API，同步 VPS 流量重置日期；非搬瓦工 VPS 可直接跳过）

KiwiVM API Key 只用于本次查询，不会保存。

> [!WARNING]
> 重新运行完整安装脚本会重新生成配置和用户令牌，使旧订阅失效。日常升级请使用更新功能。

## 开始使用

安装完成后运行：

```bash
proxy
```

推荐顺序：

1. 进入“协议管理”，逐个启用所需协议。
2. 在云服务商安全组中放行显示的随机端口。
3. 选择“新增用户”，设置流量、到期日期和续期策略。
4. 将生成的 HTTPS 订阅地址添加到客户端。

如需启用 BBR，可在 `proxy` 主菜单选择“BBR 管理”。程序会先检查当前内核是否支持 BBR，成功后将配置保存到 `/etc/sysctl.d/99-st-sb-bbr.conf`；卸载 ST-SB 时会保留该主机级网络设置。

协议删除会同时关闭 UFW 端口并从所有用户订阅中移除该协议，但不会改变用户的订阅地址。

## 协议与端口

| 协议 | 传输 | 证书 |
| --- | --- | --- |
| VLESS + REALITY | TCP | REALITY 密钥 |
| AnyTLS | TCP | Let's Encrypt |
| Hysteria2 | UDP | Let's Encrypt |
| Shadowsocks 2022 | TCP | 不需要 |
| TUIC v5 | UDP | Let's Encrypt |
| Trojan TLS | TCP | Let's Encrypt |

代理端口在启用协议时随机生成。TCP 80 用于证书申请与续期，TCP 443 用于 HTTPS 订阅。

添加 Hysteria2 时可以选择是否启用 UDP 端口跳跃。启用后可自行输入端口范围和跳跃间隔；端口范围留空时自动选择连续 100 个未占用端口，间隔留空时使用 30 秒。请在云服务商安全组中放行完整的 UDP 跳跃范围。

## 订阅格式

订阅服务会根据客户端请求自动选择格式，也可以通过查询参数强制指定：

```text
https://节点域名/sub/用户令牌?target=mihomo
https://节点域名/sub/用户令牌?target=base64
https://节点域名/sub/用户令牌?target=quanx
```

| 参数 | 格式 | 常见客户端 |
| --- | --- | --- |
| `mihomo` | Clash/Mihomo YAML | Mihomo、Clash Meta |
| `base64` | URI 列表的 Base64 编码 | v2rayN、Shadowrocket |
| `quanx` | Quantumult X 节点列表 | Quantumult X |

Quantumult X 当前不支持 Hysteria2、Shadowsocks 2022 和 TUIC v5，这些协议会在该格式中显示为“不支持”；Trojan TLS 可正常输出。

## 常用命令

```bash
proxy                    # 打开管理菜单
proxy-protocol           # 启用或删除协议
proxy-user-add           # 新增用户
proxy-user-status        # 查看用户状态和订阅地址
proxy-update             # 更新管理程序
proxy-audit              # 查看最近 24 小时访问记录
proxy-audit --summary --days 7
```

查看服务与防火墙：

```bash
systemctl status sing-box proxy-manager --no-pager
ufw status numbered
```

## 更新

已安装节点可以运行：

```bash
proxy-update
```

也可以在 `proxy` 菜单中选择“更新版本”。如果本机更新器版本过旧，可重新引导最新更新器：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ShumTin/st-sb-manager/master/update.sh)
```

更新器只替换运行文件，不会重新生成用户、订阅令牌或协议密钥；更新前会创建备份，失败时自动恢复。

## 卸载

在 `proxy` 菜单中选择“卸载”，并按提示输入 `UNINSTALL` 确认。卸载前会在 `/root` 下创建完整备份。

卸载会删除：

- ST-SB 的 systemd 服务与运行配置
- 用户流量和访问审计数据库
- 管理命令
- nginx 订阅站点
- 已启用协议对应的随机 UFW 端口规则

卸载会保留：

- Let’s Encrypt 证书
- sing-box 可执行文件
- SSH、TCP 80 和 TCP 443 的 UFW 规则
- 卸载前备份

## 访问审计与隐私

系统启用了域名/IP 级访问审计。请在提供节点服务前明确告知所有使用者。

审计内容包括：

- 用户
- 协议
- 目标域名或 IP
- 目标端口
- TCP/UDP 类型
- 访问时间

审计不保存来源 IP、URL 路径、查询参数或网页内容，记录滚动保留 7 天。

查询示例：

```bash
proxy-audit
proxy-audit --user alice --days 7
proxy-audit --domain example.com --days 7
proxy-audit --summary --days 7
```

## 重要文件

| 路径 | 说明 |
| --- | --- |
| `/etc/proxy-manager/config.json` | 用户、协议和服务端密钥 |
| `/etc/sing-box/config.json` | 当前 sing-box 配置 |
| `/var/lib/proxy-manager/usage.db` | 用户流量统计 |
| `/var/lib/proxy-manager/audit.db` | 访问审计记录 |
| `/root/node-info.txt` | 节点安装与端口信息 |

> [!CAUTION]
> 不要泄露 `/etc/proxy-manager/config.json`。该文件包含全部用户凭据和服务端密钥。

## 许可证

本项目使用 [MIT License](LICENSE)。
