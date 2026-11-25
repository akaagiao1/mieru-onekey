#!/usr/bin/env bash
set -euo pipefail

# Pinned Volto bootstrap. The upstream script verifies the release signature
# and archive checksum before installing the requested or latest release.
upstream_commit=e8dabe342be16d3071b43d0c8ba0477a226ace88
upstream_sha256=b53abf79770c394022d608394d31b1f38c0800d15b7036e8d248cdaf17c2ea5a
upstream_url="https://raw.githubusercontent.com/vcarus/volto/$upstream_commit/script/deploy.sh"
deploy_root=${VOLTO_DEPLOY_ROOT:-}
config="$deploy_root/etc/volto/config.toml"

check_update_options() {
  while (( $# )); do
    case $1 in
      --dry-run|--force|--enable-timer) shift ;;
      -t|--tag)
        if [[ $# -lt 2 || $2 == -* ]]; then
          printf '%s\n' '请为 --tag 指定发布标签，例如 v1.8.3。' >&2
          exit 1
        fi
        shift 2
        ;;
      -h|--help)
        cat <<'HELP'
升级已安装的 Volto
  sudo bash volto-onekey.sh update
  sudo bash volto-onekey.sh update --tag v1.8.3
  sudo bash volto-onekey.sh update --dry-run --tag v1.8.3

默认使用上游最新正式版并保留现有配置、证书和凭据。
指定 --tag 后可用 --force 重装同版本。--enable-timer 会启用每日更新。
HELP
        exit 0
        ;;
      *)
        printf 'update 不接受参数 %s，请用 update --help 查看用法。\n' "$1" >&2
        exit 1
        ;;
    esac
  done
}

should_prompt_for_port() {
  [[ -t 0 && ! -f "$config" ]] || return 1

  # Let upstream handle explicit ports, informational commands and bad options.
  while (( $# )); do
    case $1 in
      --enable-timer|--force|--allow-unsigned) shift ;;
      -t|--tag|-s|--sni|-u|--username|-w|--password)
        (( $# >= 2 )) || return 1
        shift 2
        ;;
      *) return 1 ;;
    esac
  done
}

udp_port_is_free() {
  local sockets
  if ! sockets=$(ss -H -u -a -n "sport = :$1"); then
    printf '%s\n' '无法检查 UDP 端口，请检查 ss 命令是否可用。' >&2
    exit 1
  fi
  [[ -z $sockets ]]
}

choose_port() {
  local choice port attempt
  if ! command -v ss >/dev/null 2>&1; then
    printf '%s\n' '选端口需要 ss，请先安装 iproute2，或用 --port 显式指定。' >&2
    return 1
  fi

  while true; do
    printf '%s' 'Volto UDP 端口（回车用 443，输入端口自定义，r 随机）: ' >&2
    if ! IFS= read -r choice; then
      printf '\n%s\n' '端口选择已取消。' >&2
      return 1
    fi

    case $choice in
      '') choice=443 ;;
      r|R|random)
        for (( attempt = 0; attempt < 128; attempt++ )); do
          port=$(( 20000 + RANDOM % 10000 ))
          if udp_port_is_free "$port"; then
            printf '%s\n' "$port"
            return
          fi
        done
        printf '%s\n' '随机试选未找到空闲端口，请手动输入端口或重试。' >&2
        continue
        ;;
    esac

    if [[ ! $choice =~ ^[0-9]{1,5}$ ]] || (( 10#$choice < 1 || 10#$choice > 65535 )); then
      printf '%s\n' '请输入 1–65535 之间的端口号，或输入 r。' >&2
      continue
    fi
    port=$(( 10#$choice ))
    if udp_port_is_free "$port"; then
      printf '%s\n' "$port"
      return
    fi
    printf 'UDP %s 已被占用，请另选一个端口。\n' "$port" >&2
  done
}

enable_dual_stack() (
  local binary="$deploy_root/usr/local/bin/volto"
  local addresses help port temp_dir candidate backup sockets status
  local replacing=false

  [[ $(sysctl -n net.ipv6.bindv6only 2>/dev/null) == 0 ]] || return 0
  addresses=$(ip -6 -o addr show scope global 2>/dev/null) || return 0
  [[ -n $addresses ]] || return 0
  command -v flock >/dev/null 2>&1 || return 0
  command -v ss >/dev/null 2>&1 || return 0
  help=$("$binary" --help 2>&1) || return 0
  [[ $help == *--check-config* ]] || return 0

  # Serialize the listener change with Volto's installer and upgrade timer.
  exec 9>>"$deploy_root/run/volto-deploy.lock"
  flock -x 9
  [[ -f $config && ! -L $config ]] || return 0
  port=$(sed -nE 's/^listen = "0\.0\.0\.0:([0-9]+)"$/\1/p' "$config")
  [[ $port =~ ^[0-9]+$ ]] || return 0

  temp_dir=$(mktemp -d -- "${config%/*}/.volto-listen.XXXXXX")
  candidate="$temp_dir/config.toml"
  backup="$temp_dir/original.toml"
  # Keep the IPv4 config until the replacement listener has been verified.
  trap '
    status=$?
    trap "" HUP INT TERM
    if [[ $replacing == true && ! -e $candidate ]]; then
      if ! mv -f -- "$backup" "$config"; then
        printf "无法恢复 Volto 原配置。备份位于 %s。\n" "$backup" >&2
        exit 1
      fi
      if systemctl restart volto && systemctl is-active --quiet volto; then
        printf "%s\n" "Volto 双栈切换未完成，已恢复 IPv4 监听。" >&2
      else
        printf "%s\n" "已恢复 Volto 原配置，但服务重启失败。" >&2
      fi
    fi
    rm -rf -- "$temp_dir"
    exit "$status"
  ' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  cp -p -- "$config" "$backup"
  cp -p -- "$config" "$candidate"
  sed "s/^listen = \"0\.0\.0\.0:$port\"$/listen = \"[::]:$port\"/" "$config" > "$candidate"
  "$binary" --check-config --config "$candidate"
  replacing=true
  mv -f -- "$candidate" "$config"

  if systemctl restart volto && sleep 3 && systemctl is-active --quiet volto &&
      sockets=$(ss -H -6 -lunpe "sport = :$port") &&
      grep -Eq '"volto".*v6only:0([[:space:]]|$)' <<<"$sockets"; then
    replacing=false
    printf 'Volto 双栈监听已启用（IPv4 和 IPv6，UDP %s）。\n' "$port"
    return 0
  fi

  return 1
)

update_only=false
if [[ ${1:-} == update ]]; then
  update_only=true
  shift
  check_update_options "$@"
  if [[ ! -f $config ]]; then
    printf '找不到 Volto 配置 %s。请先运行安装命令。\n' "$config" >&2
    exit 1
  fi
elif [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '%s\n\n' '已安装的 Volto 可用 sudo bash volto-onekey.sh update 升级。'
elif should_prompt_for_port "$@"; then
  selected_port=$(choose_port)
  printf 'Volto 将使用 UDP %s。\n' "$selected_port" >&2
  set -- "$@" --port "$selected_port"
fi

installer=$(mktemp)
trap 'rm -f -- "$installer"' EXIT

curl --proto '=https' --fail --silent --show-error --location \
  --output "$installer" "$upstream_url"

download_sha256=$(sha256sum < "$installer")
if [[ "${download_sha256%% *}" != "$upstream_sha256" ]]; then
  printf '%s\n' 'Volto installer download failed SHA-256 verification.' >&2
  exit 1
fi

if [[ $update_only == true ]]; then
  if [[ ! -f $config ]]; then
    printf 'Volto 配置 %s 已移除，升级已停止。\n' "$config" >&2
    exit 1
  fi
  # The timer needs a verified on-disk bootstrap even when no upgrade is due.
  bash "$installer" "$@" </dev/null
  exit 0
fi

first_install=false
if [[ ! -e $config && ! -L $config ]]; then
  first_install=true
fi

# Match the upstream bootstrap's stdin invocation and keep stdout attached
# to the terminal so the upstream installer can display the Surge password.
bash -s -- "$@" < "$installer"
if [[ $first_install == true && -f $config ]]; then
  enable_dual_stack
fi
