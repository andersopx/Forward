#!/usr/bin/env bash
set -u

APP_NAME="端口转发管理面板"
APP_VERSION="v4.2-cli-l2tp-udp-only-autocleanup-selfcheck-diagnosefix"

BASE_DIR="/opt/portfw_panel"
RULES_FILE="$BASE_DIR/rules.db"
LOG_DIR="$BASE_DIR/logs"
AUTO_START_ON_CREATE=1

mkdir -p "$BASE_DIR" "$LOG_DIR"
touch "$RULES_FILE"

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

if [[ ${#need_install[@]} -gt 0 ]]; then
  if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y iproute2 iptables procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iproute iptables procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iproute iptables procps-ng
  else
    echo "无法自动安装依赖，请手动安装：iproute2 iptables procps"
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
SELECTED_BIND_IP=""
SELECTED_EGRESS_IP=""

load_interfaces() {
  IFACE_NAMES=()
  IFACE_IPS=()

  local line iface cidr ip
  while IFS= read -r line; do
    iface="$(awk '{print $2}' <<< "$line")"
    cidr="$(awk '{print $4}' <<< "$line")"
    iface="${iface%@*}"
    ip="${cidr%%/*}"

    [[ -n "$iface" && -n "$ip" ]] || continue
    [[ "$ip" == "127.0.0.1" ]] && continue

    IFACE_NAMES+=("$iface")
    IFACE_IPS+=("$ip")
  done < <(ip -o -4 addr show up 2>/dev/null)

  if [[ ${#IFACE_IPS[@]} -eq 0 ]] && command -v ifconfig >/dev/null 2>&1; then
    while IFS= read -r line; do
      iface="$(awk '{print $1}' <<< "$line")"
      ip="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^inet$/ || $i ~ /^inetaddr:/) {print $(i+1); exit}}' <<< "$line")"
      ip="${ip#addr:}"
      [[ -n "$iface" && -n "$ip" ]] || continue
      [[ "$ip" == "127.0.0.1" ]] && continue
      IFACE_NAMES+=("$iface")
      IFACE_IPS+=("$ip")
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
    line 62
    echo " $title"
    line 62
    echo
    local i choice
    for (( i=0; i<${#IFACE_IPS[@]}; i++ )); do
      echo " $((i+1))) ${IFACE_NAMES[$i]}   ${IFACE_IPS[$i]}   [$(get_ip_role_hint "${IFACE_IPS[$i]}")]"
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

  stop_rule_runtime_quiet "$id"
  awk -F'|' -v id="$id" '$1!=id' "$RULES_FILE" > "${RULES_FILE}.tmp" && mv "${RULES_FILE}.tmp" "$RULES_FILE"
  append_rule_log "$id" "规则已删除"
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
  echo "编号 | 客户入口UDP | 服务端UDP | 出口源IP | UDP状态 | 返回流量 | 去目标流量 | 总流量 | 出口网卡 | 下一跳 | 备注"
  subline 176
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

    echo "$id | ${bind_ip}:${listen_port} | ${target_ip}:${target_port} | ${snat_ip} | ${udp_status} | $(format_bytes "$up_bytes") | $(format_bytes "$down_bytes") | $(format_bytes "$total_bytes") | ${dev:-未知} | ${via:-直连} | ${remark:--}"
  done < "$RULES_FILE"
  if [[ $found -eq 0 ]]; then
    echo "暂无规则"
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
  local route dev via src

  route="$(get_route_line "$snat_ip" "$target_ip")"

  echo "回程显示："
  subline 60
  echo "  监听入口IP : $bind_ip"
  echo "  转发目标IP : $target_ip${target_port:+:$target_port}"
  echo "  指定出口IP : $snat_ip"

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
  echo "已选择监听IP: $bind_ip [$(get_ip_role_hint "$bind_ip")]"
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

  local target_ip target_port snat_ip remark
  while true; do
    read -r -p "请输入目标服务端IP: " target_ip
    target_ip="$(trim "$target_ip")"
    [[ -n "$target_ip" ]] || { echo "目标IP不能为空。"; continue; }
    validate_ipv4 "$target_ip" && break
    echo "目标IP格式不合法，请输入正确的 IPv4。"
  done

  while true; do
    read -r -p "请输入目标端口 [默认1701]: " target_port
    target_port="$(trim "$target_port")"
    target_port="${target_port:-1701}"
    validate_port "$target_port" && break
    echo "目标端口不合法，请重新输入。"
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

  read -r -p "请输入备注（可选）: " remark
  remark="$(sanitize_remark "$remark")"

  echo
  echo "规则类型：$title"
  echo "客户入口UDP：${bind_ip}:${listen_port}"
  echo "服务端UDP：${target_ip}:${target_port}"
  echo "出口源IP：${snat_ip}"
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
客户入口UDP：${bind_ip}:${listen_port}
服务端UDP：${target_ip}:${target_port}
出口源IP：${snat_ip}

UDP 状态：$(rule_status_by_id "$id")"
      else
        show_message "规则已创建，但自动启动失败。

编号：$id
客户入口UDP：${bind_ip}:${listen_port}
服务端UDP：${target_ip}:${target_port}
出口源IP：${snat_ip}

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
  echo "编号：$id"
  echo "客户入口UDP：${bind_ip}:${listen_port}"
  echo "服务端UDP：${target_ip}:${target_port}"
  echo "出口源IP：${snat_ip}"
  echo "备注：${remark}"
  echo

  if confirm "确认删除规则？"; then
    delete_rule_by_id "$id"
    show_message "规则已删除。"
  fi
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
    echo
    echo "0) 返回"
    echo

    local choice id line_data
    read -r -p "请输入选项 [0-2]: " choice
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

main_menu() {
  while true; do
    clear_screen
    line 44
    printf ' %s %s\n' "$APP_NAME" "$APP_VERSION"
    line 44
    printf '\n'
    printf '1) 查看转发规则\n'
    printf '2) 新增转发规则\n'
    printf '3) 删除转发规则\n'
    printf '4) 查看运行日志\n'
    printf '5) 自检/修复\n'
    printf '6) 丢包诊断\n'
    printf '0) 退出\n'
    printf '\n'
    subline 44
    read -r -p "请输入选项 [0-6]: " choice
    case "$choice" in
      1) show_rules_menu ;;
      2) add_rule_menu ;;
      3) delete_rule_menu ;;
      4) view_log_menu ;;
      5) self_check_menu ;;
      6) diagnose_menu ;;
      0) clear_screen; exit 0 ;;
      *) show_message "无效选项，请重新输入。" ;;
    esac
  done
}

auto_cleanup_legacy_portfw_rules
main_menu
