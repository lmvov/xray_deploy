#!/bin/bash
set -e

# 必须以 root 身份运行
if [[ $(id -u) -ne 0 ]]; then
  echo "❌ 请以 root 用户运行该脚本！" >&2
  exit 1
fi

CONFIG_FILE="/usr/local/etc/xray/config.json"
NODE_INFO_FILE="/usr/local/etc/xray/nodes.json"
WS_PATH="/chat"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# ── 工具函数 ──────────────────────────────────────────────

install_jq() {
  if ! command -v jq &>/dev/null; then
    echo "安装 jq ..."
    if command -v apt-get &>/dev/null; then
      apt-get update && apt-get install -y jq
    elif command -v yum &>/dev/null; then
      yum install -y jq
    else
      echo "请手动安装 jq 后重试"
      exit 1
    fi
  fi
}

install_xray() {
  if ! command -v xray &>/dev/null; then
    echo "检测到未安装 Xray，开始安装..."
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
    if ! command -v xray &>/dev/null; then
      echo "❌ Xray 安装失败，请检查网络或手动安装" >&2
      exit 1
    fi
    systemctl enable xray
    systemctl start xray
    echo "Xray 安装完成"
  else
    echo "检测到 Xray 已安装"
  fi
}

restart_xray() {
  echo "重启 Xray 服务 ..."
  systemctl daemon-reload
  systemctl restart xray
  systemctl enable xray
}

url_encode() {
  local raw="$1"
  local length=${#raw}
  local i c encoded=""
  for (( i=0; i<length; i++ )); do
    c=${raw:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"
         encoded+="$hex"
         ;;
    esac
  done
  echo "$encoded"
}

generate_random_str() {
  tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 18
}

generate_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

generate_random_port() {
  local attempt=0
  while :; do
    attempt=$((attempt + 1))
    if (( attempt > 1000 )); then
      echo "❌ 无法找到空闲端口，端口池可能已满" >&2
      return 1
    fi
    local p=$(shuf -i 10000-30000 -n1)
    local conflict=0

    if [[ -f "$NODE_INFO_FILE" ]]; then
      conflict=$(jq --argjson port "$p" '[.[] | select(.port == $port)] | length' "$NODE_INFO_FILE" 2>/dev/null || echo 0)
    fi

    if lsof -iTCP:"$p" -sTCP:LISTEN &>/dev/null; then
      conflict=1
    fi

    if [[ "$conflict" -eq 0 ]]; then
      echo "$p"
      return
    fi
  done
}

# ── 网络相关 ──────────────────────────────────────────────

# 获取本机所有 IPv4 地址
get_local_ips() {
  ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
}

# 获取本机公网 IPv4 地址（通过外部 API）
get_public_ip() {
  curl -s --max-time 5 https://api-ipv4.ip.sb || curl -s --max-time 5 https://ifconfig.me
}

# ── 数据持久化 ────────────────────────────────────────────

load_nodes() {
  if [[ ! -f "$NODE_INFO_FILE" ]]; then
    echo "[]" > "$NODE_INFO_FILE"
  fi
  NODES=$(cat "$NODE_INFO_FILE")
}

save_nodes() {
  echo "$NODES" | jq '.' > "$NODE_INFO_FILE"
}

# ── Xray 配置重建 ─────────────────────────────────────────

rebuild_xray_config() {
  echo "$NODES" | jq \
      --arg path "$WS_PATH" \
'  map(
    if .protocol == "vless" then
      {
        port: .port,
        listen: .ip,
        protocol: "vless",
        settings: {
          clients: [ { id: .uuid } ],
          decryption: "none"
        },
        streamSettings: {
          network: "ws",
          security: "none",
          wsSettings: {
            path: $path
          }
        }
      }
    else
      {
        port: .port,
        listen: .ip,
        protocol: "socks",
        settings: {
          auth: "password",
          accounts: [ { user: .socks_user, pass: .socks_pass } ]
        }
      }
    end
  )
  | { log: { loglevel: "warning" },
      inbounds:  .,
      outbounds: [ { protocol: "freedom" } ] }
' > "$CONFIG_FILE"
}

# ── 添加节点 ──────────────────────────────────────────────

add_node() {
  echo "=== 添加节点 ==="

  local ips=()
  while IFS= read -r line; do
    ips+=("$line")
  done < <(get_local_ips)

  if [[ ${#ips[@]} -eq 0 ]]; then
    echo "未检测到本机 IP 地址"
    return 1
  fi

  echo "检测到以下 IP："
  for i in "${!ips[@]}"; do
    echo "$((i+1)). ${ips[$i]}"
  done

  read -r -p "请选择使用的 IP 序号（多个用空格分隔，回车全选）: " ip_choices

  if [[ -z $ip_choices ]]; then
    ip_choices=$(seq 1 ${#ips[@]})
  fi

  local selected=()
  for c in $ip_choices; do
    if [[ $c =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#ips[@]} )); then
      selected+=("${ips[$((c-1))]}")
    fi
  done

  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "未选择有效 IP"
    return 1
  fi

  echo ""
  echo "选择协议："
  echo "1) VLESS + WebSocket"
  echo "2) Socks5"
  read -r -p "输入选项（默认 1）: " PROTO
  PROTO=${PROTO:-1}

  for ip in "${selected[@]}"; do
    local port uuid user pass node

    if [[ $PROTO == 1 ]]; then
      # VLESS + WebSocket
      port=$(generate_random_port)
      uuid=$(generate_uuid)
      node=$(jq -n \
        --arg ip "$ip" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        '{ ip: $ip, port: $port, protocol: "vless", uuid: $uuid }')
    else
      # Socks5
      port=$(generate_random_port)
      user=$(generate_random_str)
      pass=$(generate_random_str)
      node=$(jq -n \
        --arg ip "$ip" \
        --argjson port "$port" \
        --arg socks_user "$user" \
        --arg socks_pass "$pass" \
        '{ ip: $ip, port: $port, protocol: "socks", socks_user: $socks_user, socks_pass: $socks_pass }')
    fi

    NODES=$(echo "$NODES" | jq ". + [ $node ]")
  done

  save_nodes
  rebuild_xray_config
  restart_xray

  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✅ Xray 启动成功${RESET}"
  else
    echo -e "${RED}❌ Xray 启动失败，请使用 'systemctl status xray' 查看详细信息${RESET}"
    exit 1
  fi
}

# ── 显示节点 ──────────────────────────────────────────────

show_nodes() {
  echo "=== 协议节点列表 ==="
  if [[ $(echo "$NODES" | jq length) -eq 0 ]]; then
    echo "无节点"
    return
  fi

  local public_ip
  public_ip=$(get_public_ip)

  local count=0
  local nodes_arr=()
  while IFS= read -r node; do
    nodes_arr+=("$node")
  done < <(echo "$NODES" | jq -c '.[]')

  for node in "${nodes_arr[@]}"; do
    count=$((count + 1))
    local protocol ip port uuid socks_user socks_pass
    protocol=$(echo "$node" | jq -r '.protocol')
    ip=$(echo "$node" | jq -r '.ip')
    port=$(echo "$node" | jq -r '.port')
    uuid=$(echo "$node" | jq -r '.uuid // empty')
    socks_user=$(echo "$node" | jq -r '.socks_user // empty')
    socks_pass=$(echo "$node" | jq -r '.socks_pass // empty')

    echo "[$count]"

    if [[ "$protocol" == "vless" ]]; then
      local path_enc link
      path_enc=$(url_encode "$WS_PATH")
      link="vless://${uuid}@${public_ip}:${port}?encryption=none&security=none&type=ws&path=${path_enc}#${public_ip}"

      echo "  IP: $ip"
      echo "  端口: $port"
      echo "  协议: vless"
      echo "  UUID: $uuid"
      echo "  传输: ws"
      echo "  节点链接: $link"
      echo "  ---"

    else
      echo "  IP: $ip"
      echo "  端口: $port"
      echo "  协议: socks5"
      echo "  用户名: $socks_user"
      echo "  密码: $socks_pass"
      echo "  ---"
    fi
  done
}

# ── 删除节点 ──────────────────────────────────────────────

delete_node() {
  echo "=== 删除节点 ==="
  show_nodes
  read -r -p "请输入要删除的节点序号: " DEL_IDX
  if ! [[ "$DEL_IDX" =~ ^[0-9]+$ ]]; then
    echo "无效的序号"
    return
  fi

  local len_before
  len_before=$(echo "$NODES" | jq length)
  if (( DEL_IDX < 1 || DEL_IDX > len_before )); then
    echo "序号超出范围 (1-$len_before)"
    return
  fi

  NODES=$(echo "$NODES" | jq "del(.[$((DEL_IDX - 1))])")
  save_nodes
  rebuild_xray_config
  restart_xray
  local remain
  remain=$(echo "$NODES" | jq length)
  echo "节点 $DEL_IDX 已删除。当前剩余 $remain 个节点"
}

install_cron() {
  if ! command -v crontab &>/dev/null; then
    echo "检测到未安装 cron，正在安装..."
    if command -v apt-get &>/dev/null; then
      apt-get update && apt-get install -y cron
      systemctl enable cron
      systemctl start cron
    elif command -v yum &>/dev/null; then
      yum install -y cronie
      systemctl enable crond
      systemctl start crond
    else
      echo "无法自动安装 cron，请手动安装"
      exit 1
    fi
  fi
}

setup_cron_restart() {
  local restart_hour
  read -r -p "设置每天自动重启时间 - 小时 (0-23, 默认 0): " restart_hour
  restart_hour=${restart_hour:-0}

  if ! [[ "$restart_hour" =~ ^[0-9]+$ ]]; then
    echo "无效的小时数，使用默认值 0"
    restart_hour=0
  fi

  local cron_job="0 ${restart_hour} * * * /sbin/reboot >> /var/log/vps-restart.log 2>&1"
  if /usr/bin/crontab -l 2>/dev/null | /usr/bin/grep -qF "vps restart"; then
    echo "定时重启已存在，已更新为新时间"
    (/usr/bin/crontab -l 2>/dev/null | /usr/bin/grep -v "vps restart"; echo "$cron_job") | /usr/bin/crontab -
  else
    (/usr/bin/crontab -l 2>/dev/null; echo "$cron_job") | /usr/bin/crontab -
  fi
  echo -e "${GREEN}✅ 已设置每天 ${restart_hour}:00 自动重启 VPS${RESET}"
}

cancel_cron_restart() {
  if /usr/bin/crontab -l 2>/dev/null | /usr/bin/grep -qF "vps restart"; then
    /usr/bin/crontab -l 2>/dev/null | /usr/bin/grep -v "vps restart" | /usr/bin/crontab -
    echo -e "${GREEN}✅ 已取消定时重启${RESET}"
  else
    echo "定时重启未设置"
  fi
}

show_restart_log() {
  local LOG="/var/log/vps-restart.log"
  if [[ ! -f "$LOG" ]]; then
    echo "暂无重启日志"
    return
  fi

  echo "=== 最近7天重启日志 ==="
  local cutoff
  cutoff=$(date -d "7 days ago" '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null)
  local found=0
  while IFS= read -r line; do
    local log_date
    log_date=$(echo "$line" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "")
    if [[ -n "$log_date" ]] && [[ "$log_date" > "$cutoff" || "$log_date" == "$cutoff" ]]; then
      echo "  $line"
      found=1
    fi
  done < "$LOG"

  if [[ $found -eq 0 ]]; then
    echo "  近7天无重启记录"
  fi

  # 清理超过7天的日志
  if [[ -f "$LOG" ]]; then
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      local log_date
      log_date=$(echo "$line" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "")
      if [[ -n "$log_date" ]] && [[ "$log_date" > "$cutoff" || "$log_date" == "$cutoff" ]]; then
        echo "$line"
      fi
    done < "$LOG" > "$tmp"
    mv "$tmp" "$LOG"
  fi
}

manual_restart_xray() {
  echo "正在重启 VPS ..."
  /sbin/reboot
}

# ── 主菜单 ────────────────────────────────────────────────

main_menu() {
  while true; do
    if systemctl is-active --quiet xray; then
      STATUS="${GREEN}已启动${RESET}"
    else
      STATUS="${RED}未启动${RESET}"
    fi

    clear
    echo -e "${YELLOW}====== Xray 管理菜单 (状态: $STATUS) ======${RESET}"
    echo -e "${YELLOW}当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')${RESET}"
    echo -e "${YELLOW}1) 添加协议节点${RESET}"
    echo -e "${YELLOW}2) 查看协议节点${RESET}"
    echo -e "${YELLOW}3) 删除协议节点${RESET}"
    echo -e "${YELLOW}4) 设置每天自动重启${RESET}"
    echo -e "${YELLOW}5) 取消每天自动重启${RESET}"
    echo -e "${YELLOW}6) 立即重启 VPS${RESET}"
    echo -e "${YELLOW}7) 查看7天内重启日志${RESET}"
    echo -e "${YELLOW}0) 退出${RESET}"

    read -r -p "请选择操作: " choice
    case $choice in
      1) add_node ;;
      2) show_nodes ;;
      3) delete_node ;;
      4) setup_cron_restart ;;
      5) cancel_cron_restart ;;
      6) manual_restart_xray ;;
      7) show_restart_log ;;
      0) echo "退出脚本"; exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

# ── 入口 ──────────────────────────────────────────────────

install_jq
install_xray
install_cron
load_nodes
main_menu
