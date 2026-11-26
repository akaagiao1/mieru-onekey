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
# - 重装沿用上次的用户/密码/端口/tag（存 /root/.mieru-onekey/state.env），
#   显式参数优先；只升级内核请用 update，保留现有配置文件。
# - 国旗：tag 前缀与客户端文件时间后都加国家符号（如 🇺🇸），方便筛选；
#   未指定时按本机 IP 自动识别（ipinfo → ip-api），识别不准时用 --country 指定。
#
# 用法：
#   bash mieru-onekey.sh install
#   bash mieru-onekey.sh install --port 8964 --user alice --password '你的强密码'
#   MIERU_PORT=21000 bash mieru-onekey.sh install
#   bash mieru-onekey.sh install --no-ask-port   # 有终端也不问，直接用默认/指定端口
#   bash mieru-onekey.sh update [--version 3.40.0|latest] [--dry-run]
#   bash mieru-onekey.sh show | status | restart | uninstall | update | help
#   MIERU_DRY_RUN=1 bash mieru-onekey.sh install   # 不装机，只生成配置自检
#
set -Eeuo pipefail

VERSION="1.2.4"
DEFAULT_MITA_VERSION="3.40.0"
MITA_VERSION="${MIERU_VERSION:-$DEFAULT_MITA_VERSION}"
VERSION_EXPLICIT=0
[[ -n ${MIERU_VERSION:-} ]] && VERSION_EXPLICIT=1
DRY_RUN="${MIERU_DRY_RUN:-0}"
STATE_DIR="${MIERU_STATE_DIR:-/root/.mieru-onekey}"
CLIENT_FILE="${MIERU_CLIENT_FILE:-/root/mieru-client.txt}"
LAST_MITA_STATUS=""

die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf '[注意] %s\n' "$*" >&2; }

show_help() {
  cat <<EOF
mieru-onekey ${VERSION}
官方 mita 一键安装与升级脚本（仅模式 1 明文，不装 mihomo，不做 TLS / REALITY）。

用法：
  bash mieru-onekey.sh install [--port 8964] [--user alice] [--password '强密码'] [--host IP/域名] [--tag 名称] [--country HK] [--version ${DEFAULT_MITA_VERSION}|latest]
  bash mieru-onekey.sh update [--version ${DEFAULT_MITA_VERSION}|latest] [--dry-run]
  bash mieru-onekey.sh show | status | restart | uninstall | help

子命令：install | show | status | restart | uninstall | update | help
更新：update 只替换 mita 内核并保留现有配置；可用 --version 或 MIERU_VERSION 指定版本（如 ${DEFAULT_MITA_VERSION} 或 latest），--dry-run 预览。
端口：运行有终端时会问端口，回车用默认 8964；--port / MIERU_PORT 指定后不再问；
      --no-ask-port 有终端也不问；MIERU_ASK_PORT=1 可在管道测试时强制提问。
环境变量：MIERU_USER / MIERU_PASS / MIERU_PORT / MIERU_HOST / MIERU_TAG / MIERU_COUNTRY / MIERU_VERSION / MIERU_DRY_RUN
国旗：--country US（2 位代码）指定国家，tag 前缀与客户端文件时间后加国旗；不指定时按 IP 自动识别。
EOF
}

# ---------- 工具 ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "需要 $1，请先安装。"; }

to_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

need_sha256() {
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
    die "需要 sha256sum（或 shasum），请先安装。"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    die "需要 sha256sum（或 shasum），请先安装。"
  fi
}

verify_sha256_file() { # $1=文件路径 $2=上游 .sha256.txt 路径
  local target="$1" checksum_file="$2" expected actual
  expected=$(tr -d '\r' < "$checksum_file" | awk 'NR == 1 { print $1; exit }')
  [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die "上游 SHA-256 校验文件格式错误。"
  actual=$(sha256_file "$target") || die "无法计算文件 SHA-256：${target}。"
  [[ $(to_lower "$actual") == "$(to_lower "$expected")" ]] || die "SHA-256 校验失败（期望 ${expected}，实际 ${actual}）。"
}

version_ge() { # $1 >= $2（x.y.z 数值比较，不依赖 sort -V，兼容 Alpine BusyBox）
  local -a a b
  local IFS=. i x y
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2; do
    x=$(( 10#${a[$i]:-0} ))
    y=$(( 10#${b[$i]:-0} ))
    if (( x > y )); then return 0; fi
    if (( x < y )); then return 1; fi
  done
  return 0
}

resolve_latest_mita_version() {
  local location tag
  need_cmd curl
  location=$(curl --proto '=https' -fsSLI --retry 3 --connect-timeout 10 --max-time 30 \
    -o /dev/null -w '%{url_effective}' "https://github.com/enfein/mieru/releases/latest") ||
    die "无法访问 GitHub 解析最新 mita 版本，请指定具体版本号（如 --version ${DEFAULT_MITA_VERSION}）。"
  tag="${location##*/}"
  tag="${tag#v}"
  [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "解析到的最新 mita 版本格式无效：${location}"
  printf '%s\n' "$tag"
}

normalize_mita_version() { # 允许可选前缀 v 或 latest；设置 MITA_VERSION
  local raw="${MITA_VERSION}"
  if [[ $raw == latest ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      die "--dry-run 不联网解析 latest，请指定具体版本号（如 --version ${DEFAULT_MITA_VERSION}）。"
    fi
    MITA_VERSION="$(resolve_latest_mita_version)"
    # latest 自动解析结果视作非显式降级目标，防止远端回退导致意外降级
    VERSION_EXPLICIT=0
    return 0
  fi
  raw="${raw#v}"
  [[ $raw =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "内核版本无效：${MITA_VERSION}（格式为 x.y.z，或 latest）。"
  MITA_VERSION="$raw"
}

rand_pass() { # 20 位字母数字（避免 tr|head 在 pipefail 下的 SIGPIPE 与 macOS locale 报错）
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets, string; a = string.ascii_letters + string.digits; print(''.join(secrets.choice(a) for _ in range(20)))"
    return
  fi
  local out="" chunk=""
  while (( ${#out} < 20 )); do
    chunk=$(LC_ALL=C dd if=/dev/urandom bs=64 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9') || true
    out+="$chunk"
  done
  printf '%s\n' "${out:0:20}"
}
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1025 && 10#$1 <= 65535 )); }
valid_name() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]; }
valid_pass() { [[ $1 =~ ^[A-Za-z0-9_!@#%^*+=.-]{8,64}$ ]]; }
valid_host() {
  # 拒绝占位域名 example.com/org/net 及其子域；IPv4、IPv6 或其他真实域名均可
  [[ -n $1 ]] || return 1
  case "$1" in
    example.com|example.org|example.net|*.example.com|*.example.org|*.example.net) return 1 ;;
  esac
  # 已加方括号的 IPv6
  [[ $1 =~ ^\[[0-9a-fA-F:]+\]$ ]] && return 0
  # 裸 IPv6（含 :，无点）
  [[ $1 == *:* && $1 != *.* ]] && [[ $1 =~ ^[0-9a-fA-F:]+$ ]] && return 0
  [[ $1 == *.* || $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
fmt_host() { # 客户端行里的 host：裸 IPv6 加方括号，其余原样
  if [[ $1 == *:* && $1 != \[* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}
country_flag() { # 国家代码（US）→ 国旗（🇺🇸），区域指示符拼出来
  python3 -c "import sys; print(''.join(chr(0x1F1E6 + ord(c) - 65) for c in sys.argv[1]))" "$1" 2>/dev/null || printf '%s' "$1"
}
detect_country() { # 按 IP 自动识别国家代码（$1=IP）；识别不到返回空串
  local ip="$1" code=""
  # 只认 IP（IPv4 或含 : 的 IPv6），不认域名
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $ip == *:* ]] || return 0
  code="$(curl -fsSL --max-time 8 "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d ' \r\n')" || true
  if [[ ! $code =~ ^[A-Za-z]{2}$ ]]; then
    # ipinfo 不行再试 ip-api（免费版只支持 http）
    code="$(curl -fsSL --max-time 8 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d ' \r\n')" || true
  fi
  if [[ $code =~ ^[A-Za-z]{2}$ ]]; then
    to_upper "$code"
  fi
}
is_cf_port() {
  case "$1" in
    80|8080|8880|2052|2082|2086|2095|2053|2083|2087|2096|8443) return 0 ;;
    *) return 1 ;;
  esac
}
port_in_use() { # 检查本机 TCP 或 UDP 端口是否已监听（避免 pipe 到 grep -q 的 SIGPIPE）
  local port="$1" out=""
  command -v ss >/dev/null 2>&1 || return 1
  if out=$(ss -H -tln "sport = :${port}" 2>/dev/null) && [[ -n $out ]]; then return 0; fi
  if out=$(ss -H -uln "sport = :${port}" 2>/dev/null) && [[ -n $out ]]; then return 0; fi
  return 1
}
public_ip() {
  # 先 IPv4，纯 IPv6 的机器再试 IPv6
  local ip=""
  ip="$(curl -4fsSL --max-time 8 https://ifconfig.me 2>/dev/null | tr -d ' \r\n')" || true
  [[ -n $ip ]] || ip="$(curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n')" || true
  [[ -n $ip ]] || ip="$(curl -6fsSL --max-time 8 https://ifconfig.me 2>/dev/null | tr -d ' \r\n')" || true
  [[ -n $ip ]] || ip="$(curl -6fsSL --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n')" || true
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
os_id_like() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID_LIKE:-}"
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
  show_help
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
USER_EXPLICIT=0
PASS_EXPLICIT=0
HOST_EXPLICIT=0
TAG_EXPLICIT=0
COUNTRY_EXPLICIT=0
[[ -n ${MIERU_USER:-} ]] && USER_EXPLICIT=1
[[ -n ${MIERU_PASS:-} ]] && PASS_EXPLICIT=1
[[ -n ${MIERU_HOST:-} ]] && HOST_EXPLICIT=1
[[ -n ${MIERU_TAG:-} ]] && TAG_EXPLICIT=1
COUNTRY="${MIERU_COUNTRY:-}"
[[ -n ${MIERU_COUNTRY:-} ]] && COUNTRY_EXPLICIT=1

while (( $# )); do
  if [[ $CMD == update && $1 != --dry-run && $1 != --version && $1 != --help && $1 != -h ]]; then
    die "update 不接受 $1。请用 --version 或 MIERU_VERSION 指定内核版本。"
  fi
  case "$1" in
    --mode|--modes)
      [[ $# -ge 2 ]] || die "缺少参数值：--mode"
      [[ $2 == 1 ]] || die "模式 2/3 已去掉，本脚本只支持模式 1 明文（--mode 1）。"
      shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "缺少参数值：--port"; PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    --user) [[ $# -ge 2 ]] || die "缺少参数值：--user"; USER_NAME="$2"; USER_EXPLICIT=1; shift 2 ;;
    --password) [[ $# -ge 2 ]] || die "缺少参数值：--password"; USER_PASS="$2"; PASS_EXPLICIT=1; shift 2 ;;
    --host) [[ $# -ge 2 ]] || die "缺少参数值：--host"; HOST="$2"; HOST_EXPLICIT=1; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || die "缺少参数值：--tag"; TAG="$2"; TAG_EXPLICIT=1; shift 2 ;;
    --country) [[ $# -ge 2 ]] || die "缺少参数值：--country"; COUNTRY="$2"; COUNTRY_EXPLICIT=1; shift 2 ;;
    --version) [[ $# -ge 2 && -n $2 ]] || die "缺少参数值：--version"; MITA_VERSION="$2"; VERSION_EXPLICIT=1; shift 2 ;;
    --ask-port) ASK_PORT=1; shift ;;
    --no-ask-port) ASK_PORT=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --tls-port|--reality-port|--tls-host|--reality-sni|--tls-cert|--tls-key)
      die "该参数属于已去掉的模式 2/3：$1，本脚本只支持模式 1 明文。" ;;
    --help|-h) show_help; exit 0 ;;
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
      warn "端口无效：${input}，须为 1025-65535。"
      attempts=$((attempts + 1)); continue
    fi
    input=$(( 10#$input ))
    if is_cf_port "$input"; then
      warn "端口 $input 是 Cloudflare 反代端口，直连 IP 时不建议用。"
    fi
    # mita 同时绑 TCP+UDP，只查 TCP 会漏掉只占 UDP 的情况
    if port_in_use "$input"; then
      warn "端口 $input 已被本机占用，请换一个。"
      attempts=$((attempts + 1)); continue
    fi
    PORT="$input"
    return 0
  done
  warn "连续 3 次输入无效，沿用默认端口 ${PORT}。"
}

# ---------- 校验（装机前全部拦下，不装一半才报错） ----------
validate() {
  valid_port "$PORT" || die "端口非法：${PORT}，须为 1025-65535。"
  PORT=$(( 10#$PORT ))
  if is_cf_port "$PORT"; then
    warn "端口 $PORT 是 Cloudflare 反代端口，客户端直连 IP 时不建议用，仍继续请确认无 CF 在中间。"
  fi
  if [[ -n $USER_NAME ]]; then valid_name "$USER_NAME" || die "用户名非法：只允许字母数字 _ . -，1-64 位。"; fi
  if [[ -n $USER_PASS ]]; then valid_pass "$USER_PASS" || die "密码非法：8-64 位，只允许字母数字与 _ ! @ # % ^ * + = . -。"; fi
  if [[ -n $HOST ]]; then valid_host "$HOST" || die "HOST 非法：${HOST}，example.com 这类占位域名会被直接拒绝。"; fi
  if [[ -n $COUNTRY ]]; then
    [[ $COUNTRY =~ ^[A-Za-z]{2}$ ]] || die "国家代码非法：${COUNTRY}，须为 2 位 ISO 代码，如 US / DE / HK。"
    COUNTRY="$(to_upper "$COUNTRY")"
  fi
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

# ---------- mita 版本与状态探测 ----------
mita_binary_version() {
  local output
  output=$("$1" version 2>&1) || return 1
  output="${output//$'\r'/}"
  [[ $output =~ (^|[[:space:]])v?([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[2]}"
}

wait_for_mita_daemon() {
  local binary="${1:-mita}" attempt
  for (( attempt = 0; attempt < 10; attempt++ )); do
    if "$binary" status >/dev/null 2>&1; then return 0; fi
    if (( attempt < 9 )); then sleep 1; fi
  done
  return 1
}

wait_for_mita_running() {
  local binary="$1"
  shift
  local health="" attempt
  LAST_MITA_STATUS=""
  for (( attempt = 0; attempt < 10; attempt++ )); do
    if (( $# == 0 )) || "$@" >/dev/null 2>&1; then
      if health=$("$binary" status 2>&1); then
        LAST_MITA_STATUS="$health"
        if [[ $health == *'"RUNNING"'* ]]; then return 0; fi
      else
        LAST_MITA_STATUS="$health"
      fi
    else
      LAST_MITA_STATUS="service not active"
    fi
    if (( attempt < 9 )); then sleep 1; fi
  done
  return 1
}

download_verified_asset() { # $1=下载URL $2=保存路径 $3=临时校验文件路径
  local url="$1" dest="$2" checksum_path="$3"
  curl --proto '=https' -fSsL --retry 3 --connect-timeout 15 --max-time 300 -o "$dest" "$url" ||
    die "下载失败：${url}"
  curl --proto '=https' -fSsL --retry 3 --connect-timeout 15 --max-time 60 -o "$checksum_path" "${url}.sha256.txt" ||
    die "校验文件下载失败：${url}.sha256.txt"
  verify_sha256_file "$dest" "$checksum_path"
}

# ---------- 安装 ----------
do_install() {
  local arch; arch="$(arch_name)"
  local os; os="$(os_id)"
  normalize_mita_version
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] 不装机、不联网下载，只生成配置自检。"
  else
    [[ $(id -u) == 0 ]] || die "请以 root 运行此脚本（dry-run 除外）。"
    [[ $(uname -s) == Linux ]] || die "需要 Linux（Debian / Ubuntu / RHEL 系 / Alpine）。"
    if [[ $os == alpine ]]; then
      install_alpine_deps
    fi
  fi
  # 重装沿用上次的状态（用户/密码/端口/域名/tag），显式给的值优先；
  # 升版重装不会悄悄换密码、让已发的 QuanX 配置失效。
  if [[ $DRY_RUN != 1 && -f $STATE_DIR/state.env ]]; then
    local keep_port="$PORT" keep_user="$USER_NAME" keep_pass="$USER_PASS" keep_host="$HOST" keep_tag="$TAG" keep_country="$COUNTRY"
    # shellcheck disable=SC1090
    . "$STATE_DIR/state.env"
    [[ $PORT_EXPLICIT == 1 ]] && PORT="$keep_port"
    [[ $USER_EXPLICIT == 1 ]] && USER_NAME="$keep_user"
    [[ $PASS_EXPLICIT == 1 ]] && USER_PASS="$keep_pass"
    [[ $HOST_EXPLICIT == 1 ]] && HOST="$keep_host"
    [[ $TAG_EXPLICIT == 1 ]] && TAG="$keep_tag"
    [[ $COUNTRY_EXPLICIT == 1 ]] && COUNTRY="$keep_country"
  fi
  # 旧版 state.env 里没有密码时，从客户端文件里找回（避免重装换密码）
  if [[ $DRY_RUN != 1 && $PASS_EXPLICIT != 1 && -z $USER_PASS && -f $CLIENT_FILE ]]; then
    USER_PASS="$(awk '/^mieru=/{ if (match($0, /password=[^,]*/)) { print substr($0, RSTART+9, RLENGTH-9); exit } }' "$CLIENT_FILE" 2>/dev/null || true)"
  fi
  ask_port
  validate
  need_cmd curl; need_cmd python3
  if [[ $DRY_RUN != 1 ]]; then need_sha256; fi

  # 用户名/密码：没给就生成，绝不回退到 name/pwd
  if [[ -z $USER_NAME ]]; then USER_NAME="mieru"; fi
  if [[ -z $USER_PASS ]]; then
    USER_PASS="$(rand_pass)"
    valid_pass "$USER_PASS" || die "随机密码生成失败。"
    info "已随机生成密码（见客户端文件，勿外发）。"
  fi
  if [[ -z $HOST ]]; then
    if [[ $DRY_RUN == 1 ]]; then HOST="203.0.113.10"
    else
      HOST="$(public_ip)"
      [[ -n $HOST ]] || die "探测不到本机公网 IP，请用 --host IP或域名 指定。"
    fi
  fi
  # 自动探测的 HOST 之前没走过 validate，这里补上
  valid_host "$HOST" || die "HOST 非法：${HOST}，请用 --host IP或域名 指定。"
  # 国家：没指定就按 IP 自动识别（只认 IP；识别不到就不要国旗，不报错）
  if [[ -z $COUNTRY && $DRY_RUN != 1 ]]; then
    COUNTRY="$(detect_country "$HOST")"
    [[ -n $COUNTRY ]] || warn "识别不到本机国家，生成的配置不带国旗；想指定请用 --country US（2 位代码）。"
  fi
  local flag=""
  [[ -n $COUNTRY ]] && flag="$(country_flag "$COUNTRY")"
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

  info "安装 mita ${MITA_VERSION}（$os/${arch}），端口 $PORT..."
  if [[ $DRY_RUN == 1 ]]; then
    write_mita_config "$workdir/mita-plain.json" "$PORT" "$USER_NAME" "$USER_PASS"
    info "[dry-run] mita 配置已写 $workdir/mita-plain.json，JSON 校验通过。"
  else
    local base_url="https://github.com/enfein/mieru/releases/download/v${MITA_VERSION}"
    case "$os" in
      debian|ubuntu)
        local deb="mita_${MITA_VERSION}_${arch}.deb"
        download_verified_asset "${base_url}/${deb}" "$workdir/$deb" "$workdir/${deb}.sha256.txt"
        dpkg -i "$workdir/$deb" || apt-get install -f -y || die "mita 安装失败（dpkg）。"
        ;;
      fedora|centos|rhel|rocky|almalinux)
        local rpm_arch="x86_64"; [[ $arch == arm64 ]] && rpm_arch="aarch64"
        local rpm="mita-${MITA_VERSION}-1.${rpm_arch}.rpm"
        download_verified_asset "${base_url}/${rpm}" "$workdir/$rpm" "$workdir/${rpm}.sha256.txt"
        rpm -Uvh --force "$workdir/$rpm" || die "mita 安装失败（rpm）。"
        ;;
      alpine)
        local deb="mita_${MITA_VERSION}_${arch}.deb"
        download_verified_asset "${base_url}/${deb}" "$workdir/$deb" "$workdir/${deb}.sha256.txt"
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
      *) die "不支持的系统：${os}，仅 Debian/Ubuntu/RHEL 系与 Alpine（mita 只提供 deb/rpm，Alpine 用 deb 解包）。" ;;
    esac
    command -v mita >/dev/null 2>&1 || die "mita 未装上（PATH 里找不到 mita）。"
    write_mita_config "$workdir/mita-plain.json" "$PORT" "$USER_NAME" "$USER_PASS"
    if [[ $os == alpine ]]; then
      # Alpine 顺序不能照搬 Debian：mita apply config 要走 /run/mita/mita.sock，
      # 守护进程没跑时直接报错；新装的守护进程先是 IDLE（不监听），apply 之后
      # 必须再 mita start 才会切到 RUNNING 并监听（2026-11-23 xiaoyin 实测）。
      rc-service mita start >/dev/null 2>&1 || true
      wait_for_mita_daemon mita || die "mita 守护进程未就绪，请检查 OpenRC 日志。"
      mita stop >/dev/null 2>&1 || true
      mita apply config "$workdir/mita-plain.json" || die "mita apply config 失败，请看上方报错改配置。"
      mita start || die "mita start 失败。"
    else
      wait_for_mita_daemon mita || die "mita 守护进程未就绪，请检查 systemd 日志（journalctl -u mita -e）。"
      mita stop >/dev/null 2>&1 || true
      mita apply config "$workdir/mita-plain.json" || die "mita apply config 失败，请看上方报错改配置。"
      mita start || die "mita start 失败。"
    fi
    wait_for_mita_running mita || die "mita 未进入 RUNNING：${LAST_MITA_STATUS:-$(mita status 2>&1 | head -5)}"
    info "mita 已 RUNNING，端口 ${PORT}（TCP+UDP）。"
  fi

  # ---- 输出客户端配置 ----
  if [[ $DRY_RUN == 1 ]]; then
    # dry-run 绝不碰 /root：客户端文件只写到 workdir
    CLIENT_FILE="$workdir/mieru-client.txt"
  fi
  mkdir -p "$(dirname "$CLIENT_FILE")" 2>/dev/null || true
  local tag_out="${tag_base}-01"
  [[ -n $flag ]] && tag_out="${flag}-${tag_base}-01"
  {
    if [[ -n $flag ]]; then
      printf '# mieru 客户端配置（%s） %s %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$flag" "$COUNTRY"
    else
      printf '# mieru 客户端配置（%s）\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
    fi
    printf '# 服务端：%s\n' "$HOST"
    printf '# 凭据只在此文件，勿公开分享。\n\n'
    printf '## 明文（官方 mita，端口 %s）\n' "$PORT"
    printf 'mieru=%s:%s, username=%s, password=%s, fast-open=false, udp-relay=true, udp-over-tcp=true, tag=%s\n\n' \
      "$(fmt_host "$HOST")" "$PORT" "$USER_NAME" "$USER_PASS" "$tag_out"
    printf '## 自查\n'
    printf '# mita status 应为 RUNNING；ss -tlnp | grep %s\n' "$PORT"
  } > "$CLIENT_FILE"
  chmod 600 "$CLIENT_FILE" || true
  if [[ $DRY_RUN == 1 ]]; then
    info "[dry-run] 客户端配置已写 ${CLIENT_FILE}。"
  fi
  if [[ $DRY_RUN != 1 ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    # 密码也存进 state.env（600），重装时沿用；各值字符集均不含 $ ` "，heredoc 安全
    cat > "$STATE_DIR/state.env" <<EOF
HOST="$HOST"
USER_NAME="$USER_NAME"
USER_PASS="$USER_PASS"
PORT="$PORT"
TAG="$tag_base"
COUNTRY="$COUNTRY"
EOF
    chmod 600 "$STATE_DIR/state.env" || true
  fi
  info "完成。客户端配置：$CLIENT_FILE"
  cat "$CLIENT_FILE"
}

do_show() {
  [[ -f $CLIENT_FILE ]] || die "没有客户端文件：${CLIENT_FILE}，先跑 install。"
  cat "$CLIENT_FILE"
}
do_status() {
  local check_port="$PORT"
  if [[ $PORT_EXPLICIT != 1 && -f $STATE_DIR/state.env ]]; then
    local saved_port=""
    saved_port=$(awk -F'"' '/^PORT=/{ print $2; exit }' "$STATE_DIR/state.env" 2>/dev/null || true)
    [[ -n $saved_port ]] && check_port="$saved_port"
  fi
  if command -v mita >/dev/null 2>&1; then
    local ver=""
    ver=$(mita_binary_version mita 2>/dev/null || true)
    [[ -n $ver ]] && info "mita 版本：${ver}"
    mita status || true
  else
    info "mita：未安装"
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -H -tlnp "sport = :${check_port}" 2>/dev/null || true
    ss -H -ulnp "sport = :${check_port}" 2>/dev/null || true
  fi
}
do_restart() {
  command -v mita >/dev/null 2>&1 || die "mita 未安装。"
  if [[ -f /etc/init.d/mita ]] && command -v rc-service >/dev/null 2>&1; then
    rc-service mita restart
    wait_for_mita_running mita rc-service mita status || die "重启后 mita 未进入 RUNNING：${LAST_MITA_STATUS:-未知状态}"
    mita status
  elif command -v systemctl >/dev/null 2>&1 && systemctl cat mita.service >/dev/null 2>&1; then
    systemctl restart mita.service
    wait_for_mita_running mita systemctl is-active --quiet mita.service || die "重启后 mita 未进入 RUNNING：${LAST_MITA_STATUS:-未知状态}"
    mita status
  else
    mita stop || true
    mita start
    wait_for_mita_running mita || die "重启后 mita 未进入 RUNNING：${LAST_MITA_STATUS:-未知状态}"
    mita status
  fi
  info "已重启。"
}
do_uninstall() {
  printf '将卸载 mita 并删除配置与客户端文件，输入 yes 确认：'
  local ans=""; read -r ans || true
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
  fi
  rm -rf /etc/mita /var/lib/mita
  rm -f "$CLIENT_FILE"
  info "已卸载。"
}

do_update() {
  local binary=/usr/bin/mita
  local installed="" candidate_version="" arch="" os="" os_like="" archive="" url="" health="" exit_code=0
  local staging="" candidate="" backup="" takeover="" stale_pid=""
  local restart_service=false replacing=false idle=false
  local -a service_status=() service_restart=()

  normalize_mita_version
  if [[ $DRY_RUN == 1 ]]; then
    if [[ -f $binary && -x $binary && ! -L $binary ]] && installed=$(mita_binary_version "$binary" 2>/dev/null); then
      if [[ $installed == "$MITA_VERSION" ]] ||
         { [[ $VERSION_EXPLICIT == 0 ]] && version_ge "$installed" "$MITA_VERSION"; }; then
        info "[dry-run] 当前 mita ${installed} 已达到目标版本 ${MITA_VERSION}，无需升级。"
      else
        info "[dry-run] 将把 mita 从 ${installed} 更新到 ${MITA_VERSION}（保留现有配置）。"
      fi
    else
      info "[dry-run] 目标 mita 内核为 ${MITA_VERSION}（未检测到已安装的 ${binary}）。"
    fi
    return 0
  fi
  [[ $(uname -s) == Linux && $(id -u) == 0 ]] || die "请在 Linux 上以 root 运行 update。"
  if [[ ! -e $binary && -e $binary.update/mita.old ]]; then
    die "找不到 ${binary}，但检测到上次升级遗留的原内核备份 ${binary}.update/mita.old，请先恢复后再试。"
  fi
  [[ -f $binary && -x $binary && ! -L $binary ]] || die "找不到已安装的 mita 内核：${binary}。"
  arch=$(arch_name)
  os=$(os_id)
  os_like=$(os_id_like)
  case "$os" in
    alpine)
      need_cmd rc-service
      service_status=(rc-service mita status)
      service_restart=(rc-service mita restart)
      ;;
    debian|ubuntu|fedora|centos|rhel|rocky|almalinux|ol|amzn|oracle|arch|opensuse*)
      need_cmd systemctl
      service_status=(systemctl is-active --quiet mita.service)
      service_restart=(systemctl restart mita.service)
      ;;
    *)
      if [[ -f /etc/init.d/mita ]] && command -v rc-service >/dev/null 2>&1; then
        service_status=(rc-service mita status)
        service_restart=(rc-service mita restart)
      elif [[ " $os_like " == *" debian "* || " $os_like " == *" ubuntu "* || " $os_like " == *" rhel "* || " $os_like " == *" fedora "* || -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        service_status=(systemctl is-active --quiet mita.service)
        service_restart=(systemctl restart mita.service)
      else
        die "不支持的系统：${os}。"
      fi
      ;;
  esac

  staging="$binary.update"
  if ! mkdir -m 700 -- "$staging" 2>/dev/null; then
    [[ -f $staging/pid ]] && stale_pid=$(tr -dc '0-9' < "$staging/pid" 2>/dev/null || true)
    if [[ -n $stale_pid ]] && kill -0 "$stale_pid" 2>/dev/null; then
      die "已有另一个升级进程（PID ${stale_pid}）正在运行（目录：${staging}）。"
    fi
    if [[ -e $staging/mita.old && ! -e $binary ]]; then
      die "检测到上次升级异常中断且 ${binary} 缺失，原内核备份位于 ${staging}/mita.old，请手动恢复后再试。"
    fi
    if [[ -n $stale_pid ]]; then
      takeover="$staging.takeover"
      mkdir -m 700 -- "$takeover" 2>/dev/null || die "另一个进程正在清理旧升级目录 ${staging}，请稍后重试。"
      stale_pid=""
      [[ -f $staging/pid ]] && stale_pid=$(tr -dc '0-9' < "$staging/pid" 2>/dev/null || true)
      if [[ -d $staging ]] && { [[ -z $stale_pid ]] || kill -0 "$stale_pid" 2>/dev/null; }; then
        rmdir -- "$takeover" 2>/dev/null || true
        die "已有另一个升级进程正在运行（目录：${staging}）。"
      fi
      warn "清理已退出升级进程（PID ${stale_pid}）遗留的目录 ${staging}。"
      if ! rm -rf -- "$staging" || ! mkdir -m 700 -- "$staging" 2>/dev/null; then
        rmdir -- "$takeover" 2>/dev/null || true
        die "无法创建升级目录 ${staging}。请检查是否已有升级在运行。"
      fi
      printf '%s\n' "$$" > "$staging/pid"
      rmdir -- "$takeover" 2>/dev/null || true
    else
      die "无法创建升级目录 ${staging}。若确认没有升级在运行，请先删除该目录后重试。"
    fi
  else
    printf '%s\n' "$$" > "$staging/pid"
  fi
  candidate="$staging/mita.new"
  backup="$staging/mita.old"
  # Keep the trap in the command's own shell and exit while its state is in scope.
  trap '
    exit_code=$?
    trap "" HUP INT TERM
    if [[ $replacing == true && ! -e $candidate ]]; then
      if ! mv -f -- "$backup" "$binary"; then
        warn "恢复原内核失败，备份位于 ${backup}。"
        exit 1
      fi
      if command -v restorecon >/dev/null 2>&1; then restorecon "$binary" >/dev/null 2>&1 || true; fi
      warn "升级未完成，已恢复 mita ${installed}。"
      if [[ $restart_service == true ]]; then
        if [[ ${service_restart[0]:-} == systemctl ]]; then
          systemctl reset-failed mita.service >/dev/null 2>&1 || true
        fi
        if ! "${service_restart[@]}" || ! wait_for_mita_running "$binary" "${service_status[@]}"; then
          warn "原内核已恢复，请检查 mita 服务的启动日志。"
        fi
      fi
    fi
    rm -rf -- "$staging"
    exit "$exit_code"
  ' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  installed=$(mita_binary_version "$binary") || die "无法读取已安装的 mita 版本。"
  if [[ $installed == "$MITA_VERSION" ]] ||
     { [[ $VERSION_EXPLICIT == 0 ]] && version_ge "$installed" "$MITA_VERSION"; }; then
    info "当前 mita ${installed} 已达到目标版本 ${MITA_VERSION}。"
    exit 0
  fi

  need_cmd curl
  need_sha256
  need_cmd tar
  archive="mita_${MITA_VERSION}_linux_${arch}.tar.gz"
  url="https://github.com/enfein/mieru/releases/download/v${MITA_VERSION}/${archive}"
  curl --proto '=https' -fSsL --retry 3 --connect-timeout 15 --max-time 300 -o "$staging/$archive" "$url" ||
    die "mita ${MITA_VERSION} 内核下载失败。"
  curl --proto '=https' -fSsL --retry 3 --connect-timeout 15 --max-time 60 -o "$staging/checksum" "${url}.sha256.txt" ||
    die "mita ${MITA_VERSION} 校验文件下载失败。"
  verify_sha256_file "$staging/$archive" "$staging/checksum"

  mkdir -m 700 -- "$staging/unpack"
  tar -xzf "$staging/$archive" -C "$staging/unpack" || die "解包 mita 内核失败。"
  [[ -f $staging/unpack/mita && ! -L $staging/unpack/mita ]] || die "安装包中未找到 mita 内核。"
  install -m 0755 "$staging/unpack/mita" "$candidate" || die "准备新 mita 内核失败。"
  candidate_version=$(mita_binary_version "$candidate") || die "新内核不可运行或无法读取版本。"
  [[ $candidate_version == "$MITA_VERSION" ]] || die "新内核版本不符：期望 ${MITA_VERSION}，实际 ${candidate_version}。"

  if "${service_status[@]}" >/dev/null 2>&1; then
    # Restarting an IDLE daemon would start its saved proxy listeners.
    if health=$("$binary" status 2>&1) && [[ $health == *'"IDLE"'* ]]; then
      idle=true
    else
      restart_service=true
    fi
  fi
  ln -- "$binary" "$backup" 2>/dev/null || cp -p -- "$binary" "$backup" || die "无法备份现有 mita 内核。"
  replacing=true
  mv -f -- "$candidate" "$binary"
  if command -v restorecon >/dev/null 2>&1; then restorecon "$binary" >/dev/null 2>&1 || true; fi
  if [[ $restart_service == true ]]; then
    "${service_restart[@]}" || die "新内核启动失败。"
    wait_for_mita_running "$binary" "${service_status[@]}" || die "新内核未进入 RUNNING（最后状态：${LAST_MITA_STATUS:-无输出}）。"
  fi
  replacing=false
  info "mita 已从 ${installed} 更新到 ${MITA_VERSION}。"
  if [[ $idle == true ]]; then
    info "代理保持 IDLE，守护进程下次重启时加载新内核。"
  elif [[ $restart_service == false ]]; then
    info "mita 服务当前未运行，下次启动时将使用新内核。"
  fi
  exit 0
}

case "$CMD" in
  install) do_install ;;
  show) do_show ;;
  status) do_status ;;
  restart) do_restart ;;
  uninstall) do_uninstall ;;
  update) do_update ;;
  *) die "未知子命令：${CMD}，用 bash $0 help 查看。" ;;
esac
