# sb：sing-box 多节点管理器

这是一个面向 NAT 服务器和普通 VPS 的独立 sing-box 管理器，采用 clean-room 方式实现。项目提供持久化 `sb` 命令、交互式菜单、多节点独立配置、客户端配置输出、TLS 自动化、Caddy 集成、备份回滚、旧配置迁移、在线更新、故障诊断和系统优化。

本项目借鉴了 `233boy/sing-box` 的管理体验，但没有复制其 GPL 源代码；本仓库使用 MIT License。

## 支持系统

- Alpine Linux 3.21+（OpenRC）
- Debian、Ubuntu（systemd）
- 优先使用 Alpine 软件包；仓库缺失时自动安装经 SHA-256 校验的 SagerNet 官方二进制
- sing-box 1.12.0 或更高版本

## 支持协议

- AnyTLS：自签名证书、已有证书或 ACME
- Shadowsocks 2022
- VLESS + REALITY + Vision
- 带认证的 SOCKS5
- Hysteria2 + Salamander 混淆
- TUIC
- Trojan
- VMess：TCP、WebSocket、HTTP、HTTP/2、HTTPUpgrade、QUIC
- VLESS TLS：WebSocket、HTTP/2、HTTPUpgrade
- Trojan TLS：WebSocket、HTTP/2、HTTPUpgrade

HTTP 类传输可以使用 sing-box 原生 TLS 或 Caddy 自动 HTTPS。Hysteria2、TUIC 和 VMess QUIC 使用原生 UDP/QUIC，不能放在普通 Caddy HTTP 反向代理后面。

## 安装

推荐使用一键安装命令（需要 `bash` 和 `wget`）：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/kukumi1/sing-box/main/install.sh)
```

脚本会自动检测 VPS 的公网 IPv4，并将其作为默认连接地址；直接回车即可采用，也可以输入其他 IP 或域名覆盖。随后脚本会下载最新 Release、验证 SHA-256 并执行完整安装。

Alpine 如果没有 Bash：

```sh
apk add --no-cache bash wget ca-certificates
bash <(wget -qO- https://raw.githubusercontent.com/kukumi1/sing-box/main/install.sh)
```

也可以使用无需 Bash 的非交互方式：

```sh
wget -qO- https://raw.githubusercontent.com/kukumi1/sing-box/main/install.sh | sh
```

使用 `curl`：

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/kukumi1/sing-box/main/install.sh)
```

传统 Git 安装方式仍然可用：

```sh
git clone https://github.com/kukumi1/sing-box.git
cd sing-box
sh install.sh --server-address 你的公网IP或域名
```

如果当前终端已经是 `root`，不要加 `sudo`。自动检测失败或需要指定入口域名时，可使用 `--server-address IP或域名`。菜单中的节点操作会自动列出所有节点，可直接输入序号选择，无需记住节点名称。安装器会在修改软件包前检查已有的非托管配置；只有确认自动备份无误后才应使用 `--force`。
## NAT 机器示例

假设服务商端口映射为：

```text
公网 23.134.212.11:64491
  -> 内网 10.10.1.134:30009
```

创建 AnyTLS 节点：

```sh
sb add anytls \
  --name tw-anytls \
  --listen-port 30009 \
  --public-address 23.134.212.11 \
  --public-port 64491
```

`--listen-port` 是服务器内部监听端口，`--public-port` 是 NAT 映射后的外部端口。生成的客户端链接会使用外部端口 `64491`。

端口映射要求：

- TCP：AnyTLS、VLESS REALITY、Trojan、普通 VMess/VLESS
- UDP：Hysteria2、TUIC、VMess QUIC
- TCP + UDP：需要 UDP 转发时的 SS2022 和 SOCKS5

管理器只能显示所需映射，不能自动操作服务商 NAT 面板、云安全组或外部 DNS API。

## 常用节点命令

```sh
sb                         # 打开交互菜单
sb add 协议 [参数]          # 添加节点
sb list                    # 查看节点
sb info 节点名             # 查看脱敏信息
sb info 节点名 --show-secrets
sb url 节点名              # 输出分享链接
sb qr 节点名               # 输出二维码
sb change 节点名 [参数]     # 修改节点
sb enable 节点名           # 启用节点
sb disable 节点名          # 禁用节点
sb rotate 节点名           # 重新生成凭据
sb delete 节点名 --yes      # 删除节点
sb export --all            # 导出全部节点
```

通用参数：

```text
--name NAME
--listen-address ADDRESS
--listen-port PORT
--public-address HOST
--public-port PORT
--username NAME
--password PASSWORD
```

高级参数：

```text
--transport tcp|ws|http|h2|httpupgrade|quic
--path /proxy
--host example.com
--tls-mode none|self-signed|trusted|caddy|acme
--cert /path/to/fullchain.pem
--key /path/to/private.key
--acme-email admin@example.com
--ss-method 2022-blake3-aes-128-gcm
--reality-server www.microsoft.com
--reality-port 443
--obfs-password PASSWORD
```

## 创建节点示例

```sh
sb add hysteria2 \
  --name hy2-main \
  --listen-port 30011 \
  --public-address hy2.example.com \
  --public-port 64493

sb add tuic \
  --name tuic-main \
  --listen-port 30012 \
  --public-port 64494

sb add vmess \
  --name vmess-ws \
  --listen-port 10001 \
  --public-address proxy.example.com \
  --public-port 443 \
  --transport ws \
  --path /vmess \
  --tls-mode caddy

sb add vless-tls \
  --name vless-h2 \
  --listen-port 10002 \
  --public-address proxy.example.com \
  --public-port 443 \
  --transport h2 \
  --path /vless \
  --tls-mode caddy

sb add anytls \
  --name anytls-acme \
  --listen-port 443 \
  --public-address anytls.example.com \
  --tls-mode acme \
  --acme-email admin@example.com
```

AnyTLS ACME 会根据 sing-box 版本自动生成兼容配置：1.12/1.13 使用旧版 `tls.acme`，1.14+ 使用 `certificate_provider`。

## Caddy

```sh
sb caddy sync
sb caddy status
sb caddy log
```

使用 `--tls-mode caddy` 添加节点时，管理器会按需安装 Caddy、创建基于路径的反向代理、验证 Caddyfile 并重载服务。多个 HTTP 节点可以在路径不重复时共用同一个域名和公网 443 端口。

Caddy 自动 HTTPS 要求公网 80/443 可访问，且 A/AAAA 记录正确。Caddy 不用于 Hysteria2、TUIC、VMess QUIC、AnyTLS、REALITY、SS2022 或 SOCKS5。

## 服务与诊断

```sh
sb start
sb stop
sb restart
sb status
sb check
sb log 200
sb doctor
sb dns
```

管理器使用独立的 `sb-sing-box` 服务，不会覆盖发行版自带的 `sing-box` 服务文件。`sb doctor` 会检查系统和 sing-box 版本、服务与配置状态、节点监听和公网映射、TCP/UDP 要求、DNS 解析及防火墙规则。

## 动态端口转发

进入中文菜单后选择：

```text
17) 动态端口转发
```

支持添加、查看、修改、启用、禁用、删除、立即同步和状态检查。目标可以是 IPv4 或动态解析域名；管理器每 5 分钟重新解析一次，IP 发生变化时自动重建受管规则。DNS 临时失败时继续使用上一次有效 IP。

现有规则可以直接修改本机端口、目标域名/IP、目标端口和协议，无需删除后重新创建。交互菜单选择“修改转发规则”后，留空的项目保持原值。

命令行示例：

```sh
sb forward add \
  --name game-forward \
  --listen-port 30009 \
  --target-host sn.11451.419198.xyz \
  --target-port 30009 \
  --protocol both

sb forward list
sb forward change game-forward \
  --listen-port 30010 \
  --target-host new.example.com \
  --target-port 30010 \
  --protocol both
sb forward status
sb forward sync
sb forward disable game-forward
sb forward enable game-forward
sb forward delete game-forward
```

实现约束：

- oth 表示同时转发 TCP 和 UDP。
- 默认使用 iptables；若 Debian/Ubuntu 容器未获 CAP_NET_ADMIN，会自动改用开机自启的 socat 用户态中继。
- 使用独立的 `SB_DNAT`、`SB_SNAT`、`SB_FORWARD` 链，不清空其他防火墙规则。
- iptables 后端自动启用 `net.ipv4.ip_forward=1`，配置文件为 `/etc/sysctl.d/99-sb-forward.conf`。
- Alpine 使用 OpenRC + crond；Debian/Ubuntu 使用 systemd timer。socat 回退后端目前需要 Debian/Ubuntu 的 systemd。
- 配置保存在 `/etc/sing-box/forwards/`，并包含在备份、恢复和快照中。
- 本功能只管理服务器内部端口转发；服务商 NAT 面板中的公网端口映射仍需单独配置。
## BBR

```sh
sb bbr status
sb bbr enable
sb bbr disable
```

管理器只维护 `/etc/sysctl.d/99-sb-bbr.conf`，不会重写其他全局 sysctl 配置。

## 备份、快照与回滚

```sh
sb snapshot
sb rollback RELEASE_ID
sb backup
sb backup /root/my-sb-backup.tar.gz
sb restore /root/my-sb-backup.tar.gz
```

备份包含节点密码和私钥，并使用 `0600` 权限保存。恢复前会检查 SHA-256、归档布局、路径穿越、链接和特殊文件，并先验证 sing-box 配置和创建恢复前快照。

## 迁移旧配置

```sh
sb migrate /path/to/legacy-config.json \
  --name imported-node \
  --public-address 你的公网IP \
  --public-port 公网端口
```

支持迁移 AnyTLS、Shadowsocks 2022、SOCKS5 和 VLESS + REALITY。迁移 REALITY 时必须显式提供客户端公钥：

```text
--reality-public-key PUBLIC_KEY
```

## 更新与回滚

```sh
sb update manager
sb manager-rollback
sb core status
sb core update
sb core rollback
```

管理器更新使用带 SHA-256 校验的 GitHub Release 文件并保留本地回滚副本。核心更新会备份旧二进制、检查所有启用配置并验证服务，失败时自动恢复。

## 卸载

```sh
sb uninstall
sb uninstall --purge --remove-core --yes
```

默认卸载会保留 `/etc/sing-box`；`--purge` 会删除配置、密钥、快照和备份；`--remove-core` 还会卸载 sing-box 软件包。

## 安全提示

- `sb info` 默认隐藏密码、UUID 和私钥。
- 只在私密终端中使用 `--show-secrets`。`qrencode` 会随安装器自动安装，可在菜单中直接显示节点二维码。
- SOCKS5 身份认证不会加密流量。
- 正式部署优先使用可信证书，不建议长期使用 `insecure=1`。
- 以 root 运行脚本前，应先检查脚本和 Release 校验值。
