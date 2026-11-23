# mieru 一键脚本

一个脚本装好 mieru，输出可直接贴进 Quantumult X `[server_local]`。

只做一件事：官方 `mita`，明文模式。模式 2 TLS / 模式 3 REALITY 已按要求去掉——官方 `mita` 本来就没有 TLS / REALITY 配置项（文档原话 “Does not use TLS protocol”），那两路要靠第三方服务端终结，现在不要，就不装。

输出示例：

```ini
mieru=203.0.113.10:8964, username=alice, password=你的密码, fast-open=false, udp-relay=true, udp-over-tcp=true, tag=mieru-01
```

## 环境

- Debian / Ubuntu / RHEL 系（Fedora / CentOS / Rocky / Alma），amd64 / arm64，root 运行
- `mita` 只提供 deb / rpm，没有 Alpine 包
- 系统时间必须同步：mieru 密钥由用户名 + 密码 + 系统时间推导，时钟偏差大直接连不上。脚本会看 `timedatectl` 提醒，未同步请先修 NTP

## 端口：运行时选

装的时候会问端口，规则很简单：

```text
mieru 端口 [默认 8964]，回车用默认，或输入新端口（1025-65535）：
```

- 有终端时才问，回车就是默认 8964，输数字就用你输的
- 输错（比如 80、不是数字）会提示重输，最多 3 次，3 次都错就沿用默认，不会装一半卡住
- 输入的端口已被本机占用时也会提示换一个；是 Cloudflare 反代端口时会警告
- 已经用 `--port` 或 `MIERU_PORT` 指定了端口，就不再问
- `--no-ask-port`：有终端也不问，直接用默认 / 指定端口
- 管道执行（比如 `curl | bash`）时不问，沿用默认，不卡住

三种写法都行：

```bash
# 1. 运行时问你（推荐）
bash mieru-onekey.sh install

# 2. 命令行直接指定，不问
bash mieru-onekey.sh install --port 21000 --user alice --password '换成你的强密码'

# 3. 环境变量指定，不问
MIERU_PORT=21000 bash mieru-onekey.sh install
```

## 快速开始

```bash
# 只跑安装，端口现场选，用户/密码没给就默认 mieru + 随机密码
bash mieru-onekey.sh install

# 一次给全
bash mieru-onekey.sh install --port 21000 --user alice --password '换成你的强密码'
```

不填 `--host` 时自动探测公网 IP；也可以 `--host 你的域名或IP` 指定。`example.com` 这类占位域名会被直接拒绝；`name / pwd` 这类示例凭据也会被拒绝（密码须 8–64 位）。

装完客户端配置在 `/root/mieru-client.txt`（600 权限），同时打印到终端。管理命令：

```bash
bash mieru-onekey.sh show      # 再看一遍客户端配置
bash mieru-onekey.sh status    # mita status
bash mieru-onekey.sh restart
bash mieru-onekey.sh uninstall # 输入 yes 才执行
bash mieru-onekey.sh update    # 提示换版方式，配置与凭据保留
```

## 环境变量（与命令行参数等价）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `MIERU_PORT` | `8964` | 端口，1025–65535；指定后运行时不再问 |
| `MIERU_USER` / `MIERU_PASS` | 随机 | 未指定密码时随机生成 20 位 |
| `MIERU_HOST` | 自动探测 | 客户端填的地址，IP 或域名 |
| `MIERU_TAG` | `mieru` | 节点名前缀，输出为 `mieru-01` |
| `MIERU_VERSION` | `3.39.0` | mita 版本 |
| `MIERU_ASK_PORT` | 跟随终端 | 设为 `1` 可在管道测试时强制提问；`0` 不问 |
| `MIERU_DRY_RUN` | `0` | 设为 `1` 只生成配置自检，不装机、不下载 |

## 已验证

沙箱里已验证：

- `bash -n` 通过、`shellcheck -S warning` 零告警
- `MIERU_DRY_RUN=1` 下：非交互默认 8964；`MIERU_ASK_PORT=1` 喂 `21000` 得 21000；回车得默认；先输错 `80` 再输 `22000` 得 22000；显式 `--port 23000` 时喂 `9999` 也不会被改写
- mita JSON `python3 -m json.tool` 通过
- 拒绝项均生效：`--mode 2`、`--tls-port` 等模式 2/3 参数直接报错；`example.com`、弱密码、非法端口直接报错

沙箱里**没有**验证、须在真机上验证的：

1. VPS 上真装 `mita`，`mita status` 为 `RUNNING`，`ss -tlnp` 看到所选端口监听。
2. QuanX 导入输出行，真机连通、能打开网页、UDP（视频/通话）正常。

## 文件

- `mieru-onekey.sh`：唯一脚本，独立文件，未并入其他仓库
- 本目录即交付物；推 GitHub / 装到哪台 VPS，由你定，我再动手
