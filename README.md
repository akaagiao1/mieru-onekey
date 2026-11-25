# mieru-onekey

在 Linux VPS 上安装或升级代理内核。按你使用的客户端选择脚本。

| 客户端 | 代理内核 | 默认入站端口 | 快速入口 |
| --- | --- | --- | --- |
| Surge | Volto（MASQUE） | UDP `443` | [安装](#安装-volto) · [升级](#升级-volto) · [配置 Surge](#配置-surge) |
| Quantumult X | mieru（官方 `mita`） | TCP + UDP `8964` | [安装](#安装-mita) · [升级](#升级-mita) · [配置 Quantumult X](#配置-quantumult-x) |

## Volto 一键安装（Surge MASQUE）

适用于使用 systemd 的 Debian / Ubuntu VPS，支持 amd64 和 arm64。需要 `curl`、`tar`、`sha256sum`、`ssh-keygen` 和 `openssl`。交互检查端口及自动启用双栈还需要 `iproute2`。

### 安装 Volto

```bash
curl -fsSL https://raw.githubusercontent.com/akaagiao1/mieru-onekey/main/volto-onekey.sh -o volto-onekey.sh && sudo bash volto-onekey.sh
```

首次交互安装时选择 UDP 端口：

| 输入 | 结果 |
| --- | --- |
| 回车 | 使用 `443` |
| 输入端口 | 使用指定端口。若被占用，脚本会提示重选 |
| `r` | 在 `20000–29999` 中随机选择空闲端口 |

非交互安装默认使用 UDP `443`。也可以运行 `sudo bash volto-onekey.sh --port 2443 --username alice` 直接指定端口和用户名。默认用户名为 `surge`，安装器会生成随机密码和自签名证书。

首次安装时，具有全局 IPv6 地址且内核支持双栈的 VPS 会在同一个 UDP 端口监听 IPv4 和 IPv6。按实际采用的 IP 协议和端口放行安全组及防火墙的 UDP 入站。

### 升级 Volto

在已安装 Volto 的 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/akaagiao1/mieru-onekey/main/volto-onekey.sh -o volto-onekey.sh && sudo bash volto-onekey.sh update
```

默认选择上游最新正式版。升级沿用 `/etc/volto/config.toml` 中的端口、监听地址及认证配置，也沿用现有证书和客户端凭据。一键脚本会校验固定提交的上游安装器，再由上游安装器校验发布包签名及 SHA-256，并在更换内核前检查现有配置。新版本启动失败时会尝试回滚。

换版时上游安装器会刷新 `volto.service`，已有 systemd drop-in 配置会继续生效。

| 操作 | 命令 |
| --- | --- |
| 查看当前版本 | `volto --version` |
| 指定发布版本 | `sudo bash volto-onekey.sh update --tag v1.8.3` |
| 预演 | `sudo bash volto-onekey.sh update --dry-run --tag v1.8.3` |
| 启用每日更新 | `sudo bash volto-onekey.sh update --enable-timer` |
| 查看升级帮助 | `bash volto-onekey.sh update --help` |

[Volto 上游部署文档](https://github.com/vcarus/volto/blob/v1.8.3/docs/deployment.md#deploying-from-releases)

### 配置 Surge

1. 把安装终端输出中 `volto = masque, ...` 的整行粘贴到 Surge 配置的 `[Proxy]` 段。
2. 通过 IPv6 连接时，把节点行的服务器地址替换为客户端可达的 IPv6 地址，保留 `sni` 和证书 SHA-256 指纹。
3. 把 `volto` 加到使用的策略组并测试连通性。节点行含密码，请妥善保存。

需要 Surge iOS 5.22.0 或 macOS 6.9.0 及以上版本。[Surge MASQUE 文档](https://manual.nssurge.com/policies/masque.html)

## mieru 一键安装（Quantumult X）

适用于 Debian、Ubuntu、Fedora、CentOS、RHEL、Rocky、AlmaLinux 和 Alpine，支持 amd64 和 arm64。脚本使用官方 `mita` 协议，原生模式无需 TLS 或 REALITY。服务器需同步系统时间。

### 安装 mita

```bash
curl -fsSL https://raw.githubusercontent.com/akaagiao1/mieru-onekey/main/mieru-onekey.sh -o mieru-onekey.sh && sudo bash mieru-onekey.sh install
```

Alpine 上先以 root 执行 `apk add --no-cache bash curl`，然后运行上面的安装命令并省略 `sudo`。脚本会补齐解包依赖，提取官方静态二进制并注册 OpenRC 服务。

交互安装可设置 TCP + UDP 端口。回车或非交互运行时使用 `8964`。端口范围为 `1025–65535`，无效或占用的端口会提示重选，三次失败后回到默认值。显式设置 `--port`、`MIERU_PORT` 或使用 `--no-ask-port` 可跳过询问。

```bash
sudo bash mieru-onekey.sh install --port 21000 --user alice
```

默认用户名为 `mieru`。自定义密码须为 8–64 位，未指定时自动生成 20 位随机密码。未指定 `--host` 时会探测公网 IP，也可手动指定实际域名或 IP。

### 升级 mita

```bash
curl -fsSL https://raw.githubusercontent.com/akaagiao1/mieru-onekey/main/mieru-onekey.sh -o mieru-onekey.sh && sudo bash mieru-onekey.sh update
```

默认目标为 **mita 3.40.0**。升级校验官方二进制，保留服务端配置、`/root/.mieru-onekey/state.env` 和客户端文件。运行中的代理会短暂重启，验证失败会恢复旧内核。已停止或处于 `IDLE` 的代理保持原状态，下次启动或重启守护进程时加载新内核。

| 操作 | 命令 |
| --- | --- |
| 查看实际内核版本 | `mita version` |
| 指定目标版本 | `sudo env MIERU_VERSION=3.40.0 bash mieru-onekey.sh update` |
| 预演 | `sudo bash mieru-onekey.sh update --dry-run` |
| 查看状态 | `sudo bash mieru-onekey.sh status` |
| 重启代理 | `sudo bash mieru-onekey.sh restart` |
| 卸载 | `sudo bash mieru-onekey.sh uninstall`，输入 `yes` 确认 |

`update` 直接替换二进制，系统包管理器仍记录原安装包版本，后续安装系统包时可能覆盖该二进制。需要重新生成配置时可运行 `install`，状态文件里的账号、端口等设置会沿用，显式参数优先。例如，使用 `--password` 更换密码。

### 配置 Quantumult X

安装输出也保存在权限为 `600` 的 `/root/mieru-client.txt`，可用 `sudo bash mieru-onekey.sh show` 查看。将其中的节点行粘贴到 Quantumult X 的 `[server_local]` 段。

```ini
mieru=203.0.113.10:8964, username=alice, password=你的密码, fast-open=false, udp-relay=true, udp-over-tcp=true, tag=mieru-01
```

客户端配置会尝试根据服务器 IP 添加国家旗帜。需要明确指定时可传 `--country HK` 或设置 `MIERU_COUNTRY=HK`。

### mita 环境变量

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `MIERU_PORT` | `8964` | 服务端口，指定后跳过交互 |
| `MIERU_USER` / `MIERU_PASS` | `mieru` / 随机密码 | 客户端账号及密码 |
| `MIERU_HOST` | 自动探测 | 客户端连接的域名或 IP |
| `MIERU_TAG` | `mieru` | 客户端节点名称前缀 |
| `MIERU_COUNTRY` | 自动识别 | 两位 ISO 国家代码，如 `HK` |
| `MIERU_VERSION` | `3.40.0` | 安装或更新使用的 mita 版本 |
| `MIERU_ASK_PORT` | 跟随终端 | `1` 强制询问，`0` 跳过询问 |
| `MIERU_DRY_RUN` | `0` | `1` 预演安装或升级 |

## 验证

```bash
bash -n volto-onekey.sh && bash -n mieru-onekey.sh
python3 -B -m unittest discover -s tests -v
```

<details>
<summary>历史测试与版本记录</summary>

沙箱里已验证：

- `bash -n` 通过、`shellcheck -S warning` 零告警
- `MIERU_DRY_RUN=1` 下：非交互默认 8964；`MIERU_ASK_PORT=1` 喂 `21000` 得 21000；回车得默认；先输错 `80` 再输 `22000` 得 22000；显式 `--port 23000` 时喂 `9999` 也不会被改写
- mita JSON `python3 -m json.tool` 通过
- 拒绝项均生效：`--mode 2`、`--tls-port` 等模式 2/3 参数直接报错；`example.com`、弱密码、非法端口直接报错

真机已验证（2026-11-23）：

- Debian 13：HKG1、192196、195587、gia-186143、dv-ge、dv-la-9929、IEPL，8964，`mita status` 为 `RUNNING`，TCP+UDP 监听
- Alpine：xiaoyin（3.21）、dv-us-lite（3.24），8964，`RUNNING`，TCP+UDP 监听，OpenRC 服务已加进 default 运行级
- Alpine 坑点：`mita apply config` 要走 `/run/mita/mita.sock`，守护进程没跑时直接报错；新装的守护进程先是 `IDLE`（不监听），apply 之后必须再 `mita start` 才会切到 `RUNNING`。脚本已按 `rc-service mita start → mita stop → apply → mita start` 的顺序处理。
- v1.2.1 修复（2026-11-23）：重装不再悄悄换密码（沿用 `state.env`，旧版无密码时从客户端文件找回，xiaoyin 真机重装验证配置行哈希不变）；`--port` 等缺值时干净报错，不再 `unbound variable` 崩掉；`restart` 时守护进程未跑不再半路退出；端口占用检查补了 UDP；纯 IPv6 机器自动探测 IPv6、客户端行加方括号；删掉从没用过的 `openssl` 硬依赖；`update` 显示已装版本。arm64 的 deb 已核实存在且二进制同样静态链接。
- v1.2.2 国旗（2026-11-23）：`--country` / `MIERU_COUNTRY` 指定国家，tag 前缀与客户端文件时间后加国旗；不指定时按 IP 自动识别（ipinfo → ip-api）。GeoIP 可能不准：HKG1 的 IP 在 ip-api 里是 US、ipinfo 里是 HK，实际是香港，以 `--country HK` 为准；野草云两家分别是 SG / HK，城市信息显示香港，用 HK；IEPL 出口 IP 显示 HK，但那台是国内入口机，按 CN 钉死。

沙箱里**没有**验证、须在真机上验证的：

1. QuanX 导入输出行，真机连通、能打开网页、UDP（视频/通话）正常。

</details>
