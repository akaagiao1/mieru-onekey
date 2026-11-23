#!/usr/bin/env bash
# mieru 一键脚本：官方 mita，明文模式（模式 2 TLS / 模式 3 REALITY 已按用户要求去掉）
#
# 官方 mieru/mita「Does not use TLS protocol. No need to register a domain
#   name」——本脚本只装官方 mita，不装 mihomo，不做 TLS / REALITY。
# - 用户名/密码绝不用示例里的 name/pwd；未指定则随机生成强密码。
# - 客户端凭据只保存在 /root/mieru-client.txt，勿公开分享。
# - 端口运行可选：有终端时安装前会问端口，回车用默认 8964；
#   已用 --port / MIERU_PORT 显式指定时不再问；管道/非终端时沿用默认，不卡住。
# - Alpine 也支持：mita 是静态链接二进制，musl 上能直接跑；脚本从 deb 里只取
#   二进制（不装 dpkg），服务改走 OpenRC。Alpine 上先装 bash 再跑脚本：
#   apk add --no-cache bash curl && bash mieru-onekey.sh install
#
# 用法：
#   bash mieru-onekey.sh install
#   bash mieru-onekey.sh install --port 8964 --user alice --password '你的强密码'
#   MIERU_PORT=21000 bash mieru-onekey.sh install
#   bash mieru-onekey.sh install --no-ask-port   # 有终端也不问，直接用默认/指定端口
#   bash mieru-onekey.sh show | status | restart | uninstall | update | help
#   MIERU_DRY_RUN=1 bash mieru-onekey.sh install   # 不装机，只生成配置自检
#
set -Eeuo pipefail

VERSION="1.2.0"
MITA_VERSION="${MIERU_VERSION:-3.39.0}"
DRY_RUN="${MIERU_DRY_RUN:-0}"
STATE_DIR="${MIERU_STATE_DIR:-/root/.mieru-onekey}"
CLIENT_FILE="${MIERU_CLIENT_FILE:-/root/mieru-client.txt}"

die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf '[注意] %s\n' "$*" >&2; }

# ---------- 工具 ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "需要 $1，请先安装。"; }

rand_pass() { # 20 位字母数字
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20; printf '\n'
}
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1025 && $1 <= 65535 )); }
valid_name() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]; }
valid_pass() { [[ $1 =~ ^[A-Za-z0-9_!@#%^*+=.-]{8,64}$ ]]; }
valid_host() {
  # 拒绝占位域名 example.com/org/net 及其子域；IP 或其他真实域名均可
  [[ -n $1 ]] || return 1
  case "$1" in
    example.com|example.org|example.net|*.example.com|*.example.org|*.example.net) return 1 ;;
  esac
  [[ $1 == *.* || $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
is_cf_port() {
  case "$1" in
    80|8080|8880|2052|2082|2086|2095|2053|2083|2087|2096|8443) return 0 ;;
    *) return 1 ;;
  esac
}
public_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 8 https://ifconfig.me 2>/dev/null | tr -d ' \r\n')" || true
  [[ -n $ip ]] || ip="$(curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n')" || true
  printf '%s' "$ip"
}
os_id() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  else
    printf 'unknown'
  fi
}
arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "不支持的架构：$(uname -m)，仅 amd64/arm64。" ;;
  esac
}

# ---------- 参数 ----------
CMD="${1:-install}"
if [[ $CMD == --help || $CMD == -h || $CMD == help ]]; then
  printf 'mieru-onekey %s\n' "$VERSION"
  sed -n '2,20p' "$0"
  printf '\n子命令：install | show | status | restart | uninstall | update\n'
  printf '端口：运行有终端时会问端口，回车用默认 8964；--port / MIERU_PORT 指定后不再问；\n'
  printf '      --no-ask-port 有终端也不问；MIERU_ASK_PORT=1 可在管道测试时强制提问。\n'
  printf '环境变量：MIERU_USER / MIERU_PASS / MIERU_PORT / MIERU_HOST / MIERU_TAG / MIERU_VERSION / MIERU_DRY_RUN\n'
  exit 0
fi
shift || true

PORT="${MIERU_PORT:-8964}"
PORT_EXPLICIT=0
[[ -n ${MIERU_PORT:-} ]] && PORT_EXPLICIT=1
ASK_PORT=1
[[ ${MIERU_ASK_PORT:-} == 0 ]] && ASK_PORT=0
USER_NAME="${MIERU_USER:-}"
USER_PASS="${MIERU_PASS:-}"
HOST="${MIERU_HOST:-}"
TAG="${MIERU_TAG:-}"

while (( $# )); do
  case "$1" in
    --mode|--modes)
      [[ $2 == 1 ]] || die "模式 2/3 已去掉，本脚本只支持模式 1 明文（--mode 1）。"
      shift 2 ;;
    --port) PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --password) USER_PASS="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --ask-port) ASK_PORT=1; shift ;;
    --no-ask-port) ASK_PORT=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --tls-port|--reality-port|--tls-host|--reality-sni|--tls-cert|--tls-key)
      die "该参数属于已去掉的模式 2/3：$1，本脚本只支持模式 1 明文。" ;;
    --help|-h) bash "$0" help; exit 0 ;;
    *) die "未知参数：$1，用 bash $0 help 查看用法。" ;;
  esac
done

# ---------- 交互选端口 ----------
# 有终端才问；显式指定过端口或 --no-ask-port 时不问；管道时不问、不卡住。
# MIERU_ASK_PORT=1 可在管道里强制提问（便于测试）。
ask_port() {
  local input="" attempts=0
  [[ $ASK_PORT == 1 ]] || return 0
  [[ $PORT_EXPLICIT == 1 ]] && return 0
  if [[ ! -t 0 && ${MIERU_ASK_PORT:-0} != 1 ]]; then return 0; fi
  while (( attempts < 3 )); do
    printf 'mieru 端口 [默认 %s]，回车用默认，或输入新端口（1025-65535）：' "$PORT"
    if ! IFS= read -r input; then printf '\n'; return 0; fi
    input="$(printf '%s' "$input" | tr -d ' \t\r\n')"
    [[ -z $input ]] && return 0
    if ! valid_port "$input"; then
      warn "端口无效：$input，须为 1025-65535。"
      attempts=$((attempts + 1)); continue
    fi
    if is_cf_port "$input"; then
      warn "端口 $input 是 Cloudflare 反代端口，直连 IP 时不建议用。"
    fi
    if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":${input} "; then
      warn "端口 $input 已被本机占用，请换一个。"
      attempts=$((attempts + 1)); continue
    fi
    PORT="$input"
    return 0
  done
  warn "连续 3 次输入无效，沿用默认端口 $PORT。"
}

# ---------- 校验（装机前全部拦下，不装一半才报错） ----------
validate() {
  valid_port "$PORT" || die "端口非法：$PORT，须为 1025-65535。"
  if is_cf_port "$PORT"; then
    warn "端口 $PORT 是 Cloudflare 反代端口，客户端直连 IP 时不建议用，仍继续请确认无 CF 在中间。"
  fi
  if [[ -n $USER_NAME ]]; then valid_name "$USER_NAME" || die "用户名非法：只允许字母数字 _ . -，1-64 位。"; fi
  if [[ -n $USER_PASS ]]; then valid_pass "$USER_PASS" || die "密码非法：8-64 位，只允许字母数字与 _ ! @ # % ^ * + = . -。"; fi
  if [[ -n $HOST ]]; then valid_host "$HOST" || die "HOST 非法：$HOST，example.com 这类占位域名会被直接拒绝。"; fi
}

# ---------- 生成 mita 配置（python 写 JSON，避免手拼引号转义） ----------
write_mita_config() { # $1=输出路径 $2=端口 $3=用户名 $4=密码
  local out="$1" port="$2" user="$3" pass="$4"
  python3 - "$out" "$port" "$user" "$pass" <<'PY'
import json, sys
out, port, user, password = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
cfg = {
    "portBindings": [
        {"port": port, "protocol": "TCP"},
        {"port": port, "protocol": "UDP"},
    ],
    "users": [{"name": user, "password": password}],
    "loggingLevel": "INFO",
    "mtu": 1400,
    "dns": {"dualStack": "PREFER_IPv4"},
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=4)
PY
  python3 -m json.tool "$out" >/dev/null || die "mita 配置 JSON 生成失败：$out"
}

# ---------- Alpine 依赖与服务 ----------
install_alpine_deps() {
  # Alpine 自带 busybox tar 解不了 deb 里 data.tar.xz（缺 xz/ar），补 GNU tar/xz/binutils；
  # 基础工具缺失时也一并补上。
  info "Alpine：安装解包与运行依赖（tar/xz/binutils）..."
  apk add --no-cache tar xz binutils || die "apk 安装依赖失败。"
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  command -v ss >/dev/null 2>&1 || pkgs+=(iproute2)
  if (( ${#pkgs[@]} )); then
    apk add --no-cache "${pkgs[@]}" || die "apk 安装依赖失败：${pkgs[*]}"
  fi
}

install_alpine_service() {
  # 照抄 deb 的 systemd 服务含义：mita run 前台跑，mita 用户，/run/mita 归 mita 所有；
  # 只是 init 从 systemd 换成 OpenRC。
  cat > /etc/init.d/mita <<'INIT'
#!/sbin/openrc-run
name="mita"
description="Mieru proxy server"
command="/usr/bin/mita"
command_args="run"
command_user="mita:mita"
pidfile="/run/mita/mita.pid"
command_background=true
start_pre() {
    mkdir -p /run/mita
    chown mita:mita /run/mita
    chmod 775 /run/mita
}
depend() {
    need net
    after firewall
}
INIT
  chmod +x /etc/init.d/mita
  rc-update add mita default >/dev/null 2>&1 || warn "rc-update add mita default 失败，开机自启可能未生效，请手动检查。"
}

# ---------- 安装 ----------
do_install() {
  local arch; arch="$(arch_name)"
  local os; os="$(os_id)"
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] 不装机、不联网下载，只生成配置自检。"
  else
    [[ $(id -u) == 0 ]] || die "请以 root 运行此脚本（dry-run 除外）。"
    [[ $(uname -s) == Linux ]] || die "需要 Linux（Debian / Ubuntu / RHEL 系 / Alpine）。"
    if [[ $os == alpine ]]; then
      install_alpine_deps
    fi
  fi
  ask_port
  validate
  need_cmd curl; need_cmd python3; need_cmd openssl

  # 用户名/密码：没给就生成，绝不回退到 name/pwd
  if [[ -z $USER_NAME ]]; then USER_NAME="mieru"; fi
  if [[ -z $USER_PASS ]]; then USER_PASS="$(rand_pass)"; info "已随机生成密码（见客户端文件，勿外发）。"; fi
  if [[ -z $HOST ]]; then
    if [[ $DRY_RUN == 1 ]]; then HOST="203.0.113.10"
    else
      HOST="$(public_ip)"
      [[ -n $HOST ]] || die "探测不到本机公网 IP，请用 --host IP或域名 指定。"
    fi
  fi
  local tag_base="${TAG:-mieru}"
  # arch/os 已在 do_install 开头探测（Alpine 依赖安装需要先知道 os）

  # 时间同步提醒：mieru 密钥由用户名+密码+系统时间推导，时钟偏差大直接连不上
  if command -v timedatectl >/dev/null 2>&1 && [[ $DRY_RUN != 1 ]]; then
    timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -qx "yes" \
      || warn "系统时间可能未同步（timedatectl NTPSynchronized != yes），mieru 对时钟敏感，请先确认 NTP。"
  fi

  # workdir 故意不用 local：trap 在 EXIT 时才跑，局部变量那时已失效，set -u 下会报 unbound variable（2026-11-23 HKG1 实测）
  workdir=""
  if [[ $DRY_RUN == 1 ]]; then
    workdir="${MIERU_DRYRUN_DIR:-/tmp/mieru-dryrun}"
    mkdir -p "$workdir"
  else
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/mieru-onekey.XXXXXXXX")" || die "无法创建临时目录。"
    trap 'rm -rf -- "${workdir:-}"' EXIT
  fi

  info "安装 mita $MITA_VERSION（$os/$arch），端口 $PORT..."
  if [[ $DRY_RUN == 1 ]]; then
    write_mita_config "$workdir/mita-plain.json" "$PORT" "$USER_NAME" "$USER_PASS"
    info "[dry-run] mita 配置已写 $workdir/mita-plain.json，JSON 校验通过。"
  else
    case "$os" in
      debian|ubuntu)
        local deb="mita_${MITA_VERSION}_${arch}.deb"
        curl -fSsL --retry 3 --connect-timeout 15 -o "$workdir/$deb" \
          "https://github.com/enfein/mieru/releases/download/v${MITA_VERSION}/${deb}" \
          || die "mita 下载失败：请检查版本号 $MITA_VERSION 与网络。"
        dpkg -i "$workdir/$deb" || apt-get install -f -y || die "mita 安装失败（dpkg）。"
        ;;
      fedora|centos|rhel|rocky|almalinux)
        local rpm_arch="x86_64"; [[ $arch == arm64 ]] && rpm_arch="aarch64"
        local rpm="mita-${MITA_VERSION}-1.${rpm_arch}.rpm"
        curl -fSsL --retry 3 --connect-timeout 15 -o "$workdir/$rpm" \
          "https://github.com/enfein/mieru/releases/download/v${MITA_VERSION}/${rpm}" \
          || die "mita 下载失败：请检查版本号 $MITA_VERSION 与网络。"
        rpm -Uvh --force "$workdir/$rpm" || die "mita 安装失败（rpm）。"
        ;;
      alpine)
        local deb="mita_${MITA_VERSION}_${arch}.deb"
        curl -fSsL --retry 3 --connect-timeout 15 -o "$workdir/$deb" \
          "https://github.com/enfein/mieru/releases/download/v${MITA_VERSION}/${deb}" \
          || die "mita 下载失败：请检查版本号 $MITA_VERSION 与网络。"
        # mita 是静态链接二进制，musl 的 Alpine 能直接跑；deb 里只有二进制与
        # systemd 服务文件，这里只取二进制，服务改走 OpenRC。
        (cd "$workdir" && ar x "$deb" data.tar.xz && tar -xf data.tar.xz ./usr/bin/mita) \
          || die "mita 解包失败（ar/tar）。"
        install -m 0755 "$workdir/usr/bin/mita" /usr/bin/mita
        # 照抄 deb postinst：建 mita 用户与目录（Alpine 用 addgroup/adduser）
        if ! id mita >/dev/null 2>&1; then
          addgroup -S mita && adduser -S -G mita -H -s /sbin/nologin mita \
            || die "创建 mita 用户失败。"
        fi
        mkdir -p /etc/mita /var/lib/mita /var/run/mita
        chown -R mita:mita /etc/mita /var/lib/mita /var/run/mita
        chmod 775 /etc/mita /var/lib/mita /var/run/mita
        install_alpine_service
        ;;
      *) die "不支持的系统：$os，仅 Debian/Ubuntu/RHEL 系与 Alpine（mita 只提供 deb/rpm，Alpine 用 deb 解包）。" ;;
    esac
    command -v mita >/dev/null 2>&1 || die "mita 未装上（PATH 里找不到 mita）。"
    write_mita_config "$workdir/mita-plain.json" "$PORT" "$USER_NAME" "$USER_PASS"
    if [[ $os == alpine ]]; then
      # Alpine 顺序不能照搬 Debian：mita apply config 要走 /run/mita/mita.sock，
      # 守护进程没跑时直接报错；新装的守护进程先是 IDLE（不监听），apply 之后
      # 必须再 mita start 才会切到 RUNNING 并监听（2026-11-23 xiaoyin 实测）。
      rc-service mita start >/dev/null 2>&1 || true
      mita stop >/dev/null 2>&1 || true
      mita apply config "$workdir/mita-plain.json" || die "mita apply config 失败，请看上方报错改配置。"
      mita start || die "mita start 失败。"
    else
      mita stop >/dev/null 2>&1 || true
      mita apply config "$workdir/mita-plain.json" || die "mita apply config 失败，请看上方报错改配置。"
      mita start || die "mita start 失败。"
    fi
    sleep 2
    mita status | grep -q 'RUNNING' || die "mita 未进入 RUNNING：$(mita status 2>&1 | head -5)"
    info "mita 已 RUNNING，端口 $PORT（TCP+UDP）。"
  fi

  # ---- 输出客户端配置 ----
  if [[ $DRY_RUN == 1 ]]; then
    # dry-run 绝不碰 /root：客户端文件只写到 workdir
    CLIENT_FILE="$workdir/mieru-client.txt"
  fi
  mkdir -p "$(dirname "$CLIENT_FILE")" 2>/dev/null || true
  {
    printf '# mieru 客户端配置（%s）\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
    printf '# 服务端：%s\n' "$HOST"
    printf '# 凭据只在此文件，勿公开分享。\n\n'
    printf '## 明文（官方 mita，端口 %s）\n' "$PORT"
    printf 'mieru=%s:%s, username=%s, password=%s, fast-open=false, udp-relay=true, udp-over-tcp=true, tag=%s-01\n\n' \
      "$HOST" "$PORT" "$USER_NAME" "$USER_PASS" "$tag_base"
    printf '## 自查\n'
    printf '# mita status 应为 RUNNING；ss -tlnp | grep %s\n' "$PORT"
  } > "$CLIENT_FILE"
  chmod 600 "$CLIENT_FILE" || true
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] 客户端配置已写 $CLIENT_FILE。"
  fi
  if [[ $DRY_RUN != 1 ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    cat > "$STATE_DIR/state.env" <<EOF
HOST="$HOST"
USER_NAME="$USER_NAME"
PORT="$PORT"
TAG="$tag_base"
EOF
    chmod 600 "$STATE_DIR/state.env" || true
  fi
  info "完成。客户端配置：$CLIENT_FILE"
  cat "$CLIENT_FILE"
}

do_show() {
  [[ -f $CLIENT_FILE ]] || die "没有客户端文件：$CLIENT_FILE，先跑 install。"
  cat "$CLIENT_FILE"
}
do_status() {
  if command -v mita >/dev/null 2>&1; then mita status || true; else info "mita：未安装"; fi
  ss -tlnp 2>/dev/null | grep -E ":${PORT:-8964} " || true
}
do_restart() {
  if [[ -f /etc/init.d/mita ]] && command -v rc-service >/dev/null 2>&1; then
    rc-service mita restart; mita status
  elif command -v mita >/dev/null 2>&1; then mita stop; mita start; mita status; fi
  info "已重启。"
}
do_uninstall() {
  printf '将卸载 mita 并删除配置与客户端文件，输入 yes 确认：'
  local ans=""; read -r ans
  [[ $ans == yes ]] || die "已取消。"
  rm -rf "$STATE_DIR"
  command -v mita >/dev/null 2>&1 && { mita stop || true; }
  if command -v dpkg >/dev/null 2>&1; then dpkg -r mita 2>/dev/null || true; fi
  if command -v rpm >/dev/null 2>&1; then rpm -e mita 2>/dev/null || true; fi
  if [[ -f /etc/init.d/mita ]]; then
    rc-service mita stop >/dev/null 2>&1 || true
    rc-update del mita default >/dev/null 2>&1 || true
    rm -f /etc/init.d/mita /usr/bin/mita
    deluser mita >/dev/null 2>&1 || true
    rm -rf /etc/mita /var/lib/mita
  fi
  rm -f "$CLIENT_FILE"
  info "已卸载。"
}
do_update() {
  info "update：重新跑 install 会保留 /root/.mieru-onekey/state.env 里的用户与端口，只换版本。"
  warn "当前版本：mita $MITA_VERSION；改版请用 MIERU_VERSION=xxx 再跑 install。"
}

case "$CMD" in
  install) do_install ;;
  show) do_show ;;
  status) do_status ;;
  restart) do_restart ;;
  uninstall) do_uninstall ;;
  update) do_update ;;
  *) die "未知子命令：$CMD，用 bash $0 help 查看。" ;;
esac
