#!/usr/bin/env bash
set -euo pipefail

# Pinned Volto bootstrap. The upstream script verifies the release signature
# and archive checksum before installing the requested or latest release.
upstream_commit=e8dabe342be16d3071b43d0c8ba0477a226ace88
upstream_sha256=b53abf79770c394022d608394d31b1f38c0800d15b7036e8d248cdaf17c2ea5a
upstream_url="https://raw.githubusercontent.com/vcarus/volto/$upstream_commit/script/deploy.sh"
deploy_root=${VOLTO_DEPLOY_ROOT:-}
config="$deploy_root/etc/volto/config.toml"
min_udp_buffer=4194304
default_ech_public_name="cloudflare-ech.com"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '缺少必需命令 %s，请先安装。\n' "$1" >&2
    exit 1
  fi
}

find_sysctl() {
  if command -v sysctl >/dev/null 2>&1; then
    command -v sysctl
  elif [[ -x /usr/sbin/sysctl ]]; then
    printf '%s\n' /usr/sbin/sysctl
  elif [[ -x /sbin/sysctl ]]; then
    printf '%s\n' /sbin/sysctl
  else
    return 1
  fi
}

read_sysctl_int() {
  local key="$1" val="" sc=""
  if sc=$(find_sysctl 2>/dev/null); then
    val=$("$sc" -n "$key" 2>/dev/null || true)
  fi
  if [[ ! $val =~ ^[0-9]+$ && -z $deploy_root ]]; then
    local proc_path="/proc/sys/${key//.//}"
    if [[ -r $proc_path ]]; then
      val=$(<"$proc_path")
    fi
  fi
  val=$(printf '%s' "$val" | tr -d ' \t\r\n')
  [[ $val =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$val"
}

check_update_options() {
  local has_tag=false need_tag_flag=""
  if [[ -n ${TAG:-} ]]; then
    has_tag=true
  fi
  while (( $# )); do
    case $1 in
      --enable-timer) shift ;;
      --dry-run|--force)
        need_tag_flag="$1"
        shift
        ;;
      -t|--tag)
        if [[ $# -lt 2 || -z $2 || $2 == -* || $2 != v[0-9]* ]]; then
          printf '%s\n' '请为 --tag 指定发布标签，例如 v1.8.5。' >&2
          exit 1
        fi
        has_tag=true
        shift 2
        ;;
      -h|--help)
        cat <<'HELP'
升级已安装的 Volto
  sudo bash volto-onekey.sh update
  sudo bash volto-onekey.sh update --tag v1.8.5
  sudo bash volto-onekey.sh update --dry-run --tag v1.8.5

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
  if [[ -n $need_tag_flag && $has_tag != true ]]; then
    printf 'update %s 需要配合 --tag 指定发布标签，例如 --tag v1.8.5。\n' "$need_tag_flag" >&2
    exit 1
  fi
}

check_config_for_update() {
  local missing_msg="$1"
  if [[ -f $config ]]; then
    return 0
  fi
  if [[ -d ${config%/*} && ! -x ${config%/*} ]]; then
    printf '无法访问 Volto 配置 %s，请使用 sudo 或以 root 运行。\n' "$config" >&2
  else
    printf '%s\n' "$missing_msg" >&2
  fi
  exit 1
}

should_prompt_for_port() {
  [[ -t 0 && -z ${PORT:-} && ! -f "$config" ]] || return 1
  # If /etc/volto exists but is unreadable (0750 root:volto), avoid falsely treating as fresh install.
  [[ ! -d ${config%/*} || -x ${config%/*} ]] || return 1

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
    choice=$(printf '%s' "$choice" | tr -d ' \t\r\n')

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

# Ensure kernel UDP socket buffer ceilings are at least 4 MiB without lowering higher values.
ensure_udp_buffers() {
  local cur_rmem cur_wmem target_rmem target_wmem sysctl_dir sysctl_conf tmp sc=""
  cur_rmem=$(read_sysctl_int net.core.rmem_max 2>/dev/null) || return 0
  cur_wmem=$(read_sysctl_int net.core.wmem_max 2>/dev/null) || return 0

  if (( cur_rmem >= min_udp_buffer && cur_wmem >= min_udp_buffer )); then
    return 0
  fi

  target_rmem=$cur_rmem
  target_wmem=$cur_wmem
  (( target_rmem < min_udp_buffer )) && target_rmem=$min_udp_buffer
  (( target_wmem < min_udp_buffer )) && target_wmem=$min_udp_buffer

  sysctl_dir="$deploy_root/etc/sysctl.d"
  sysctl_conf="$sysctl_dir/90-volto-udp-buffers.conf"
  if mkdir -p "$sysctl_dir" 2>/dev/null; then
    tmp=$(mktemp "$sysctl_dir/.volto-sysctl.XXXXXX") || tmp=""
    if [[ -n $tmp ]]; then
      {
        printf '# Managed by volto-onekey.sh: ensure >= 4 MiB UDP socket buffer ceilings for Volto QUIC.\n'
        printf 'net.core.rmem_max = %s\n' "$target_rmem"
        printf 'net.core.wmem_max = %s\n' "$target_wmem"
      } > "$tmp"
      chmod 0644 "$tmp" 2>/dev/null || true
      mv -f -- "$tmp" "$sysctl_conf" 2>/dev/null || rm -f -- "$tmp"
    fi
  fi

  if sc=$(find_sysctl 2>/dev/null); then
    "$sc" -w "net.core.rmem_max=$target_rmem" >/dev/null 2>&1 || true
    "$sc" -w "net.core.wmem_max=$target_wmem" >/dev/null 2>&1 || true
  fi

  printf '已将内核 UDP 缓冲上限调优至 rmem_max=%s / wmem_max=%s（>= 4 MB）。\n' "$target_rmem" "$target_wmem"
}

detect_cert_sni() {
  local cert="${1:-$deploy_root/etc/volto/cert.pem}" san=""
  if [[ -n $requested_sni ]]; then
    printf '%s\n' "$requested_sni"
    return 0
  fi
  if [[ -r $cert ]] && command -v openssl >/dev/null 2>&1; then
    san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null |
      sed -nE 's/.*DNS:([^,[:space:]]+).*/\1/p' | head -n 1 || true)
    if [[ -n $san ]]; then
      printf '%s\n' "$san"
      return 0
    fi
  fi
  printf '%s\n' 'volto.internal'
}

resolve_deploy_path() {
  local path="$1"
  if [[ -n $deploy_root && $path == /* && $path != "$deploy_root/"* ]]; then
    printf '%s%s\n' "$deploy_root" "$path"
  else
    printf '%s\n' "$path"
  fi
}

detect_server_address() {
  local ips ip ipv4="" ipv6="" first=""
  ips=$(hostname -I 2>/dev/null || true)
  for ip in $ips; do
    [[ -z $first ]] && first="$ip"
    if [[ $ip != *:* ]]; then
      ipv4="$ip"
      break
    elif [[ -z $ipv6 && $ip != fe80:* && $ip != ::1 ]]; then
      ipv6="$ip"
    fi
  done
  if [[ -n $ipv4 ]]; then
    printf '%s\n' "$ipv4"
  elif [[ -n $ipv6 ]]; then
    printf '%s\n' "$ipv6"
  elif [[ -n $first ]]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' '<server-ip>'
  fi
}

read_config_string_key() {
  local target_section="$1" target_key="$2"
  local section="" line val=""
  local sec_re='^\[([^]]+)\][[:space:]]*$'
  local key_re="^[[:space:]]*${target_key}[[:space:]]*=[[:space:]]*\"([^\"]*)\""
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line =~ $sec_re ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ $section == "$target_section" && $line =~ $key_re ]]; then
      val="${BASH_REMATCH[1]}"
      break
    fi
  done < "$config" || true
  printf '%s\n' "$val"
}

read_config_expected_sni() {
  local section="" line val=""
  local sec_re='^\[([^]]+)\][[:space:]]*$'
  local sni_re='^[[:space:]]*expected_sni[[:space:]]*=[[:space:]]*\[[[:space:]]*"([^"]+)"'
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line =~ $sec_re ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ $section == security && $line =~ $sni_re ]]; then
      val="${BASH_REMATCH[1]}"
      break
    fi
  done < "$config" || true
  printf '%s\n' "$val"
}

filter_upstream_surge_block() {
  awk '
    /^Surge policy line/ { skip = 2; next }
    skip > 0 && $0 == "" { skip--; next }
    /^[[:space:]]*volto = masque,/ { skip = 1; next }
    { skip = 0; print; fflush() }
  '
}

print_surge_policy_line() {
  local binary="$deploy_root/usr/local/bin/volto"
  if [[ ! -x $binary && -z $deploy_root ]]; then
    binary=$(command -v volto 2>/dev/null || true)
  fi
  local cert_cfg cert_file fingerprint="" fp_val=""
  local listen_val port address sni
  local ech_key_cfg ech_file ech_config_list="" ech_part=""
  local conf_username="" conf_password="" shown_password="" line
  local user_re='\{[[:space:]]*username[[:space:]]*=[[:space:]]*"([^"]*)"[[:space:]]*,[[:space:]]*password[[:space:]]*=[[:space:]]*"([^"]*)"[[:space:]]*\}'

  cert_cfg=$(read_config_string_key server cert)
  [[ -n $cert_cfg ]] || cert_cfg="/etc/volto/cert.pem"
  cert_file=$(resolve_deploy_path "$cert_cfg")

  if [[ -r $cert_file ]] && command -v openssl >/dev/null 2>&1; then
    fingerprint=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null || true)
  fi
  fp_val="${fingerprint#*=}"
  [[ -n $fp_val ]] || fp_val='<unknown>'

  address=$(detect_server_address)

  listen_val=$(read_config_string_key server listen)
  port="${listen_val##*:}"
  [[ $port =~ ^[0-9]+$ ]] || port='<port>'

  sni=$(read_config_expected_sni)
  [[ -n $sni ]] || sni=$(detect_cert_sni "$cert_file")

  # Read credentials with bash builtins so plaintext passwords never appear in /proc/<pid>/cmdline.
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line =~ $user_re ]]; then
      conf_username="${BASH_REMATCH[1]}"
      conf_password="${BASH_REMATCH[2]}"
      break
    fi
  done < "$config" || true
  [[ -n $conf_username ]] || conf_username='<unknown>'
  [[ -n $conf_password ]] || conf_password='<unknown>'

  if [[ -t 1 ]]; then
    shown_password="$conf_password"
  else
    shown_password="<as in $config>"
  fi

  ech_key_cfg=$(read_config_string_key server ech_key)
  if [[ -n $ech_key_cfg ]]; then
    ech_file=$(resolve_deploy_path "$ech_key_cfg")
    if [[ -x $binary && -r $ech_file ]]; then
      ech_config_list=$("$binary" ech-config "$ech_file" 2>/dev/null | tr -d ' \t\r\n' || true)
    fi
    if [[ -z $ech_config_list ]]; then
      printf '警告: 无法从 %s 读取 ECHConfigList，请运行 volto ech-config %s 检查。\n' "$ech_file" "$ech_file" >&2
      ech_config_list='<unknown>'
    fi
    ech_part=", ech-config=${ech_config_list}"
  fi

  printf '\n'
  printf 'Surge 完整配置（可直接粘贴到 [Proxy]，中转时替换 IP/端口即可）:\n\n'
  printf '  volto = masque, %s, %s, sni=%s, server-cert-fingerprint-sha256=%s%s, username=%s, password=%s\n\n' \
    "$address" "$port" "$sni" "$fp_val" "$ech_part" "$conf_username" "$shown_password"
}

choose_ech_public_name() {
  local sni="$1" candidate="${ech_public_name:-$default_ech_public_name}"
  if [[ ${candidate,,} == "${sni,,}" ]]; then
    if [[ ${sni,,} == "public.volto.internal" ]]; then
      candidate="$default_ech_public_name"
    else
      candidate="public.volto.internal"
    fi
  fi
  printf '%s\n' "$candidate"
}

rewrite_volto_config() {
  local src="$1" dst="$2"
  local want_v6="$3" port="$4"
  local want_sni="$5" sni_name="$6"
  local want_ech="$7" ech_cfg_path="$8"

  awk \
    -v want_v6="$want_v6" \
    -v port="$port" \
    -v want_sni="$want_sni" \
    -v sni_name="$sni_name" \
    -v want_ech="$want_ech" \
    -v ech_cfg_path="$ech_cfg_path" '
    function flush_section(sec) {
      if (sec == "server" && want_ech == "1" && !done_ech_key) {
        print "ech_key = \"" ech_cfg_path "\""
        done_ech_key = 1
      }
      if (sec == "security") {
        if (want_sni == "1" && !done_sni) {
          print "expected_sni = [\"" sni_name "\"]"
          done_sni = 1
        }
        if (want_ech == "1" && !done_req_ech) {
          print "require_ech = true"
          done_req_ech = 1
        }
      }
    }
    BEGIN {
      section = ""
      saw_security = 0
      done_ech_key = 0
      done_sni = 0
      done_req_ech = 0
    }
    /^\[[^]]+\][[:space:]]*$/ {
      flush_section(section)
      section = $0
      sub(/^\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      if (section == "security") saw_security = 1
      print $0
      next
    }
    {
      if (section == "server") {
        if (want_v6 == "1" && $0 == "listen = \"0.0.0.0:" port "\"") {
          print "listen = \"[::]:" port "\""
          next
        }
        if (want_ech == "1" && $0 ~ /^#?[[:space:]]*ech_key[[:space:]]*=/) {
          print "ech_key = \"" ech_cfg_path "\""
          done_ech_key = 1
          next
        }
      }
      if (section == "limits" && want_v6 == "1") {
        if ($0 ~ /^#?[[:space:]]*initial_mtu[[:space:]]*=/) {
          print "initial_mtu = 1200"
          next
        }
      }
      if (section == "security") {
        if (want_sni == "1" && $0 ~ /^#?[[:space:]]*expected_sni[[:space:]]*=/) {
          print "expected_sni = [\"" sni_name "\"]"
          done_sni = 1
          next
        }
        if (want_ech == "1" && $0 ~ /^#?[[:space:]]*require_ech[[:space:]]*=/) {
          print "require_ech = true"
          done_req_ech = 1
          next
        }
      }
      print $0
    }
    END {
      flush_section(section)
      if (!saw_security && (want_sni == "1" || want_ech == "1")) {
        print ""
        print "[security]"
        if (want_sni == "1" && !done_sni) print "expected_sni = [\"" sni_name "\"]"
        if (want_ech == "1" && !done_req_ech) print "require_ech = true"
      }
    }
  ' "$src" > "$dst"
}

# Atomically harden a fresh Volto install:
# - Dual-stack listener ([::]:<port> + initial_mtu=1200) when global IPv6 and bindv6only=0
# - SNI Gate (expected_sni = ["<cert_sni>"])
# - Private ECH (ech_key + require_ech = true), unless --no-ech / VOLTO_NO_ECH=1
configure_fresh_install() (
  local binary="$deploy_root/usr/local/bin/volto"
  local ech_file="$deploy_root/etc/volto/ech.pem"
  local ech_cfg_path="/etc/volto/ech.pem"
  [[ -n $deploy_root ]] && ech_cfg_path="$ech_file"

  local addresses help port temp_dir candidate backup sockets status
  local want_v6=0 want_sni=0 want_ech=0
  local sni_name="" pub_name="" ech_config_list=""
  local replacing=false created_ech=false

  command -v flock >/dev/null 2>&1 || return 0
  help=$("$binary" --help 2>&1) || return 0
  [[ $help == *--check-config* ]] || return 0

  # Serialize config edits with Volto's installer and upgrade timer.
  exec 9>>"$deploy_root/run/volto-deploy.lock"
  flock -x 9
  [[ -f $config && ! -L $config ]] || return 0

  port=$(sed -nE 's/^listen = "0\.0\.0\.0:([0-9]+)"$/\1/p' "$config")
  if [[ $port =~ ^[0-9]+$ ]] && command -v ss >/dev/null 2>&1; then
    if [[ $(read_sysctl_int net.ipv6.bindv6only 2>/dev/null || echo 1) == 0 ]]; then
      addresses=$(ip -6 -o addr show scope global 2>/dev/null || true)
      [[ -n $addresses ]] && want_v6=1
    fi
  fi

  sni_name=$(detect_cert_sni)
  if [[ -n $sni_name ]] && ! grep -Eq '^[[:space:]]*expected_sni[[:space:]]*=' "$config"; then
    want_sni=1
  fi

  if [[ $no_ech != true && $help == *ech-keygen* ]] &&
     ! grep -Eq '^[[:space:]]*ech_key[[:space:]]*=' "$config" &&
     [[ ! -e $ech_file ]]; then
    want_ech=1
    pub_name=$(choose_ech_public_name "$sni_name")
  fi

  if (( want_v6 == 0 && want_sni == 0 && want_ech == 0 )); then
    return 0
  fi

  temp_dir=$(mktemp -d -- "${config%/*}/.volto-harden.XXXXXX")
  candidate="$temp_dir/config.toml"
  backup="$temp_dir/original.toml"

  # Keep original config and clean newly created ECH key if validation or restart fails.
  trap '
    status=$?
    trap "" HUP INT TERM
    if [[ $replacing == true && ! -e $candidate ]]; then
      if ! mv -f -- "$backup" "$config"; then
        printf "无法恢复 Volto 原配置。备份位于 %s。\n" "$backup" >&2
        exit 1
      fi
      if [[ $created_ech == true ]]; then
        rm -f -- "$ech_file"
      fi
      systemctl reset-failed volto >/dev/null 2>&1 || true
      if systemctl restart volto && systemctl is-active --quiet volto; then
        printf "%s\n" "Volto 加固/双栈配置未完成，已恢复原配置。" >&2
      else
        printf "%s\n" "已恢复 Volto 原配置，但服务重启失败。" >&2
      fi
    elif [[ $status -ne 0 && $created_ech == true ]]; then
      rm -f -- "$ech_file"
    fi
    rm -rf -- "$temp_dir"
    exit "$status"
  ' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if (( want_ech == 1 )); then
    ech_config_list=$("$binary" ech-keygen --public-name "$pub_name" --out "$ech_file")
    ech_config_list=$(printf '%s' "$ech_config_list" | tr -d ' \t\r\n')
    [[ -n $ech_config_list ]] || {
      printf '%s\n' '生成 ECH 密钥失败（未输出 ECHConfigList）。' >&2
      return 1
    }
    created_ech=true
    chgrp volto "$ech_file" 2>/dev/null || true
    chmod 0640 "$ech_file" 2>/dev/null || true
  fi

  cp -p -- "$config" "$backup"
  cp -p -- "$config" "$candidate"
  rewrite_volto_config "$backup" "$candidate" "$want_v6" "$port" "$want_sni" "$sni_name" "$want_ech" "$ech_cfg_path"

  (unset RUST_LOG; "$binary" --check-config --config "$candidate")
  replacing=true
  mv -f -- "$candidate" "$config"

  if systemctl restart volto && sleep 3 && systemctl is-active --quiet volto; then
    if (( want_v6 == 1 )); then
      if ! sockets=$(ss -H -6 -lunpe "sport = :$port") ||
         ! grep -Eq '"volto".*v6only:0([[:space:]]|$)' <<<"$sockets"; then
        return 1
      fi
    fi
    replacing=false
    created_ech=false
    if (( want_v6 == 1 )); then
      printf 'Volto 双栈监听已启用（IPv4 和 IPv6，UDP %s，initial_mtu=1200）。\n' "$port"
    fi
    if (( want_sni == 1 )); then
      printf 'Volto SNI Gate 已启用: expected_sni = ["%s"]。\n' "$sni_name"
    fi
    if (( want_ech == 1 )); then
      printf 'Volto ECH 已启用: require_ech = true（外部 public_name=%s，密钥=%s）。\n' "$pub_name" "$ech_cfg_path"
    fi
    return 0
  fi

  return 1
)

update_only=false
help_only=false
no_ech=false
[[ ${VOLTO_NO_ECH:-0} == 1 ]] && no_ech=true
ech_public_name=${ECH_PUBLIC_NAME:-}
requested_sni=${SNI:-}

if [[ ${1:-} == show ]]; then
  shift
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    cat <<'HELP'
输出当前已安装 Volto 的完整 Surge 节点配置（含 ech-config）
  sudo bash volto-onekey.sh show

仅在交互终端输出明文密码；重定向或非终端环境下会隐藏密码。
HELP
    exit 0
  fi
  if (( $# > 0 )); then
    printf 'show 不接受参数 %s，请用 show --help 查看用法。\n' "$1" >&2
    exit 1
  fi
  check_config_for_update "找不到 Volto 配置 ${config}。请先运行安装命令。"
  print_surge_policy_line
  exit 0
elif [[ ${1:-} == update ]]; then
  update_only=true
  shift
  check_update_options "$@"
  check_config_for_update "找不到 Volto 配置 ${config}。请先运行安装命令。"
elif [[ ${1:-} == --help || ${1:-} == -h ]]; then
  help_only=true
  cat <<'HELP'
已安装的 Volto 可用:
  sudo bash volto-onekey.sh show     查看当前完整 Surge 节点配置（含 ech-config）
  sudo bash volto-onekey.sh update   升级已安装的 Volto

额外加固选项（仅首次安装生效，默认全部开启）:
  --no-ech                     不启用 ECH / require_ech（兼容 Apple NERelay 客户端）
  --ech-public-name <NAME>     自定义 ECH 外部明文域名（默认 cloudflare-ech.com）

默认首次安装还会自动:
  - 将 net.core.rmem_max / wmem_max 调优至 >= 4 MB（不降低原更高值）
  - 开启 [security] expected_sni = ["<证书SNI>"]
  - 生成 /etc/volto/ech.pem 并开启 ech_key + require_ech = true
  - 有全局 IPv6 且支持双栈时切换 [::] 并将 initial_mtu 调整为 1200
  - 末尾直接输出可直接粘贴的完整 Surge 节点配置（已包含 ech-config）

HELP
else
  # Strip wrapper-only options before invoking upstream deploy.sh, and capture --sni.
  upstream_args=()
  while (( $# )); do
    case $1 in
      --no-ech)
        no_ech=true
        shift
        ;;
      --ech-public-name)
        if [[ $# -lt 2 || -z $2 || $2 == -* ]]; then
          printf '%s\n' '请为 --ech-public-name 指定域名，例如 cloudflare-ech.com。' >&2
          exit 1
        fi
        ech_public_name="$2"
        shift 2
        ;;
      -s|--sni)
        if [[ $# -ge 2 ]]; then
          requested_sni="$2"
          upstream_args+=("$1" "$2")
          shift 2
        else
          upstream_args+=("$1")
          shift
        fi
        ;;
      *)
        upstream_args+=("$1")
        shift
        ;;
    esac
  done
  set -- "${upstream_args[@]}"

  if should_prompt_for_port "$@"; then
    selected_port=$(choose_port)
    printf 'Volto 将使用 UDP %s。\n' "$selected_port" >&2
    set -- "$@" --port "$selected_port"
  fi
fi

need_cmd curl
need_cmd sha256sum

installer=$(mktemp)
trap 'rm -f -- "$installer"' EXIT

curl --proto '=https' --fail --silent --show-error --location \
  --retry 3 --retry-max-time 60 --connect-timeout 10 --max-time 60 \
  --output "$installer" "$upstream_url"

download_sha256=$(sha256sum < "$installer")
if [[ "${download_sha256%% *}" != "$upstream_sha256" ]]; then
  printf '%s\n' 'Volto installer download failed SHA-256 verification.' >&2
  exit 1
fi

if [[ $update_only == true ]]; then
  check_config_for_update "Volto 配置 ${config} 已移除，升级已停止。"
  # The timer needs a verified on-disk bootstrap even when no upgrade is due.
  bash "$installer" "$@" </dev/null
  exit 0
fi

first_install=false
if [[ $help_only != true && ! -e $config && ! -L $config ]]; then
  first_install=true
  ensure_udp_buffers
fi

# Run from the verified on-disk file so --enable-timer works even when already
# current, detach stdin to match upstream's non-interactive SNI default, and
# replace upstream's incomplete non-ECH Surge line with our complete ECH line
# when ECH hardening is enabled on a fresh install.
suppressed_upstream_surge=false
if [[ $first_install == true && $no_ech != true ]]; then
  suppressed_upstream_surge=true
  bash "$installer" "$@" </dev/null | filter_upstream_surge_block
else
  bash "$installer" "$@" </dev/null
fi
if [[ $first_install == true && -f $config ]]; then
  configure_fresh_install
  if [[ $suppressed_upstream_surge == true ]]; then
    print_surge_policy_line
  fi
fi
