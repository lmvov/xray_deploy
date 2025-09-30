#!/bin/bash
set -e
# 必须以 root 身份运行
if [[ $(id -u) -ne 0 ]]; then
  echo "❌ 请以 root 用户运行该脚本！" >&2
  exit 1
fi

CONFIG_FILE="/usr/local/etc/xray/config.json"
NODE_INFO_FILE="/usr/local/etc/xray/nodes.json"
PATH_SETTING="/chat"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

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

restart_xray() {
  echo "重启 Xray 服务 ..."
  systemctl daemon-reload
  systemctl restart xray
  systemctl enable xray
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
    local p=$(shuf -i 10000-40000 -n1)  # 随机生成一个端口号
    local conflict=0

    # 检查端口是否已在 JSON 文件中
    if [[ -f "$NODE_INFO_FILE" ]]; then
      conflict=$(jq --argjson port "$p" '[.[] | select(.port == $port)] | length' "$NODE_INFO_FILE" 2>/dev/null || echo 0)
    fi
    
    # 检查端口是否已被系统占用
    if lsof -iTCP:"$p" -sTCP:LISTEN &>/dev/null; then
      conflict=1
    fi

    # 如果没有冲突，则返回端口
    if [[ "$conflict" -eq 0 ]]; then
      echo "$p"
      return
    fi
  done
}


load_nodes() {
  if [[ ! -f "$NODE_INFO_FILE" ]]; then
    echo "[]" > "$NODE_INFO_FILE"
  fi
  NODES=$(cat "$NODE_INFO_FILE")
}

save_nodes() {
  echo "$NODES" | jq '.' > "$NODE_INFO_FILE"
}

rebuild_xray_config() {
  echo "$NODES" | jq \
      --arg path "$PATH_SETTING" \
'  ##  jq 程序开始  ##
  map(
    if .protocol == "vless" then
      {
        port: .port,
        listen: .ip,
        protocol: "vless",

        settings: {
          clients: [ { id: .uuid } ],
          decryption: "none"
        },

        streamSettings: (
          {
            network: .network,
            security: (if .mode == "tls" then "tls" else "none" end)
          }
          +
          ( if .mode == "tls" then
              { tlsSettings: { certificates: [ { certificateFile: .cert_file, keyFile: .key_file } ] } }
            else {} end
          )
          +
          ( if .network == "ws" then
              { wsSettings: { path: $path,
                              headers: (if .mode == "tls" then { "Host": .domain } else {} end) } }
            elif .network == "xhttp" then
              { xhttpSettings: { path: $path, mode: "auto" } }
            else {} end
          )
        )
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
  ##  jq 程序结束  ##
' > "$CONFIG_FILE"
}




input_ip() {
  IPS=($(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}'))
  [[ ${#IPS[@]} -gt 0 ]] || { echo "未检测到公网 IPv4 地址"; exit 1; }

  echo "检测到以下公网 IP："
  for i in "${!IPS[@]}"; do
    echo "$((i+1)). ${IPS[$i]}"
  done
  read -r -p "请选择使用的 IP 序号（多个用空格分隔）: " ip_choices

  IPS_SELECTED=()
  for c in $ip_choices; do
    if [[ $c =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#IPS[@]} )); then
      IPS_SELECTED+=("${IPS[$((c-1))]}")
    fi
  done
  [[ ${#IPS_SELECTED[@]} -gt 0 ]] || IPS_SELECTED=("${IPS[@]}")
}

input_domain() {
  read -r -p "请输入已解析到本机的域名（留空表示无域名）: " DOMAIN

  if [[ -z $DOMAIN ]]; then
    MODE="no_tls"
    CERT_FILE=""
    KEY_FILE=""
    return
  fi

  MODE="tls"

  # 检查并安装必要命令 dig curl socat
  for cmd in dig curl socat; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "检测到系统缺少 $cmd，正在安装..."
      if command -v apt &>/dev/null; then
        apt update -qq
        case "$cmd" in
          dig) apt -y install dnsutils ;;
          curl) apt -y install curl ;;
          socat) apt -y install socat ;;
        esac
      elif command -v yum &>/dev/null; then
        case "$cmd" in
          dig) yum -y install bind-utils ;;
          curl) yum -y install curl ;;
          socat) yum -y install socat ;;
        esac
      fi
    fi
  done

  # 检查并安装 cron 服务
  if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null; then
    echo "检测到系统未安装 cron，正在安装..."
    if command -v apt &>/dev/null; then
      apt update -qq
      apt install -y cron
      systemctl enable cron
      systemctl start cron
    elif command -v yum &>/dev/null; then
      yum install -y cronie
      systemctl enable crond
      systemctl start crond
    else
      echo "未检测到 apt 或 yum，无法自动安装 cron，请手动安装 cron 服务"
      exit 1
    fi
  else
    echo "检测到 cron 已安装"
  fi

  IP_SERVER_LIST=$(
    {
      curl -s https://api-ipv4.ip.sb
      ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1
    } | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
  )

  IPS_DOMAIN=($(dig +short A "$DOMAIN" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'))

  MATCHED_IP=""
  for ip in "${IPS_DOMAIN[@]}"; do
    if echo "$IP_SERVER_LIST" | grep -qx "$ip"; then
      MATCHED_IP=$ip
      break
    fi
  done

  if [[ -z $MATCHED_IP ]]; then
    echo -e "${RED}❌ 域名解析的 IP(${IPS_DOMAIN[*]}) 与本机公网 IP(${IP_SERVER_LIST//[$'\n']/ }) 均不匹配！${RESET}"
    echo "   - 请确认解析是否已生效"
    echo "   - 如果本机有多 IP，可将域名解析到其中任何一个即可"
    exit 1
  fi

  echo -e "${GREEN}✅ 域名解析检查通过，匹配 IP: $MATCHED_IP${RESET}"

  # 安装 acme.sh（如果没装）
  if ! command -v acme.sh &>/dev/null; then
    echo "安装 acme.sh ..."
    curl https://get.acme.sh | sh
  fi

  export HOME=${HOME:-/root}
  export PATH="$HOME/.acme.sh:$PATH"

  # 自动注册账户，避免申请失败
  # 注意：这里请修改为你自己的邮箱，或者提示用户输入
  ACCOUNT_EMAIL="your_email@example.com"
  if ! acme.sh --showaccount --home "$HOME/.acme.sh" | grep -q "$ACCOUNT_EMAIL"; then
    echo "注册 acme.sh 账户邮箱为 $ACCOUNT_EMAIL"
    acme.sh --register-account -m "$ACCOUNT_EMAIL" --home "$HOME/.acme.sh"
  fi

# 申请证书
echo "申请 Let's Encrypt 证书 ..."

acme.sh --issue --standalone --keylength ec-256 -d "$DOMAIN" \
        --home "$HOME/.acme.sh" || { 
  echo "❌ 证书申请失败，详见日志"; exit 1; 
}

# 安装证书
acme.sh --install-cert -d "$DOMAIN" \
        --ecc \
        --fullchain-file "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer" \
        --key-file "$HOME/.acme.sh/${DOMAIN}_ecc/private.key" \
        --home "$HOME/.acme.sh"

# 创建目标目录：/usr/local/etc/$DOMAIN
DEST_DIR="/usr/local/etc/$DOMAIN"  # 为每个域名创建子目录
mkdir -p "$DEST_DIR"  # 确保目标目录存在

# 将证书和私钥文件移到域名对应的子目录
mv "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer" "$DEST_DIR/fullchain.cer"
mv "$HOME/.acme.sh/${DOMAIN}_ecc/private.key" "$DEST_DIR/private.key"

# 更新证书路径
CERT_FILE="$DEST_DIR/fullchain.cer"
KEY_FILE="$DEST_DIR/private.key"

echo -e "${GREEN}🎉 证书已移动到 $CERT_FILE / $KEY_FILE${RESET}"

# 更新 xray 配置
rebuild_xray_config



# 1) 若无则创建专用用户 xray（系统账号，无法登录）
if ! id xray &>/dev/null; then
  if command -v useradd &>/dev/null; then
    useradd -r -s /usr/sbin/nologin xray
  elif command -v adduser &>/dev/null; then
    adduser --system --shell /usr/sbin/nologin --no-create-home xray
  else
    echo "❌ 无法创建 xray 用户：系统缺少 useradd/adduser 命令" >&2
    exit 1
  fi
fi

# 2) 将证书目录的所有权分配给 xray 用户，并锁定私钥权限
chown -R xray:xray "$DEST_DIR"
chmod 600 "$KEY_FILE"
chmod 644 "$DEST_DIR/fullchain.cer"

# 3) 如果 service 文件里还是 User=nobody，就改为 User=xray
SERVICE_FILE="/etc/systemd/system/xray.service"
if grep -q '^User=nobody' "$SERVICE_FILE"; then
  sed -i 's/^User=nobody/User=xray/' "$SERVICE_FILE"
fi

# 4) 重新加载 systemd 并重启 Xray
systemctl daemon-reload
systemctl restart xray
systemctl status xray --no-pager



}





add_node() {
  echo "=== 添加节点 ==="
  input_ip

  echo "选择协议："
  echo "1) VLESS"
  echo "2) Socks5"
  read -r -p "输入选项（默认 1）: " PROTO
  PROTO=${PROTO:-1}

  if [[ $PROTO == 1 ]]; then
    echo "选择传输协议 (VLESS)："
    echo "1) ws (WebSocket)"
    echo "2) xhttp"
    read -r -p "输入选项（默认 1）: " TRANSPORT
    TRANSPORT=${TRANSPORT:-1}
    NETWORK=$([[ $TRANSPORT == 1 ]] && echo "ws" || echo "xhttp")

    input_domain

    for IP in "${IPS_SELECTED[@]}"; do
      PORT=$(generate_random_port)
      UUID=$(generate_uuid)
      NODE=$(jq -n --arg ip "$IP" --argjson port "$PORT" --arg uuid "$UUID" --arg protocol "vless" \
            --arg network "$NETWORK" --arg mode "$MODE" --arg domain "$DOMAIN" \
            --arg cert_file "$CERT_FILE" --arg key_file "$KEY_FILE" '{
              ip: $ip,
              port: $port,
              protocol: $protocol,
              uuid: $uuid,
              network: $network,
              mode: $mode,
              domain: $domain,
              cert_file: $cert_file,
              key_file: $key_file
            }')
      NODES=$(echo "$NODES" | jq ". + [ $NODE ]")
    done
  else
    for IP in "${IPS_SELECTED[@]}"; do
      PORT=$(generate_random_port)
      read -r -p "请输入 Socks5 用户名（留空自动生成）: " SOCKS_USER
      read -r -p "请输入 Socks5 密码（留空自动生成）: " SOCKS_PASS
      SOCKS_USER=${SOCKS_USER:-$(generate_random_str)}
      SOCKS_PASS=${SOCKS_PASS:-$(generate_random_str)}

      NODE=$(jq -n --arg ip "$IP" --argjson port "$PORT" --arg protocol "socks" --arg socks_user "$SOCKS_USER" --arg socks_pass "$SOCKS_PASS" '{
        ip: $ip,
        port: $port,
        protocol: $protocol,
        socks_user: $socks_user,
        socks_pass: $socks_pass
      }')
      NODES=$(echo "$NODES" | jq ". + [ $NODE ]")
    done
  fi

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

show_nodes() {
  echo "=== 协议节点列表 ==="
  if [[ $(echo "$NODES" | jq length) -eq 0 ]]; then
    echo "无节点"
    return
  fi

  echo "$NODES" | jq -c '.[]' | while read -r node; do
    protocol=$(echo "$node" | jq -r '.protocol')
    ip=$(echo "$node" | jq -r '.ip')
    port=$(echo "$node" | jq -r '.port')

    if [[ "$protocol" == "vless" ]]; then
      uuid=$(echo "$node" | jq -r '.uuid')
      network=$(echo "$node" | jq -r '.network')
      mode=$(echo "$node" | jq -r '.mode')
      domain=$(echo "$node" | jq -r '.domain')

      security="none"
      host="$ip"
      [[ "$mode" == "tls" ]] && { security="tls"; host="$domain"; }

      path_enc=$(url_encode "$PATH_SETTING")
      extra=""
      [[ "$network" == "xhttp" ]] && extra="&mode=auto"

      link="vless://${uuid}@${host}:${port}?encryption=none&security=${security}&type=${network}&path=${path_enc}${extra}#node"

      echo "IP: $ip"
      echo "端口: $port"
      echo "协议: vless"
      echo "UUID: $uuid"
      echo "传输: $network"
      echo "节点链接: $link"
      echo "---"

    else
      socks_user=$(echo "$node" | jq -r '.socks_user')
      socks_pass=$(echo "$node" | jq -r '.socks_pass')

      echo "IP: $ip"
      echo "端口: $port"
      echo "协议: socks5"
      echo "用户名: $socks_user"
      echo "密码: $socks_pass"
      echo "---"
    fi
  done
}


delete_node() {
  echo "=== 删除节点 ==="
  show_nodes
  read -r -p "请输入要删除节点的端口号: " DEL_PORT
  if ! [[ $DEL_PORT =~ ^[0-9]+$ ]]; then
    echo "无效端口号"
    return
  fi

  LEN_BEFORE=$(echo "$NODES" | jq length)
  NODES=$(echo "$NODES" | jq "map(select(.port != ($DEL_PORT | tonumber)))")
  LEN_AFTER=$(echo "$NODES" | jq length)

  if [[ "$LEN_BEFORE" == "$LEN_AFTER" ]]; then
    echo "未找到对应端口的节点"
  else
    save_nodes
    rebuild_xray_config
    restart_xray
    echo "端口 $DEL_PORT 的节点已删除，Xray 已重启"
  fi
}

main_menu() {
  while true; do
    if systemctl is-active --quiet xray; then
      STATUS="${GREEN}已启动${RESET}"
    else
      STATUS="${RED}未启动${RESET}"
    fi

    clear
    echo -e "${YELLOW}====== Xray 管理菜单 (状态: $STATUS) ======${RESET}"
    echo -e "${YELLOW}1) 添加协议节点${RESET}"
    echo -e "${YELLOW}2) 查看协议节点${RESET}"
    echo -e "${YELLOW}3) 删除协议节点${RESET}"
    echo -e "${YELLOW}0) 退出${RESET}"

    read -r -p "请选择操作: " choice
    case $choice in
      1) add_node ;;
      2) show_nodes ;;
      3) delete_node ;;
      0) echo "退出脚本"; exit 0 ;;
      *) echo "无效选项" ;;
    esac
    echo
    read -r -p "按回车继续..."
  done
}

# 主流程
install_jq
install_xray
load_nodes
main_menu