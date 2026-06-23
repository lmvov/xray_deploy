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
  while :; do
    local p=$(shuf -i 10000-40000 -n1)
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

  echo "$NODES" | jq -c '.[]' | while IFS= read -r node; do
    local protocol ip port uuid socks_user socks_pass
    eval "$(echo "$node" | jq -r 'to_entries | map("\(.key)=\(.value | tostring)") | join("\n")')"

    if [[ "$protocol" == "vless" ]]; then
      local path_enc link
      path_enc=$(url_encode "$WS_PATH")
      link="vless://${uuid}@${public_ip}:${port}?encryption=none&security=none&type=ws&path=${path_enc}#${public_ip}"

      echo "IP: $ip"
      echo "端口: $port"
      echo "协议: vless"
      echo "UUID: $uuid"
      echo "传输: ws"
      echo "节点链接: $link"
      echo "---"

    else
      echo "IP: $ip"
      echo "端口: $port"
      echo "协议: socks5"
      echo "用户名: $socks_user"
      echo "密码: $socks_pass"
      echo "---"
    fi
  done
}

# ── 删除节点 ──────────────────────────────────────────────

delete_node() {
  echo "=== 删除节点 ==="
  show_nodes
  read -r -p "请输入要删除节点的端口号: " DEL_PORT
  if ! [[ $DEL_PORT =~ ^[0-9]+$ ]]; then
    echo "无效端口号"
    return
  fi

  local len_before len_after
  len_before=$(echo "$NODES" | jq length)
  NODES=$(echo "$NODES" | jq "map(select(.port != ($DEL_PORT | tonumber)))")
  len_after=$(echo "$NODES" | jq length)

  if [[ "$len_before" == "$len_after" ]]; then
    echo "未找到对应端口的节点"
  else
    save_nodes
    rebuild_xray_config
    restart_xray
    echo "端口 $DEL_PORT 的节点已删除，Xray 已重启"
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

  local cron_job="0 ${restart_hour} * * * /usr/bin/systemctl restart xray >> /var/log/xray-restart.log 2>&1"
  if crontab -l 2>/dev/null | grep -qF "xray restart"; then
    echo "定时重启已存在，已更新为新时间"
    (crontab -l 2>/dev/null | grep -v "xray restart"; echo "$cron_job") | crontab -
  else
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
  fi
  echo -e "${GREEN}✅ 已设置每天 ${restart_hour}:00 自动重启 Xray${RESET}"
}

cancel_cron_restart() {
  if crontab -l 2>/dev/null | grep -qF "xray restart"; then
    crontab -l 2>/dev/null | grep -v "xray restart" | crontab -
    echo -e "${GREEN}✅ 已取消定时重启${RESET}"
  else
    echo "定时重启未设置"
  fi
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
    echo -e "${YELLOW}0) 退出${RESET}"

    read -r -p "请选择操作: " choice
    case $choice in
      1) add_node ;;
      2) show_nodes ;;
      3) delete_node ;;
      4) setup_cron_restart ;;
      5) cancel_cron_restart ;;
      0) echo "退出脚本"; exit 0 ;;
      *) echo "无效选项" ;;
    esac
    echo
    read -r -p "按回车继续..."
  done
}

# ── 入口 ──────────────────────────────────────────────────

install_jq
install_xray
load_nodes
main_menu
