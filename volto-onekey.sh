#!/usr/bin/env bash
set -euo pipefail

# Volto v1.8.2 bootstrap. The upstream script verifies the release signature
# and archive checksum before installing the requested or latest release.
upstream_commit=e8dabe342be16d3071b43d0c8ba0477a226ace88
upstream_sha256=b53abf79770c394022d608394d31b1f38c0800d15b7036e8d248cdaf17c2ea5a
upstream_url="https://raw.githubusercontent.com/vcarus/volto/$upstream_commit/script/deploy.sh"

should_prompt_for_port() {
  [[ -t 0 && ! -f "${VOLTO_DEPLOY_ROOT:-}/etc/volto/config.toml" ]] || return 1

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

if should_prompt_for_port "$@"; then
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

# Match the upstream bootstrap's stdin invocation and keep stdout attached
# to the terminal so the upstream installer can display the Surge password.
bash -s -- "$@" < "$installer"
