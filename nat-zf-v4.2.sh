#!/usr/bin/env bash
set -u

APP_NAME="端口转发管理面板"
APP_VERSION="v4.2-cli-l2tp-udp-only-autocleanup-selfcheck-diagnosefix"

BASE_DIR="/opt/portfw_panel"
RULES_FILE="$BASE_DIR/rules.db"
LIMITS_FILE="$BASE_DIR/limits.db"
LOG_DIR="$BASE_DIR/logs"
AUTO_START_ON_CREATE=1

mkdir -p "$BASE_DIR" "$LOG_DIR"
touch "$RULES_FILE"
touch "$LIMITS_FILE"

is_ipv4_maybe() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local a b c d
  IFS='.' read -r a b c d <<< "$ip"
  local octet
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

migrate_rules_file() {
  [[ -f "$RULES_FILE" && -s "$RULES_FILE" ]] || return 0

  local tmp migrated=0
  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line:-}" ]] || continue
    local count
    count=$(awk -F'|' '{print NF}' <<< "$line")

    if [[ "$count" -ge 7 ]]; then
      local id bind_ip listen_port target_ip target_port field6 field7
      IFS='|' read -r id bind_ip listen_port target_ip target_port field6 field7 _ <<< "$line"

      if is_ipv4_maybe "$field6"; then
        echo "${id}|${bind_ip}|${listen_port}|${target_ip}|${target_port}|${field6}|${field7}" >> "$tmp"
      else
        echo "${id}|${bind_ip}|${listen_port}|${target_ip}|${target_port}|${bind_ip}|${field6}" >> "$tmp"
        migrated=1
      fi
    elif [[ "$count" -eq 6 ]]; then
      local id bind_ip listen_port target_ip target_port remark
      IFS='|' read -r id bind_ip listen_port target_ip target_port remark <<< "$line"
      echo "${id}|${bind_ip}|${listen_port}|${target_ip}|${target_port}|${bind_ip}|${remark}" >> "$tmp"
      migrated=1
    elif [[ "$count" -eq 5 ]]; then
      local id bind_ip listen_port target_ip remark
      IFS='|' read -r id bind_ip listen_port target_ip remark <<< "$line"
      echo "${id}|${bind_ip}|${listen_port}|${target_ip}|${listen_port}|${bind_ip}|${remark}" >> "$tmp"
      migrated=1
    else
      echo "$line" >> "$tmp"
    fi
  done < "$RULES_FILE"

  if (( migrated == 1 )); then
    cp -f "$RULES_FILE" "${RULES_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    mv "$tmp" "$RULES_FILE"
  else
    rm -f "$tmp"
  fi
}

migrate_limits_file() {
  [[ -f "$LIMITS_FILE" && -s "$LIMITS_FILE" ]] || return 0

  local tmp migrated=0 idx=0
  local id port_spec rate remark normalized_spec
  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line:-}" ]] || continue
    IFS='|' read -r id port_spec rate remark _ <<< "$line"
    normalized_spec="$(normalize_port_spec "$port_spec" 2>/dev/null || true)"
    if [[ -z "$normalized_spec" ]] || ! validate_rate_mbps "$rate"; then
      migrated=1
      continue
    fi
    idx=$((idx + 1))
    remark="$(sanitize_remark "${remark:-}")"
    echo "${idx}|${normalized_spec}|${rate}|${remark}" >> "$tmp"
    if [[ "$id" != "$idx" || "$port_spec" != "$normalized_spec" ]]; then
      migrated=1
    fi
  done < "$LIMITS_FILE"

  if (( migrated == 1 )); then
    cp -f "$LIMITS_FILE" "${LIMITS_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    mv "$tmp" "$LIMITS_FILE"
  else
    rm -f "$tmp"
  fi
}

migrate_rules_file

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  fi
  echo "请使用 root 运行此脚本。"
  exit 1
fi

need_install=()
command -v ip >/dev/null 2>&1 || need_install+=("iproute2")
command -v ss >/dev/null 2>&1 || need_install+=("iproute2")
command -v iptables >/dev/null 2>&1 || need_install+=("iptables")
command -v sysctl >/dev/null 2>&1 || need_install+=("procps")
command -v curl >/dev/null 2>&1 || need_install+=("curl")

if [[ ${#need_install[@]} -gt 0 ]]; then
  if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y iproute2 iptables procps curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iproute iptables procps-ng curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iproute iptables procps-ng curl
  else
    echo "无法自动安装依赖，请手动安装：iproute2 iptables procps curl"
    exit 1
  fi
fi

clear_screen() {
  clear 2>/dev/null || printf '\033c'
}

line() {
  local n="${1:-44}"
  printf '=%.0s' $(seq 1 "$n")
  printf '\n'
}

subline() {
  local n="${1:-44}"
  printf -- '-%.0s' $(seq 1 "$n")
  printf '\n'
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

pause() {
  echo
  read -r -p "按回车继续..." _
}

show_message() {
  clear_screen
  line 60
  echo " $APP_NAME $APP_VERSION"
  line 60
  echo
  printf '%b\n' "$1"
  pause
}


legacy_portfw_rules_exist() {
  iptables-save 2>/dev/null | grep -q 'PORTFW_'
}

backup_current_iptables_ruleset() {
  local backup_dir backup_file
  backup_dir="$BASE_DIR/backups"
  mkdir -p "$backup_dir"
  backup_file="$backup_dir/iptables.before_legacy_portfw_cleanup.$(date +%Y%m%d%H%M%S).rules"
  iptables-save > "$backup_file"
  printf '%s' "$backup_file"
}

cleanup_legacy_portfw_rules() {
  local tmpfile rc=0 line
  tmpfile="$(mktemp)"

  iptables-save | awk '
    /^\*/ {
      table = substr($0, 2)
      next
    }
    /^-A / && /PORTFW_/ {
      cmd = $0
      sub(/^-A /, "iptables -t " table " -D ", cmd)
      lines[++n] = cmd
    }
    END {
      for (i = n; i >= 1; i--) print lines[i]
    }
  ' > "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    return 0
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! bash -c "$line" >/dev/null 2>&1; then
      rc=1
    fi
  done < "$tmpfile"

  rm -f "$tmpfile"
  return "$rc"
}

auto_cleanup_legacy_portfw_rules() {
  legacy_portfw_rules_exist || return 0

  local backup_file
  backup_file="$(backup_current_iptables_ruleset)"

  if cleanup_legacy_portfw_rules; then
    show_message "检测到旧版 PORTFW 规则残留，已自动清理完成。\n\niptables 备份文件：$backup_file\n\n说明：为避免旧版 PORTFW 与新版 L2TP 规则冲突，脚本已在启动时自动完成迁移清理。"
    return 0
  fi

  show_message "检测到旧版 PORTFW 规则残留，但自动清理失败。\n\niptables 备份文件：$backup_file\n\n请先手动执行旧规则清理，再继续使用本脚本。"
  exit 1
}

confirm() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

validate_ipv4() {
  is_ipv4_maybe "$1"
}

sanitize_remark() {
  local s="$1"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//|//}"
  printf '%s' "$(trim "$s")"
}

validate_rate_mbps() {
  local rate="$1"
  [[ "$rate" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v r="$rate" 'BEGIN{exit !(r>0)}'
}

normalize_port_spec() {
  local raw="$1"
  raw="${raw// /}"
  raw="${raw//-/:}"
  [[ -n "$raw" ]] || return 1

  local item start end out=()
  IFS=',' read -r -a parts <<< "$raw"
  for item in "${parts[@]}"; do
    [[ -n "$item" ]] || continue
    if [[ "$item" =~ ^[0-9]+$ ]]; then
      validate_port "$item" || return 1
      out+=("$item")
    elif [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      validate_port "$start" || return 1
      validate_port "$end" || return 1
      (( start <= end )) || return 1
      out+=("${start}:${end}")
    else
      return 1
    fi
  done
  ((${#out[@]} > 0)) || return 1
  (IFS=','; printf '%s' "${out[*]}")
}

port_spec_item_count() {
  local spec="$1"
  awk -F',' '{print NF}' <<< "$spec"
}

port_in_spec() {
  local port="$1"
  local spec="$2"
  local item s e
  IFS=',' read -r -a items <<< "$spec"
  for item in "${items[@]}"; do
    if [[ "$item" =~ ^[0-9]+$ ]]; then
      [[ "$port" == "$item" ]] && return 0
    elif [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
      s="${BASH_REMATCH[1]}"
      e="${BASH_REMATCH[2]}"
      (( port >= s && port <= e )) && return 0
    fi
  done
  return 1
}

next_limit_id() {
  if [[ ! -s "$LIMITS_FILE" ]]; then
    echo "1"
    return
  fi
  awk -F'|' 'BEGIN{max=0} $1 ~ /^[0-9]+$/ && $1>max {max=$1} END{print max+1}' "$LIMITS_FILE"
}

get_limit_line() {
  local id="$1"
  awk -F'|' -v id="$id" '$1==id {print; exit}' "$LIMITS_FILE"
}

rate_to_bytes_per_sec() {
  local rate="$1"
  awk -v m="$rate" 'BEGIN{printf "%.0f", m*125000}'
}

start_limit_by_id() {
  local id="$1"
  local line_data port_spec rate_mbps remark bytes_per_sec burst_bytes comment
  line_data="$(get_limit_line "$id")"
  [[ -n "$line_data" ]] || return 1
  IFS='|' read -r _ port_spec rate_mbps remark <<< "$line_data"
  bytes_per_sec="$(rate_to_bytes_per_sec "$rate_mbps")"
  burst_bytes=$(( bytes_per_sec / 5 ))
  (( burst_bytes < 65536 )) && burst_bytes=65536
  comment="LIM_${id}_udp"

  if ! iptables_add_unique filter FORWARD -p udp -m multiport --dports "$port_spec" -m hashlimit --hashlimit-name "${comment}_D" --hashlimit-mode dstport --hashlimit-above "${bytes_per_sec}b/second" --hashlimit-burst "${burst_bytes}b" -j DROP; then
    return 1
  fi
  if ! iptables_add_unique filter FORWARD -p udp -m multiport --sports "$port_spec" -m hashlimit --hashlimit-name "${comment}_S" --hashlimit-mode srcport --hashlimit-above "${bytes_per_sec}b/second" --hashlimit-burst "${burst_bytes}b" -j DROP; then
    iptables_del_if_exists filter FORWARD -p udp -m multiport --dports "$port_spec" -m hashlimit --hashlimit-name "${comment}_D" --hashlimit-mode dstport --hashlimit-above "${bytes_per_sec}b/second" --hashlimit-burst "${burst_bytes}b" -j DROP || true
    return 1
  fi
  return 0
}

stop_limit_by_id() {
  local id="$1"
  local line_data port_spec rate_mbps remark bytes_per_sec burst_bytes comment
  line_data="$(get_limit_line "$id")"
  [[ -n "$line_data" ]] || return 0
  IFS='|' read -r _ port_spec rate_mbps remark <<< "$line_data"
  bytes_per_sec="$(rate_to_bytes_per_sec "$rate_mbps")"
  burst_bytes=$(( bytes_per_sec / 5 ))
  (( burst_bytes < 65536 )) && burst_bytes=65536
  comment="LIM_${id}_udp"

  iptables_del_if_exists filter FORWARD -p udp -m multiport --dports "$port_spec" -m hashlimit --hashlimit-name "${comment}_D" --hashlimit-mode dstport --hashlimit-above "${bytes_per_sec}b/second" --hashlimit-burst "${burst_bytes}b" -j DROP || true
  iptables_del_if_exists filter FORWARD -p udp -m multiport --sports "$port_spec" -m hashlimit --hashlimit-name "${comment}_S" --hashlimit-mode srcport --hashlimit-above "${bytes_per_sec}b/second" --hashlimit-burst "${burst_bytes}b" -j DROP || true
  return 0
}

save_limit_rule() {
  local port_spec="$1"
  local rate_mbps="$2"
  local remark="$3"
  local id
  id="$(next_limit_id)"
  remark="$(sanitize_remark "$remark")"
  echo "${id}|${port_spec}|${rate_mbps}|${remark}" >> "$LIMITS_FILE"
  echo "$id"
}

delete_limit_by_id() {
  local id="$1"
  [[ -n "$(get_limit_line "$id")" ]] || return 1
  local old_id spec rate remark
  while IFS='|' read -r old_id spec rate remark _; do
    [[ -n "${old_id:-}" ]] || continue
    stop_limit_by_id "$old_id"
  done < "$LIMITS_FILE"
  awk -F'|' -v id="$id" '$1!=id' "$LIMITS_FILE" > "${LIMITS_FILE}.tmp" && mv "${LIMITS_FILE}.tmp" "$LIMITS_FILE"
  renumber_limits_file
  reconcile_all_limits
}

renumber_limits_file() {
  [[ -f "$LIMITS_FILE" ]] || return 0
  local tmp idx=0 id spec rate remark
  tmp="$(mktemp)"
  while IFS='|' read -r id spec rate remark _; do
    [[ -n "${id:-}" ]] || continue
    idx=$((idx + 1))
    echo "${idx}|${spec}|${rate}|${remark}" >> "$tmp"
  done < "$LIMITS_FILE"
  mv "$tmp" "$LIMITS_FILE"
}

limit_text_for_port() {
  local port="$1"
  local id spec rate remark result=""
  while IFS='|' read -r id spec rate remark _; do
    [[ -n "${id:-}" ]] || continue
    if port_in_spec "$port" "$spec"; then
      [[ -n "$result" ]] && result+=", "
      result+="${rate}M(${spec})"
    fi
  done < "$LIMITS_FILE"
  [[ -n "$result" ]] || result="--"
  printf '%s' "$result"
}

next_rule_id() {
  if [[ ! -s "$RULES_FILE" ]]; then
    echo "1"
    return
  fi
  awk -F'|' 'BEGIN{max=0} $1 ~ /^[0-9]+$/ && $1>max {max=$1} END{print max+1}' "$RULES_FILE"
}

get_rule_line() {
  local id="$1"
  awk -F'|' -v id="$id" '$1==id {print; exit}' "$RULES_FILE"
}

log_file() {
  local id="$1"
  echo "$LOG_DIR/${id}.udp.log"
}

append_rule_log() {
  local id="$1"
  shift
  local lf
  lf="$(log_file "$id")"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$lf"
}

is_local_ipv4() {
  local ip="$1"
  ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$ip"
}

iptables_has_rule() {
  local table="$1"
  shift
  iptables -t "$table" -C "$@" >/dev/null 2>&1
}

run_iptables_logged() {
  local id="$1"
  local mode="$2"
  local table="$3"
  shift 3

  local output rc=0
  if output="$(iptables -t "$table" "$mode" "$@" 2>&1)"; then
    return 0
  fi
  rc=$?
  append_rule_log "$id" "iptables $table $mode 失败: $* | $output"
  return "$rc"
}

iptables_add_unique_logged() {
  local id="$1"
  local table="$2"
  shift 2
  if iptables_has_rule "$table" "$@"; then
    return 0
  fi
  run_iptables_logged "$id" -A "$table" "$@"
}

iptables_del_if_exists_logged() {
  local id="$1"
  local table="$2"
  shift 2
  local rc=0
  while iptables_has_rule "$table" "$@"; do
    run_iptables_logged "$id" -D "$table" "$@" || rc=$?
    [[ "$rc" -eq 0 ]] || break
  done
  return "$rc"
}

iptables_add_unique() {
  local table="$1"
  shift
  if iptables_has_rule "$table" "$@"; then
    return 0
  fi
  iptables -t "$table" -A "$@" >/dev/null 2>&1
}

iptables_del_if_exists() {
  local table="$1"
  shift
  local rc=0
  while iptables_has_rule "$table" "$@"; do
    iptables -t "$table" -D "$@" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || break
  done
  return "$rc"
}

validate_rule_runtime() {
  local bind_ip="$1"
  local listen_port="$2"
  local target_ip="$3"
  local target_port="$4"
  local snat_ip="$5"

  validate_ipv4 "$bind_ip" || { echo "监听IP格式不合法: $bind_ip"; return 1; }
  validate_ipv4 "$target_ip" || { echo "目标IP格式不合法: $target_ip"; return 1; }
  validate_ipv4 "$snat_ip" || { echo "出口源IP格式不合法: $snat_ip"; return 1; }
  validate_port "$listen_port" || { echo "监听端口不合法: $listen_port"; return 1; }
  validate_port "$target_port" || { echo "目标端口不合法: $target_port"; return 1; }

  is_local_ipv4 "$bind_ip" || { echo "监听IP不在本机: $bind_ip"; return 1; }
  is_local_ipv4 "$snat_ip" || { echo "出口源IP不在本机: $snat_ip"; return 1; }

  if [[ "$bind_ip" == "$target_ip" && "$listen_port" == "$target_port" ]]; then
    echo "禁止创建/启动自环规则: ${bind_ip}:${listen_port} -> ${target_ip}:${target_port}"
    return 1
  fi

  if ! ip route get "$target_ip" >/dev/null 2>&1; then
    echo "系统未找到到目标IP的路由: $target_ip"
    return 1
  fi

  return 0
}

find_rule_conflict_id() {
  local bind_ip="$1"
  local listen_port="$2"
  local exclude_id="${3:-}"
  awk -F'|' -v bind_ip="$bind_ip" -v listen_port="$listen_port" -v exclude_id="$exclude_id" '
    $1 != exclude_id && $2 == bind_ip && $3 == listen_port { print $1; exit }
  ' "$RULES_FILE"
}

get_route_line() {
  local from_ip="$1"
  local target_ip="$2"
  local route
  route="$(ip route get "$target_ip" from "$from_ip" 2>/dev/null | head -n1)"
  if [[ -z "$route" ]]; then
    route="$(ip route get "$target_ip" 2>/dev/null | head -n1)"
  fi
  printf '%s' "$route"
}

get_route_fields() {
  local from_ip="$1"
  local target_ip="$2"
  local route dev via src
  route="$(get_route_line "$from_ip" "$target_ip")"
  if [[ -n "$route" ]]; then
    dev="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "$route")"
    via="$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<< "$route")"
    src="$(awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' <<< "$route")"
  fi
  printf '%s|%s|%s|%s' "$dev" "$via" "$src" "$route"
}

declare -a IFACE_NAMES=()
declare -a IFACE_IPS=()
declare -a IFACE_PUBLIC_IPS=()
SELECTED_BIND_IP=""
SELECTED_EGRESS_IP=""
DETECTED_PRIMARY_PUBLIC_IP=""
DEFAULT_ROUTE_IFACE=""
PUBLIC_IP_DETECT_ATTEMPTED=0

is_privateish_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10[.] ]] && return 0
  [[ "$ip" =~ ^192[.]168[.] ]] && return 0
  [[ "$ip" =~ ^172[.](1[6-9]|2[0-9]|3[0-1])[.] ]] && return 0
  [[ "$ip" =~ ^100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.] ]] && return 0
  [[ "$ip" =~ ^169[.]254[.] ]] && return 0
  [[ "$ip" =~ ^127[.] ]] && return 0
  [[ "$ip" =~ ^0[.] ]] && return 0
  return 1
}

is_public_ipv4() {
  local ip="$1"
  is_ipv4_maybe "$ip" || return 1
  is_privateish_ipv4 "$ip" && return 1
  return 0
}

http_get_quiet() {
  local url="$1"
  curl -fsS --connect-timeout 1 --max-time 2 "$url" 2>/dev/null | tr -d '
' | head -n1
}

http_get_header_quiet() {
  local header="$1"
  local url="$2"
  curl -fsS --connect-timeout 1 --max-time 2 -H "$header" "$url" 2>/dev/null | tr -d '
' | head -n1
}

http_put_header_quiet() {
  local header="$1"
  local url="$2"
  curl -fsS --connect-timeout 1 --max-time 2 -X PUT -H "$header" "$url" 2>/dev/null | tr -d '
' | head -n1
}

trim_first_ipv4() {
  local value="$1"
  value="$(tr ', ' '
' <<< "$value" | sed '/^$/d' | head -n1)"
  printf '%s' "$value"
}

try_set_detected_public_ip() {
  local candidate="$1"
  candidate="$(trim_first_ipv4 "$candidate")"
  is_public_ipv4 "$candidate" || return 1
  DETECTED_PRIMARY_PUBLIC_IP="$candidate"
  return 0
}

detect_primary_public_ipv4() {
  if [[ "$PUBLIC_IP_DETECT_ATTEMPTED" == "1" ]]; then
    [[ -n "$DETECTED_PRIMARY_PUBLIC_IP" ]]
    return $?
  fi
  PUBLIC_IP_DETECT_ATTEMPTED=1
  DETECTED_PRIMARY_PUBLIC_IP=""

  local token candidate

  token="$(http_put_header_quiet 'X-aliyun-ecs-metadata-token-ttl-seconds: 60' 'http://100.100.100.200/latest/api/token')"
  if [[ -n "$token" ]]; then
    candidate="$(http_get_header_quiet "X-aliyun-ecs-metadata-token: $token" 'http://100.100.100.200/latest/meta-data/eipv4')"
    try_set_detected_public_ip "$candidate" && return 0
    candidate="$(http_get_header_quiet "X-aliyun-ecs-metadata-token: $token" 'http://100.100.100.200/latest/meta-data/public-ipv4')"
    try_set_detected_public_ip "$candidate" && return 0
  fi

  candidate="$(http_get_quiet 'http://100.100.100.200/latest/meta-data/eipv4')"
  try_set_detected_public_ip "$candidate" && return 0
  candidate="$(http_get_quiet 'http://100.100.100.200/latest/meta-data/public-ipv4')"
  try_set_detected_public_ip "$candidate" && return 0

  candidate="$(http_get_quiet 'http://metadata.tencentyun.com/meta-data/public-ipv4')"
  try_set_detected_public_ip "$candidate" && return 0

  candidate="$(http_get_quiet 'https://api.ipify.org')"
  try_set_detected_public_ip "$candidate" && return 0
  candidate="$(http_get_quiet 'https://ipv4.icanhazip.com')"
  try_set_detected_public_ip "$candidate" && return 0
  candidate="$(http_get_quiet 'https://ifconfig.me/ip')"
  try_set_detected_public_ip "$candidate" && return 0

  return 1
}

get_public_display_for_local_ip() {
  local local_ip="$1"
  local i
  for (( i=0; i<${#IFACE_IPS[@]}; i++ )); do
    if [[ "${IFACE_IPS[$i]}" == "$local_ip" ]]; then
      printf '%s' "${IFACE_PUBLIC_IPS[$i]}"
      return 0
    fi
  done
  if is_public_ipv4 "$local_ip"; then
    printf '%s' "$local_ip"
    return 0
  fi
  return 1
}

format_ip_with_public_hint() {
  local local_ip="$1"
  local public_ip
  public_ip="$(get_public_display_for_local_ip "$local_ip")"
  if [[ -n "$public_ip" && "$public_ip" != "$local_ip" ]]; then
    printf '%s (公网:%s)' "$local_ip" "$public_ip"
  else
    printf '%s' "$local_ip"
  fi
}

format_entry_endpoint() {
  local local_ip="$1"
  local port="$2"
  local public_ip
  public_ip="$(get_public_display_for_local_ip "$local_ip")"
  if [[ -n "$public_ip" && "$public_ip" != "$local_ip" ]]; then
    printf '%s:%s (本机:%s:%s)' "$public_ip" "$port" "$local_ip" "$port"
  else
    printf '%s:%s' "$local_ip" "$port"
  fi
}

format_remark_for_table() {
  local remark="$1"
  local max_len=18
  local len=${#remark}
  [[ -n "$remark" ]] || { printf '--'; return; }
  if (( len > max_len )); then
    printf '%s…' "${remark:0:max_len}"
  else
    printf '%s' "$remark"
  fi
}

format_egress_for_table() {
  local bind_ip="$1"
  local snat_ip="$2"
  if [[ "$bind_ip" == "$snat_ip" ]]; then
    printf '同入口IP'
    return 0
  fi
  format_ip_with_public_hint "$snat_ip"
}

iface_ip_exists() {
  local ip="$1"
  local i
  for (( i=0; i<${#IFACE_IPS[@]}; i++ )); do
    [[ "${IFACE_IPS[$i]}" == "$ip" ]] && return 0
  done
  return 1
}

append_iface_entry() {
  local iface="$1"
  local ip="$2"
  local public_ip="$3"

  iface_ip_exists "$ip" && return 0
  IFACE_NAMES+=("$iface")
  IFACE_IPS+=("$ip")
  IFACE_PUBLIC_IPS+=("$public_ip")
}

load_interfaces() {
  IFACE_NAMES=()
  IFACE_IPS=()
  IFACE_PUBLIC_IPS=()
  DEFAULT_ROUTE_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  if [[ "$PUBLIC_IP_DETECT_ATTEMPTED" == "0" ]]; then
    detect_primary_public_ipv4 >/dev/null 2>&1 || true
  fi

  local line iface cidr ip public_ip
  while IFS= read -r line; do
    iface="$(awk '{print $2}' <<< "$line")"
    cidr="$(awk '{print $4}' <<< "$line")"
    iface="${iface%@*}"
    ip="${cidr%%/*}"

    [[ -n "$iface" && -n "$ip" ]] || continue
    [[ "$ip" == "127.0.0.1" ]] && continue

    public_ip=""
    if is_public_ipv4 "$ip"; then
      public_ip="$ip"
    elif [[ -n "$DETECTED_PRIMARY_PUBLIC_IP" && -n "$DEFAULT_ROUTE_IFACE" && "$iface" == "$DEFAULT_ROUTE_IFACE" ]]; then
      public_ip="$DETECTED_PRIMARY_PUBLIC_IP"
    fi

    append_iface_entry "$iface" "$ip" "$public_ip"
  done < <(ip -o -4 addr show up 2>/dev/null)

  if [[ ${#IFACE_IPS[@]} -eq 0 ]] && command -v ifconfig >/dev/null 2>&1; then
    while IFS= read -r line; do
      iface="$(awk '{print $1}' <<< "$line")"
      ip="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^inet$/ || $i ~ /^inetaddr:/) {print $(i+1); exit}}' <<< "$line")"
      ip="${ip#addr:}"
      [[ -n "$iface" && -n "$ip" ]] || continue
      [[ "$ip" == "127.0.0.1" ]] && continue

      public_ip=""
      if is_public_ipv4 "$ip"; then
        public_ip="$ip"
      elif [[ -n "$DETECTED_PRIMARY_PUBLIC_IP" && -n "$DEFAULT_ROUTE_IFACE" && "$iface" == "$DEFAULT_ROUTE_IFACE" ]]; then
        public_ip="$DETECTED_PRIMARY_PUBLIC_IP"
      fi

      append_iface_entry "$iface" "$ip" "$public_ip"
    done < <(ifconfig 2>/dev/null | awk '
      /^[a-zA-Z0-9]/ {iface=$1}
      /inet / || /inet addr:/ {print iface, $0}
    ')
  fi
}

get_ip_role_hint() {
  local ip="$1"
  if [[ "$ip" =~ ^10[.] || "$ip" =~ ^192[.]168[.] || "$ip" =~ ^172[.](1[6-9]|2[0-9]|3[0-1])[.] ]]; then
    echo "常见私网"
  elif [[ "$ip" =~ ^100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.] ]]; then
    echo "CGNAT/运营商内网"
  elif [[ "$ip" =~ ^169[.]254[.] ]]; then
    echo "链路本地"
  else
    echo "可路由IPv4"
  fi
}

select_ip_for_role() {
  local role="$1"
  local title="$2"
  load_interfaces

  if [[ ${#IFACE_IPS[@]} -eq 0 ]]; then
    return 1
  fi

  while true; do
    clear_screen
    line 72
    echo " $title"
    line 72
    echo
    echo " 说明：云厂商公网IP通常通过NAT映射到实例私网IP。此处会显示公网映射，但规则实际仍绑定本机私网IP。"
    echo
    local i choice public_ip
    for (( i=0; i<${#IFACE_IPS[@]}; i++ )); do
      public_ip="${IFACE_PUBLIC_IPS[$i]}"
      if [[ -n "$public_ip" && "$public_ip" != "${IFACE_IPS[$i]}" ]]; then
        echo " $((i+1))) ${IFACE_NAMES[$i]}   内网:${IFACE_IPS[$i]}   公网:${public_ip}   [$(get_ip_role_hint "${IFACE_IPS[$i]}")]"
      else
        echo " $((i+1))) ${IFACE_NAMES[$i]}   IP:${IFACE_IPS[$i]}   [$(get_ip_role_hint "${IFACE_IPS[$i]}")]"
      fi
    done
    echo
    echo " 0) 返回"
    echo
    read -r -p "请输入选项 [0-${#IFACE_IPS[@]}]: " choice
    choice="$(trim "$choice")"
    if [[ "$choice" == "0" ]]; then
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#IFACE_IPS[@]} )); then
      if [[ "$role" == "egress" ]]; then
        SELECTED_EGRESS_IP="${IFACE_IPS[$((choice-1))]}"
      else
        SELECTED_BIND_IP="${IFACE_IPS[$((choice-1))]}"
      fi
      return 0
    fi
  done
}

select_interface() {
  select_ip_for_role custom "选择自定义监听IP"
}

select_egress_ip() {
  select_ip_for_role egress "选择出口源IP"
}

port_in_use_info() {
  local bind_ip="$1"
  local port="$2"
  ss -lnuH 2>/dev/null | awk -v ip="$bind_ip" -v port="$port" '
    {
      addr=$5
      if (addr == ip ":" port || addr == "*" ":" port || addr == "0.0.0.0:" port || addr == "[::]:" port) print
    }' | sed 's/^/  /'
}

save_rule() {
  local bind_ip="$1"
  local listen_port="$2"
  local target_ip="$3"
  local target_port="$4"
  local snat_ip="$5"
  local remark="$6"
  local id
  id="$(next_rule_id)"
  remark="$(sanitize_remark "$remark")"
  echo "${id}|${bind_ip}|${listen_port}|${target_ip}|${target_port}|${snat_ip}|${remark}" >> "$RULES_FILE"
  echo "$id"
}

ensure_sysctl_ready() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || return 1
  sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
  return 0
}

mark_value() {
  local id="$1"
  echo $(( id * 10 + 2 ))
}

rule_comment() {
  local id="$1"
  echo "L2TP_${id}_udp"
}

rule_mark_hex() {
  local id="$1"
  printf '0x%x' "$(mark_value "$id")"
}

rule_count_by_values() {
  local id="$1"
  local bind_ip="$2"
  local listen_port="$3"
  local target_ip="$4"
  local target_port="$5"
  local snat_ip="$6"

  local comment mark count=0
  comment="$(rule_comment "$id")"
  mark="$(mark_value "$id")"

  iptables_has_rule mangle PREROUTING -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j MARK --set-mark "$mark" && ((count++))
  iptables_has_rule mangle OUTPUT     -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j MARK --set-mark "$mark" && ((count++))

  iptables_has_rule nat PREROUTING -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j DNAT --to-destination "${target_ip}:${target_port}" && ((count++))
  iptables_has_rule nat OUTPUT     -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j DNAT --to-destination "${target_ip}:${target_port}" && ((count++))

  iptables_has_rule filter FORWARD -p udp -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT && ((count++))
  iptables_has_rule filter FORWARD -p udp -s "$target_ip" --sport "$target_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT && ((count++))

  iptables_has_rule nat POSTROUTING -m mark --mark "$mark" -p udp -m comment --comment "$comment" -j SNAT --to-source "$snat_ip" && ((count++))
  echo "$count"
}

status_from_count() {
  local count="$1"
  if (( count >= 7 )); then
    echo "运行中"
  elif (( count > 0 )); then
    echo "部分异常(${count}/7)"
  else
    echo "已停止"
  fi
}

rule_status_by_id() {
  local id="$1"
  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || { echo "规则不存在"; return 1; }
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"
  local count
  count="$(rule_count_by_values "$id" "$bind_ip" "$listen_port" "$target_ip" "$target_port" "$snat_ip")"
  status_from_count "$count"
}

start_rule_runtime() {
  local id="$1"
  local bind_ip="$2"
  local listen_port="$3"
  local target_ip="$4"
  local target_port="$5"
  local snat_ip="$6"

  local comment mark rc=0 validate_msg
  comment="$(rule_comment "$id")"
  mark="$(mark_value "$id")"

  if ! validate_msg="$(validate_rule_runtime "$bind_ip" "$listen_port" "$target_ip" "$target_port" "$snat_ip" 2>&1)"; then
    append_rule_log "$id" "启动前校验失败: $validate_msg"
    return 1
  fi

  if ! ensure_sysctl_ready; then
    append_rule_log "$id" "sysctl 设置失败: net.ipv4.ip_forward 或 route_localnet 写入失败"
    return 1
  fi

  iptables_add_unique_logged "$id" mangle PREROUTING -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j MARK --set-mark "$mark" || rc=1
  iptables_add_unique_logged "$id" mangle OUTPUT     -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j MARK --set-mark "$mark" || rc=1

  iptables_add_unique_logged "$id" nat PREROUTING -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j DNAT --to-destination "${target_ip}:${target_port}" || rc=1
  iptables_add_unique_logged "$id" nat OUTPUT     -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j DNAT --to-destination "${target_ip}:${target_port}" || rc=1

  iptables_add_unique_logged "$id" filter FORWARD -p udp -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT || rc=1
  iptables_add_unique_logged "$id" filter FORWARD -p udp -s "$target_ip" --sport "$target_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT || rc=1

  iptables_add_unique_logged "$id" nat POSTROUTING -m mark --mark "$mark" -p udp -m comment --comment "$comment" -j SNAT --to-source "$snat_ip" || rc=1

  if [[ "$rc" -eq 0 ]]; then
    append_rule_log "$id" "NAT规则已启动：${bind_ip}:${listen_port} -> ${target_ip}:${target_port}（SNAT=${snat_ip}，mark=${mark}）"
    return 0
  fi

  append_rule_log "$id" "NAT规则启动存在失败项：${bind_ip}:${listen_port} -> ${target_ip}:${target_port}（SNAT=${snat_ip}，mark=${mark}）"
  return 1
}

stop_rule_runtime_quiet() {
  local id="$1"

  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || return 0
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  local comment mark rc=0
  comment="$(rule_comment "$id")"
  mark="$(mark_value "$id")"

  iptables_del_if_exists_logged "$id" nat POSTROUTING -m mark --mark "$mark" -p udp -m comment --comment "$comment" -j SNAT --to-source "$snat_ip" || rc=1

  iptables_del_if_exists_logged "$id" filter FORWARD -p udp -s "$target_ip" --sport "$target_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT || rc=1
  iptables_del_if_exists_logged "$id" filter FORWARD -p udp -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT || rc=1

  iptables_del_if_exists_logged "$id" nat OUTPUT     -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j DNAT --to-destination "${target_ip}:${target_port}" || rc=1
  iptables_del_if_exists_logged "$id" nat PREROUTING -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j DNAT --to-destination "${target_ip}:${target_port}" || rc=1

  iptables_del_if_exists_logged "$id" mangle OUTPUT     -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j MARK --set-mark "$mark" || rc=1
  iptables_del_if_exists_logged "$id" mangle PREROUTING -d "$bind_ip" -p udp --dport "$listen_port" -m comment --comment "$comment" -j MARK --set-mark "$mark" || rc=1

  if [[ "$rc" -eq 0 ]]; then
    append_rule_log "$id" "NAT规则已停止：${bind_ip}:${listen_port} -> ${target_ip}:${target_port}"
  else
    append_rule_log "$id" "NAT规则停止时存在失败项：${bind_ip}:${listen_port} -> ${target_ip}:${target_port}"
  fi
  return 0
}

start_rule_by_id() {
  local id="$1"
  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || return 1
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  stop_rule_runtime_quiet "$id"
  start_rule_runtime "$id" "$bind_ip" "$listen_port" "$target_ip" "$target_port" "$snat_ip"
}

delete_rule_by_id() {
  local id="$1"
  local line_data
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || return 1

  local running_ids_file map_file old_id new_id
  running_ids_file="$(mktemp)"
  while IFS='|' read -r old_id _; do
    [[ -n "${old_id:-}" ]] || continue
    [[ "$old_id" == "$id" ]] && continue
    if [[ "$(rule_status_by_id "$old_id")" == "运行中" ]]; then
      echo "$old_id" >> "$running_ids_file"
    fi
  done < "$RULES_FILE"

  stop_rule_runtime_quiet "$id"
  while IFS='|' read -r old_id _; do
    [[ -n "${old_id:-}" ]] || continue
    [[ "$old_id" == "$id" ]] && continue
    stop_rule_runtime_quiet "$old_id"
  done < "$RULES_FILE"

  awk -F'|' -v id="$id" '$1!=id' "$RULES_FILE" > "${RULES_FILE}.tmp" && mv "${RULES_FILE}.tmp" "$RULES_FILE"
  rm -f "$(log_file "$id")"

  map_file="$(renumber_rules_file)"
  if [[ -n "$map_file" && -f "$map_file" ]]; then
    relink_rule_logs_by_map "$map_file"
    while IFS='|' read -r old_id new_id; do
      [[ -n "${old_id:-}" && -n "${new_id:-}" ]] || continue
      if grep -qx "$old_id" "$running_ids_file" 2>/dev/null; then
        start_rule_by_id "$new_id" >/dev/null 2>&1 || true
      fi
    done < "$map_file"
    rm -f "$map_file"
  fi
  rm -f "$running_ids_file"
}

renumber_rules_file() {
  [[ -f "$RULES_FILE" ]] || return 0

  local tmp map_file
  tmp="$(mktemp)"
  map_file="$(mktemp)"
  local idx=0 id bind_ip listen_port target_ip target_port snat_ip remark

  while IFS='|' read -r id bind_ip listen_port target_ip target_port snat_ip remark _; do
    [[ -n "${id:-}" ]] || continue
    idx=$((idx + 1))
    echo "${idx}|${bind_ip}|${listen_port}|${target_ip}|${target_port}|${snat_ip}|${remark}" >> "$tmp"
    echo "${id}|${idx}" >> "$map_file"
  done < "$RULES_FILE"

  mv "$tmp" "$RULES_FILE"
  printf '%s\n' "$map_file"
}

relink_rule_logs_by_map() {
  local map_file="$1"
  local old_id new_id old_log new_log
  [[ -f "$map_file" ]] || return 0

  while IFS='|' read -r old_id new_id; do
    [[ -n "${old_id:-}" && -n "${new_id:-}" ]] || continue
    [[ "$old_id" == "$new_id" ]] && continue
    old_log="$(log_file "$old_id")"
    new_log="$(log_file "$new_id")"
    [[ -f "$old_log" ]] || continue
    if [[ -f "$new_log" ]]; then
      cat "$old_log" >> "$new_log"
      rm -f "$old_log"
    else
      mv "$old_log" "$new_log"
    fi
  done < "$map_file"
}

update_rule_by_id() {
  local id="$1"
  local bind_ip="$2"
  local listen_port="$3"
  local target_ip="$4"
  local target_port="$5"
  local snat_ip="$6"
  local remark="$7"

  remark="$(sanitize_remark "$remark")"
  awk -F'|' -v id="$id" -v bind_ip="$bind_ip" -v listen_port="$listen_port" \
    -v target_ip="$target_ip" -v target_port="$target_port" -v snat_ip="$snat_ip" -v remark="$remark" \
    'BEGIN{OFS="|"} $1==id {$2=bind_ip;$3=listen_port;$4=target_ip;$5=target_port;$6=snat_ip;$7=remark} {print}' \
    "$RULES_FILE" > "${RULES_FILE}.tmp" && mv "${RULES_FILE}.tmp" "$RULES_FILE"
}

format_bytes() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

  local units=(B KB MB GB TB PB)
  local idx=0 value
  value="$bytes"

  while (( value >= 1024 && idx < ${#units[@]} - 1 )); do
    value=$(( value / 1024 ))
    idx=$(( idx + 1 ))
  done

  if (( idx == 0 )); then
    printf '%s%s' "$value" "${units[$idx]}"
  else
    local decimal=$(( (bytes * 10 / (1024 ** idx)) % 10 ))
    printf '%s.%s%s' "$value" "$decimal" "${units[$idx]}"
  fi
}

get_forward_bytes_by_values() {
  local id="$1"
  local direction="$2"
  local target_ip="$3"
  local target_port="$4"
  local comment bytes=0
  comment="$(rule_comment "$id")"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$direction" in
      down)
        if [[ "$line" == *"$comment"* && "$line" == *"$target_ip"* && "$line" == *"dpt:$target_port"* ]]; then
          set -- $line
          [[ "${2:-}" =~ ^[0-9]+$ ]] && bytes=$(( bytes + $2 ))
        fi
        ;;
      up)
        if [[ "$line" == *"$comment"* && "$line" == *"$target_ip"* && "$line" == *"spt:$target_port"* ]]; then
          set -- $line
          [[ "${2:-}" =~ ^[0-9]+$ ]] && bytes=$(( bytes + $2 ))
        fi
        ;;
    esac
  done < <(iptables -t filter -vnxL FORWARD 2>/dev/null)

  echo "$bytes"
}

rule_traffic_summary_by_id() {
  local id="$1"
  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || { echo '0|0|0'; return 1; }
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  local down_total up_total all_total
  down_total="$(get_forward_bytes_by_values "$id" down "$target_ip" "$target_port")"
  up_total="$(get_forward_bytes_by_values "$id" up "$target_ip" "$target_port")"
  all_total=$(( down_total + up_total ))

  echo "${up_total}|${down_total}|${all_total}"
}

print_rules_table() {
  load_interfaces
  echo "编号 | 客户入口UDP(公网优先) | 服务端UDP | 出口源IP | 限速 | UDP状态 | 返回流量 | 去目标流量 | 总流量 | 下一跳 | 备注(截断)"
  subline 214
  local found=0
  while IFS='|' read -r id bind_ip listen_port target_ip target_port snat_ip remark _; do
    [[ -n "${id:-}" ]] || continue
    found=1

    local udp_status route_fields dev via src route traffic_summary up_bytes down_bytes total_bytes
    udp_status="$(rule_status_by_id "$id")"
    route_fields="$(get_route_fields "$snat_ip" "$target_ip")"
    IFS='|' read -r dev via src route <<< "$route_fields"
    traffic_summary="$(rule_traffic_summary_by_id "$id")"
    IFS='|' read -r up_bytes down_bytes total_bytes <<< "$traffic_summary"

    echo "$id | $(format_entry_endpoint "$bind_ip" "$listen_port") | ${target_ip}:${target_port} | $(format_egress_for_table "$bind_ip" "$snat_ip") | $(format_remark_for_table "$(limit_text_for_port "$listen_port")") | ${udp_status} | $(format_bytes "$up_bytes") | $(format_bytes "$down_bytes") | $(format_bytes "$total_bytes") | ${via:-直连} | $(format_remark_for_table "${remark:--}")"
  done < "$RULES_FILE"
  if [[ $found -eq 0 ]]; then
    echo "暂无规则"
  fi
}

edit_rule_menu() {
  clear_screen
  line 44
  echo " 修改转发规则"
  line 44
  echo
  print_rules_table
  echo

  local id
  read -r -p "请输入要修改的规则编号: " id
  id="$(trim "$id")"
  [[ "$id" =~ ^[0-9]+$ ]] || { show_message "规则编号不合法。"; return; }

  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || { show_message "规则编号不存在。"; return; }
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  local new_target_ip new_target_port new_snat_ip new_remark
  echo "当前配置："
  echo "客户入口UDP：$(format_entry_endpoint "$bind_ip" "$listen_port")"
  echo "服务端UDP：${target_ip}:${target_port}"
  echo "出口源IP：$(format_ip_with_public_hint "$snat_ip")"
  echo "备注：${remark:--}"
  echo

  while true; do
    read -r -p "目标服务端IP [当前: $target_ip]: " new_target_ip
    new_target_ip="$(trim "$new_target_ip")"
    new_target_ip="${new_target_ip:-$target_ip}"
    validate_ipv4 "$new_target_ip" && break
    echo "目标IP格式不合法，请输入正确的 IPv4。"
  done

  while true; do
    read -r -p "目标服务端端口 [当前: $target_port]: " new_target_port
    new_target_port="$(trim "$new_target_port")"
    new_target_port="${new_target_port:-$target_port}"
    validate_port "$new_target_port" && break
    echo "目标端口不合法，请重新输入。"
  done

  new_snat_ip="$snat_ip"
  if confirm "是否重新选择出口源IP？"; then
    if ! select_egress_ip; then
      show_message "未选择出口源IP，已返回。"
      return
    fi
    new_snat_ip="$SELECTED_EGRESS_IP"
  fi

  read -r -p "备注 [当前: ${remark:--}]: " new_remark
  new_remark="$(trim "$new_remark")"
  new_remark="${new_remark:-$remark}"

  if [[ "$bind_ip" == "$new_target_ip" && "$listen_port" == "$new_target_port" ]]; then
    show_message "修改失败：禁止自环规则。"
    return
  fi

  local validate_msg was_running
  if ! validate_msg="$(validate_rule_runtime "$bind_ip" "$listen_port" "$new_target_ip" "$new_target_port" "$new_snat_ip" 2>&1)"; then
    show_message "修改失败：$validate_msg"
    return
  fi
  was_running=0
  [[ "$(rule_status_by_id "$id")" == "运行中" ]] && was_running=1

  stop_rule_runtime_quiet "$id"
  update_rule_by_id "$id" "$bind_ip" "$listen_port" "$new_target_ip" "$new_target_port" "$new_snat_ip" "$new_remark"
  append_rule_log "$id" "规则已修改：${bind_ip}:${listen_port} -> ${new_target_ip}:${new_target_port}（SNAT=${new_snat_ip}）"

  if (( was_running == 1 )); then
    if start_rule_by_id "$id" >/dev/null 2>&1; then
      show_message "规则修改成功，并已自动重启。"
    else
      show_message "规则已修改，但自动重启失败，请查看运行日志。"
    fi
  else
    show_message "规则修改成功。"
  fi
}

show_rules_menu() {
  clear_screen
  line 54
  echo " $APP_NAME $APP_VERSION"
  line 54
  echo " 转发规则总览"
  line 54
  echo
  print_rules_table
  pause
}

show_return_path() {
  local bind_ip="$1"
  local target_ip="$2"
  local target_port="${3:-}"
  local snat_ip="${4:-$bind_ip}"
  local route dev via src bind_public_ip snat_public_ip

  load_interfaces
  bind_public_ip="$(get_public_display_for_local_ip "$bind_ip")"
  snat_public_ip="$(get_public_display_for_local_ip "$snat_ip")"
  route="$(get_route_line "$snat_ip" "$target_ip")"

  echo "回程显示："
  subline 60
  echo "  监听入口IP(本机实际) : $bind_ip"
  [[ -n "$bind_public_ip" && "$bind_public_ip" != "$bind_ip" ]] && echo "  客户访问公网IP       : $bind_public_ip"
  echo "  转发目标IP           : $target_ip${target_port:+:$target_port}"
  echo "  指定出口IP(本机实际) : $snat_ip"
  [[ -n "$snat_public_ip" && "$snat_public_ip" != "$snat_ip" ]] && echo "  出口公网IP           : $snat_public_ip"

  if [[ -n "$route" ]]; then
    dev="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "$route")"
    via="$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<< "$route")"
    src="$(awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' <<< "$route")"

    echo "  系统路由   : $route"
    [[ -n "$dev" ]] && echo "  出口网卡   : $dev"
    [[ -n "$via" ]] && echo "  下一跳     : $via"
    [[ -n "$src" ]] && echo "  内核源IP   : $src"
    echo "  SNAT后源IP : $snat_ip"

    if [[ -n "$src" && "$src" != "$snat_ip" ]]; then
      echo "  提示       : 系统原始源IP会选 $src，但本规则在 POSTROUTING 阶段会 SNAT 成 $snat_ip"
    else
      echo "  提示       : 当前内核选路与指定出口IP 一致"
    fi
  else
    echo "  系统路由   : 未解析到，请检查目标地址是否可达"
    echo "  SNAT后源IP : $snat_ip"
  fi
}

add_rule_menu() {
  local rule_type bind_ip title

  while true; do
    clear_screen
    line 56
    echo " 新增转发规则"
    line 56
    echo
    echo "请选择规则类型："
    echo " 1) 入口转发（客户 → 本机入口IP → 服务端）"
    echo " 2) 链路中转（本机链路IP → 后端业务）"
    echo " 3) 自定义监听IP"
    echo
    echo " 0) 返回"
    echo
    read -r -p "请输入选项 [0-3]: " rule_type
    rule_type="$(trim "$rule_type")"
    case "$rule_type" in
      0) return ;;
      1)
        if ! select_ip_for_role entry "选择入口监听IP"; then
          show_message "未检测到可用 IPv4。"
          return
        fi
        title="入口转发"
        break
        ;;
      2)
        if ! select_ip_for_role relay "选择链路中转监听IP"; then
          show_message "未检测到可用 IPv4。"
          return
        fi
        title="链路中转"
        break
        ;;
      3)
        select_interface || return
        title="自定义监听转发"
        break
        ;;
      *) ;;
    esac
  done

  bind_ip="$SELECTED_BIND_IP"

  clear_screen
  line 56
  echo " $title"
  line 56
  echo
  local bind_public_ip snat_public_ip
  load_interfaces
  bind_public_ip="$(get_public_display_for_local_ip "$bind_ip")"
  echo "已选择监听IP(本机实际绑定): $bind_ip [$(get_ip_role_hint "$bind_ip")]"
  if [[ -n "$bind_public_ip" && "$bind_public_ip" != "$bind_ip" ]]; then
    echo "公网访问地址(云厂商映射): $bind_public_ip"
  fi
  echo

  local listen_port
  while true; do
    read -r -p "请输入客户连接端口(UDP监听端口，如10001): " listen_port
    listen_port="$(trim "$listen_port")"
    validate_port "$listen_port" && break
    echo "监听端口不合法，请重新输入。"
  done

  local inuse
  inuse="$(port_in_use_info "$bind_ip" "$listen_port")"
  if [[ -n "$inuse" ]]; then
    echo
    echo "提示：${bind_ip}:${listen_port} 当前已有本地 UDP 监听："
    echo "$inuse"
    echo
    confirm "是否继续创建规则？" || return
  fi

  local conflict_id
  conflict_id="$(find_rule_conflict_id "$bind_ip" "$listen_port")"
  if [[ -n "$conflict_id" ]]; then
    show_message "创建失败：${bind_ip}:${listen_port} 已被规则 ${conflict_id} 使用。"
    return
  fi

  local target_ip target_port snat_ip remark port_mode
  while true; do
    read -r -p "请输入目标服务端IP: " target_ip
    target_ip="$(trim "$target_ip")"
    [[ -n "$target_ip" ]] || { echo "目标IP不能为空。"; continue; }
    validate_ipv4 "$target_ip" && break
    echo "目标IP格式不合法，请输入正确的 IPv4。"
  done

  echo
  echo "请选择目标端口模式："
  echo " 1) 纯L2TP固定端口（1701）"
  echo " 2) 同端口转发（目标端口 = 监听端口）"
  echo " 3) 自定义目标端口"
  echo
  while true; do
    read -r -p "请输入选项 [默认3]: " port_mode
    port_mode="$(trim "$port_mode")"
    port_mode="${port_mode:-3}"
    case "$port_mode" in
      1)
        target_port="1701"
        echo "已选择：纯L2TP固定端口，目标端口 = 1701"
        break
        ;;
      2)
        target_port="$listen_port"
        echo "已选择：同端口转发，目标端口 = ${target_port}"
        break
        ;;
      3)
        while true; do
          read -r -p "请输入目标端口 [默认1701]: " target_port
          target_port="$(trim "$target_port")"
          target_port="${target_port:-1701}"
          validate_port "$target_port" && break
          echo "目标端口不合法，请重新输入。"
        done
        break
        ;;
      *)
        echo "无效选项，请重新输入。"
        ;;
    esac
  done

  if [[ "$bind_ip" == "$target_ip" && "$listen_port" == "$target_port" ]]; then
    show_message "创建失败：禁止自环规则。"
    return
  fi

  echo
  if ! select_egress_ip; then
    show_message "未选择出口源IP，已返回。"
    return
  fi
  snat_ip="$SELECTED_EGRESS_IP"
  load_interfaces
  snat_public_ip="$(get_public_display_for_local_ip "$snat_ip")"

  read -r -p "请输入备注（可选）: " remark
  remark="$(sanitize_remark "$remark")"

  echo
  echo "规则类型：$title"
  echo "客户入口UDP：$(format_entry_endpoint "$bind_ip" "$listen_port")"
  echo "服务端UDP：${target_ip}:${target_port}"
  echo "出口源IP：$(format_ip_with_public_hint "$snat_ip")"
  echo "备注：${remark:--}"
  echo
  echo "协议：仅 UDP NAT 转发（适用于 L2TP，支持非标入口端口）"
  echo "启动方式：规则创建后默认自动启动"
  echo
  show_return_path "$bind_ip" "$target_ip" "$target_port" "$snat_ip"
  echo

  if confirm "确认创建规则？"; then
    local id
    id="$(save_rule "$bind_ip" "$listen_port" "$target_ip" "$target_port" "$snat_ip" "$remark")"
    if [[ "$AUTO_START_ON_CREATE" == "1" ]]; then
      if start_rule_by_id "$id" >/dev/null 2>&1; then
        show_message "规则创建成功，并已执行自动启动。

编号：$id
客户入口UDP：$(format_entry_endpoint "$bind_ip" "$listen_port")
服务端UDP：${target_ip}:${target_port}
出口源IP：$(format_ip_with_public_hint "$snat_ip")

UDP 状态：$(rule_status_by_id "$id")"
      else
        show_message "规则已创建，但自动启动失败。

编号：$id
客户入口UDP：$(format_entry_endpoint "$bind_ip" "$listen_port")
服务端UDP：${target_ip}:${target_port}
出口源IP：$(format_ip_with_public_hint "$snat_ip")

请查看运行日志。"
      fi
    else
      show_message "规则创建成功。编号：$id"
    fi
  fi
}

delete_rule_menu() {
  clear_screen
  line 44
  echo " 删除转发规则"
  line 44
  echo
  print_rules_table
  echo
  local id
  read -r -p "请输入要删除的规则编号: " id
  id="$(trim "$id")"
  [[ "$id" =~ ^[0-9]+$ ]] || { show_message "规则编号不合法。"; return; }

  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || { show_message "规则编号不存在。"; return; }
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  echo
  load_interfaces
  echo "编号：$id"
  echo "客户入口UDP：$(format_entry_endpoint "$bind_ip" "$listen_port")"
  echo "服务端UDP：${target_ip}:${target_port}"
  echo "出口源IP：$(format_ip_with_public_hint "$snat_ip")"
  echo "备注：${remark}"
  echo

  if confirm "确认删除规则？"; then
    delete_rule_by_id "$id"
    show_message "规则已删除。"
  fi
}

show_limits_table() {
  echo "限速ID | 端口范围 | 速率(Mbps) | 备注"
  subline 64
  local found=0 id spec rate remark
  while IFS='|' read -r id spec rate remark _; do
    [[ -n "${id:-}" ]] || continue
    found=1
    echo "${id} | ${spec} | ${rate} | ${remark:--}"
  done < "$LIMITS_FILE"
  (( found == 1 )) || echo "暂无限速规则"
}

add_limit_menu() {
  clear_screen
  line 44
  echo " 新增端口限速"
  line 44
  echo
  show_limits_table
  echo

  local raw_spec spec rate remark id
  if ! iptables -m hashlimit -h >/dev/null 2>&1; then
    show_message "当前系统 iptables 不支持 hashlimit 模块，无法启用限速。"
    return
  fi

  while true; do
    read -r -p "请输入端口范围(如 10001-10005 或 10001,10003): " raw_spec
    raw_spec="$(trim "$raw_spec")"
    spec="$(normalize_port_spec "$raw_spec")" && break
    echo "端口范围格式不合法，请重试。"
  done
  if (( $(port_spec_item_count "$spec") > 15 )); then
    show_message "端口段数量超过 iptables multiport 上限（最多15段），请拆分成多条限速规则。"
    return
  fi

  while true; do
    read -r -p "请输入限速(Mbps，如50): " rate
    rate="$(trim "$rate")"
    validate_rate_mbps "$rate" && break
    echo "限速值不合法，请输入大于0的数字。"
  done

  read -r -p "请输入备注（可选）: " remark
  remark="$(sanitize_remark "$remark")"
  id="$(save_limit_rule "$spec" "$rate" "$remark")"
  if start_limit_by_id "$id" >/dev/null 2>&1; then
    show_message "限速规则创建成功：ID=${id}，端口=${spec}，速率=${rate}Mbps"
  else
    awk -F'|' -v id="$id" '$1!=id' "$LIMITS_FILE" > "${LIMITS_FILE}.tmp" && mv "${LIMITS_FILE}.tmp" "$LIMITS_FILE"
    renumber_limits_file
    show_message "限速规则已保存，但应用失败，请检查 iptables/hashlimit 模块。"
  fi
}

delete_limit_menu() {
  clear_screen
  line 44
  echo " 删除端口限速"
  line 44
  echo
  show_limits_table
  echo

  local id
  read -r -p "请输入要删除的限速ID: " id
  id="$(trim "$id")"
  [[ "$id" =~ ^[0-9]+$ ]] || { show_message "限速ID不合法。"; return; }
  [[ -n "$(get_limit_line "$id")" ]] || { show_message "限速ID不存在。"; return; }

  if confirm "确认删除该限速规则？"; then
    delete_limit_by_id "$id"
    show_message "限速规则已删除。"
  fi
}

limit_menu() {
  while true; do
    clear_screen
    line 44
    echo " 端口限速管理"
    line 44
    echo
    show_limits_table
    echo
    echo "1) 新增限速"
    echo "2) 删除限速"
    echo "0) 返回"
    echo
    read -r -p "请输入选项 [0-2]: " choice
    choice="$(trim "$choice")"
    case "$choice" in
      1) add_limit_menu ;;
      2) delete_limit_menu ;;
      0) return ;;
      *) show_message "无效选项，请重新输入。" ;;
    esac
  done
}

show_rule_counters() {
  local id="$1"
  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || return 0
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  local comment
  comment="$(rule_comment "$id")"

  echo "当前 UDP NAT / FORWARD 规则命中计数（iptables -v）："
  subline 60
  echo "[nat/PREROUTING]"
  iptables -t nat -vnL PREROUTING 2>/dev/null | awk -v bind_ip="$bind_ip" -v listen_port="$listen_port" -v comment="$comment" '
    index($0, comment) || (index($0, bind_ip) && index($0, "dpt:" listen_port)) { print }
  ' || true
  echo
  echo "[filter/FORWARD]"
  iptables -t filter -vnxL FORWARD 2>/dev/null | awk -v target_ip="$target_ip" -v target_port="$target_port" -v comment="$comment" '
    index($0, comment) && index($0, target_ip) && (index($0, "dpt:" target_port) || index($0, "spt:" target_port)) { print }
  ' || true
  echo
  echo "[nat/POSTROUTING]"
  iptables -t nat -vnL POSTROUTING 2>/dev/null | awk -v comment="$comment" '
    index($0, comment) { print }
  ' || true
}

view_log_menu() {
  clear_screen
  line 44
  echo " 查看运行日志"
  line 44
  echo
  print_rules_table
  echo
  local id
  read -r -p "请输入要查看日志的规则编号: " id
  id="$(trim "$id")"
  [[ "$id" =~ ^[0-9]+$ ]] || { show_message "规则编号不合法。"; return; }

  local line_data bind_ip listen_port target_ip target_port snat_ip remark udp_log has_log=0
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || { show_message "规则编号不存在。"; return; }
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  udp_log="$(log_file "$id")"

  clear_screen
  line 68
  echo " 规则 $id 运行日志（UDP NAT版：操作日志 + 当前规则计数，Ctrl+C 返回）"
  line 68
  echo
  show_rule_counters "$id"
  echo
  show_return_path "$bind_ip" "$target_ip" "$target_port" "$snat_ip"
  echo
  echo "UDP 日志: $udp_log"
  echo "出口源IP: $snat_ip"
  echo
  subline 68
  echo

  if [[ -f "$udp_log" ]]; then
    has_log=1
  else
    echo "[提示] UDP 日志文件不存在：$udp_log"
  fi

  if [[ "$has_log" -eq 0 ]]; then
    pause
    return
  fi

  tail -n 100 -F "$udp_log"
}

reconcile_rule_by_id() {
  local id="$1"
  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || { show_message "规则编号不存在。"; return 1; }
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  local check_msg udp_status
  if ! check_msg="$(validate_rule_runtime "$bind_ip" "$listen_port" "$target_ip" "$target_port" "$snat_ip" 2>&1)"; then
    show_message "规则 $id 自检失败：\n\n$check_msg"
    return 1
  fi

  udp_status="$(rule_status_by_id "$id")"

  # 兼容“已停止”和“未启动”的情况：都纳入修复范围
  if [[ "$udp_status" != "运行中" ]]; then
    stop_rule_runtime_quiet "$id"
    if ! start_rule_by_id "$id" >/dev/null 2>&1; then
      udp_status="$(rule_status_by_id "$id")"
      show_message "规则 $id 自检后仍有异常。\n\nUDP：$udp_status\n\n请进入“查看运行日志”查看具体错误。"
      return 1
    fi
    udp_status="$(rule_status_by_id "$id")"
  fi

  if [[ "$udp_status" == "运行中" ]]; then
    show_message "规则 $id 自检并修复完成。\n\nUDP：$udp_status"
    return 0
  fi

  show_message "规则 $id 自检后仍有异常。\n\nUDP：$udp_status\n\n请进入“查看运行日志”查看具体错误。"
  return 1
}

reconcile_all_rules() {
  local ok=0 fail=0 total=0
  local details=""
  local id

  while IFS='|' read -r id _; do
    [[ -n "${id:-}" ]] || continue
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    ((total++))

    local result_msg line_data bind_ip listen_port target_ip target_port snat_ip remark udp_status check_msg
    line_data="$(get_rule_line "$id")"
    if [[ -z "$line_data" ]]; then
      ((fail++))
      details+="规则 $id：规则不存在"$'
'
      continue
    fi
    IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

    if ! check_msg="$(validate_rule_runtime "$bind_ip" "$listen_port" "$target_ip" "$target_port" "$snat_ip" 2>&1)"; then
      ((fail++))
      details+="规则 $id：修复失败（$check_msg）"$'
'
      continue
    fi

    udp_status="$(rule_status_by_id "$id")"
    if [[ "$udp_status" != "运行中" ]]; then
      stop_rule_runtime_quiet "$id"
      start_rule_by_id "$id" >/dev/null 2>&1 || true
      udp_status="$(rule_status_by_id "$id")"
    fi

    if [[ "$udp_status" == "运行中" ]]; then
      ((ok++))
      details+="规则 $id：正常/修复成功"$'
'
    else
      ((fail++))
      details+="规则 $id：修复失败，请查看运行日志"$'
'
    fi
  done < "$RULES_FILE"

  show_message "全部规则自检完成。

总规则数：$total
正常/修复成功：$ok
失败：$fail

${details%$'
'}"
}

self_check_menu() {
  while true; do
    clear_screen
    line 44
    echo " 自检/修复"
    line 44
    echo
    echo "1) 单条规则自检"
    echo "2) 全部规则自检"
    echo "3) 全脚本检查并修复"
    echo
    echo "0) 返回"
    echo

    local choice id line_data
    read -r -p "请输入选项 [0-3]: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1)
        clear_screen
        line 44
        echo " 单条规则自检"
        line 44
        echo
        print_rules_table
        echo
        read -r -p "请输入规则编号: " id
        id="$(trim "$id")"

        if ! [[ "$id" =~ ^[0-9]+$ ]]; then
          show_message "规则编号不合法。"
          continue
        fi

        line_data="$(get_rule_line "$id")"
        if [[ -z "$line_data" ]]; then
          show_message "规则不存在。"
          continue
        fi

        reconcile_rule_by_id "$id"
        ;;
      2)
        reconcile_all_rules
        ;;
      3)
        migrate_rules_file
        migrate_limits_file
        reconcile_all_rules
        reconcile_all_limits
        show_message "全脚本检查并修复已执行完成。\n\n已处理项：\n- 规则文件结构迁移与兼容修复\n- 限速文件格式修复与重排\n- 全部规则运行态自检/修复\n- 限速规则重载"
        ;;
      0)
        return
        ;;
      *)
        show_message "无效选项，请重新输入。"
        ;;
    esac
  done
}

get_chain_counter_packets() {
  local table="$1"
  local chain="$2"
  local pattern1="$3"
  local pattern2="${4:-}"
  local packets=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"$pattern1"* ]] && { [[ -z "$pattern2" ]] || [[ "$line" == *"$pattern2"* ]]; }; then
      set -- $line
      [[ "${1:-}" =~ ^[0-9]+$ ]] && packets=$(( packets + $1 ))
    fi
  done < <(iptables -t "$table" -vnxL "$chain" 2>/dev/null)
  echo "$packets"
}

diagnose_rule_by_id() {
  local id="$1"
  local line_data bind_ip listen_port target_ip target_port snat_ip remark
  line_data="$(get_rule_line "$id")"
  [[ -n "$line_data" ]] || { show_message "规则不存在。"; return 1; }
  IFS='|' read -r _ bind_ip listen_port target_ip target_port snat_ip remark <<< "$line_data"

  local comment markhex udp_status
  comment="$(rule_comment "$id")"
  markhex="$(rule_mark_hex "$id")"
  udp_status="$(rule_status_by_id "$id")"

  local entry_pkts output_entry_pkts forward_down_pkts snat_pkts reply_pkts drop_pkts
  entry_pkts="$(get_chain_counter_packets nat PREROUTING "$comment" "dpt:$listen_port")"
  output_entry_pkts="$(get_chain_counter_packets nat OUTPUT "$comment" "dpt:$listen_port")"
  forward_down_pkts="$(get_chain_counter_packets filter FORWARD "$comment" "dpt:$target_port")"
  snat_pkts="$(get_chain_counter_packets nat POSTROUTING "$comment" "$markhex")"
  reply_pkts="$(get_chain_counter_packets filter FORWARD "$comment" "spt:$target_port")"

  drop_pkts=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"$target_ip"* ]] && ([[ "$line" == *DROP* ]] || [[ "$line" == *REJECT* ]]); then
      set -- $line
      [[ "${1:-}" =~ ^[0-9]+$ ]] && drop_pkts=$(( drop_pkts + $1 ))
    fi
  done < <(iptables -t filter -vnxL FORWARD 2>/dev/null)

  local conclusion
  if [[ "$udp_status" != "运行中" ]]; then
    conclusion="当前规则不在运行中，优先先执行“自检/修复”再观察诊断。"
  elif (( forward_down_pkts > 0 && reply_pkts > 0 )); then
    conclusion="已观察到后端双向流量，未见明显证据表明主要丢在本机转发阶段。若入口或SNAT计数偏低，更多可能是iptables计数口径差异、本机本地流量命中OUTPUT链、或计数刚被清零，建议结合 tcpdump 继续确认。"
  elif (( entry_pkts > 0 && forward_down_pkts == 0 )); then
    conclusion="入口有命中但未见去服务端流量，更像是本机转发阶段未放行或未正确 DNAT。"
  elif (( forward_down_pkts > 0 && snat_pkts == 0 && reply_pkts == 0 )); then
    conclusion="去服务端有命中，但未见SNAT和回包，更像是 MARK/SNAT 未正确命中，或服务端未回包。"
  elif (( forward_down_pkts > 0 && reply_pkts == 0 )); then
    conclusion="去服务端有命中但未见回包，更像是服务端未回包、回程链路丢包，或多节点回偏。"
  elif (( entry_pkts == 0 && output_entry_pkts == 0 && forward_down_pkts == 0 && reply_pkts == 0 )); then
    conclusion="当前没有明显流量命中，暂时无法判断。"
  else
    conclusion="当前计数不足以单独定性，请结合 tcpdump 和运行日志进一步确认。"
  fi

  show_message "规则 $id 丢包诊断：

运行状态：$udp_status
入口命中包(PREROUTING)：$entry_pkts
本机命中包(OUTPUT)：$output_entry_pkts
去服务端包：$forward_down_pkts
SNAT命中包：$snat_pkts
服务端回包：$reply_pkts
DROP/REJECT近似命中：$drop_pkts

结论：$conclusion"
}

diagnose_menu() {
  clear_screen
  line 44
  echo " 丢包诊断"
  line 44
  echo
  print_rules_table
  echo
  local id
  read -r -p "请输入要诊断的规则编号: " id
  id="$(trim "$id")"
  [[ "$id" =~ ^[0-9]+$ ]] || { show_message "规则编号不合法。"; return; }
  diagnose_rule_by_id "$id"
}

reconcile_all_limits() {
  iptables -m hashlimit -h >/dev/null 2>&1 || return 0
  local id spec rate remark
  while IFS='|' read -r id spec rate remark _; do
    [[ -n "${id:-}" ]] || continue
    stop_limit_by_id "$id" >/dev/null 2>&1 || true
    start_limit_by_id "$id" >/dev/null 2>&1 || true
  done < "$LIMITS_FILE"
}

main_menu() {
  while true; do
    clear_screen
    line 44
    printf ' %s %s\n' "$APP_NAME" "$APP_VERSION"
    line 44
    printf '\n'
    printf '1) 查看转发规则\n'
    printf '2) 新增转发规则\n'
    printf '3) 修改转发规则\n'
    printf '4) 删除转发规则\n'
    printf '5) 查看运行日志\n'
    printf '6) 自检/修复\n'
    printf '7) 丢包诊断\n'
    printf '8) 端口限速管理\n'
    printf '0) 退出\n'
    printf '\n'
    subline 44
    read -r -p "请输入选项 [0-8]: " choice
    case "$choice" in
      1) show_rules_menu ;;
      2) add_rule_menu ;;
      3) edit_rule_menu ;;
      4) delete_rule_menu ;;
      5) view_log_menu ;;
      6) self_check_menu ;;
      7) diagnose_menu ;;
      8) limit_menu ;;
      0) clear_screen; exit 0 ;;
      *) show_message "无效选项，请重新输入。" ;;
    esac
  done
}

auto_cleanup_legacy_portfw_rules
migrate_limits_file
reconcile_all_limits
main_menu
