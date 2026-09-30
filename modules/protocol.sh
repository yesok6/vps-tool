#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
NODE_INFO_FILE="${CONF_DIR}/node_info.txt"
LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

log_action() {
    mkdir -p "${LOG_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

[[ $EUID -ne 0 ]] && echo -e "${RED}[错误]${PLAIN} 请使用 root 权限运行！" && exit 1

install_singbox() {
    if command -v sing-box &>/dev/null && command -v jq &>/dev/null; then return; fi
    echo -e "${BLUE}[环境]${PLAIN} 正在自动部署 sing-box 核心环境..."
    
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}[错误]${PLAIN} 不支持的架构！"; exit 1 ;;
    esac

    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y -q &>/dev/null && apt-get install -y -q curl jq openssl bc &>/dev/null
    else
        yum install -y curl jq openssl bc &>/dev/null || dnf install -y curl jq openssl bc &>/dev/null
    fi

    if ! command -v sing-box &>/dev/null; then
        local latest_version
        latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | tr -d 'v')
        [[ -z "$latest_version" || "$latest_version" == "null" ]] && latest_version="1.10.7"

        local download_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${arch}.tar.gz"
        curl -fsSL "$download_url" -o /tmp/sing-box.tar.gz
        tar -zxvf /tmp/sing-box.tar.gz -C /tmp/ &>/dev/null
        mv /tmp/sing-box-*/sing-box /usr/local/bin/
        chmod +x /usr/local/bin/sing-box
        rm -rf /tmp/sing-box*
        log_action "[可撤销] 安装 sing-box 核心二进制程序至 /usr/local/bin/sing-box"
    fi

    mkdir -p "${CONF_DIR}"
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=Core Proxy Service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box &>/dev/null
    log_action "[可撤销] 创建 sing-box.service 守护进程服务"
}

get_sys_ip() {
    local ip4 ip6
    ip4=$(curl -s4m 2 https://api.ipify.org || curl -s4m 2 https://icanhazip.com)
    if [[ -n "$ip4" ]]; then
        echo "$ip4"
    else
        ip6=$(curl -s6m 2 https://api6.ipify.org || curl -s6m 2 https://icanhazip.com)
        echo "[${ip6}]"
    fi
}

get_random_port() {
    local port
    while true; do
        port=$((RANDOM % 50001 + 10000))
        if ! ss -tuln | grep -q ":${port} "; then
            echo "$port"; break
        fi
    done
}

open_firewall_port() {
    local port="$1" proto="$2"
    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "${port}/${proto}" &>/dev/null
    fi
}

get_best_sni() {
    local candidate_domains=("gateway.icloud.com" "itunes.apple.com" "addons.mozilla.org" "swdist.apple.com" "www.microsoft.com" "dl.google.com" "images.unsplash.com")
    local tmp_res="/tmp/sni_test.txt"
    rm -f "$tmp_res"

    for domain in "${candidate_domains[@]}"; do
        (
            local rtt
            rtt=$(curl -o /dev/null -s -w "%{time_connect}\n" --connect-timeout 2 "https://${domain}" 2>/dev/null)
            if [[ -n "$rtt" && "$rtt" != "0.000" ]]; then
                local ms
                ms=$(echo "$rtt * 1000" | bc 2>/dev/null | awk -F'.' '{print $1}')
                [[ -n "$ms" && "$ms" -gt 0 ]] && echo "${ms} ${domain}" >> "$tmp_res"
            fi
        ) &
    done
    wait
    local best_domain=""
    [[ -f "$tmp_res" ]] && best_domain=$(sort -n "$tmp_res" | head -n1 | awk '{print $2}')
    echo "${best_domain:-addons.mozilla.org}"
}

deploy_vless_reality() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}  配置 VLESS + Reality  ${GREEN}[可完全撤销]${PLAIN}              ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    
    local default_port
    default_port=$(get_random_port)
    read -rp "请输入端口号 [直接回车随机分配: ${default_port}]: " input_port
    local port="${input_port:-$default_port}"

    install_singbox
    echo -e "${BLUE}[优选中]${PLAIN} 正在自动匹配最低延迟的大厂伪装节点..."
    local sni
    sni=$(get_best_sni)
    echo -e "${GREEN}[已匹配伪装域名]${PLAIN}: ${BOLD}${sni}${PLAIN}"

    local uuid key_pair private_key public_key short_id server_ip
    uuid=$(sing-box generate uuid)
    key_pair=$(sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}')
    short_id=$(sing-box generate rand --hex 8)
    server_ip=$(get_sys_ip)

    cat <<EOF > "${CONF_FILE}"
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${sni}", "server_port": 443 },
          "private_key": "${private_key}",
          "short_id": ["${short_id}"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

    systemctl restart sing-box
    open_firewall_port "$port" "tcp"
    log_action "[可撤销] 部署 VLESS+Reality 协议 (端口: ${port}, SNI: ${sni})"

    local vless_link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VLESS-Reality"

    cat <<EOF > "${NODE_INFO_FILE}"
===================== 节点连接信息 =====================
协议方案: VLESS + Vision + Reality
服务器地址: ${server_ip}
连接端口: ${port}
用户 ID (UUID): ${uuid}
流控 (flow): xtls-rprx-vision
伪装域名 (SNI): ${sni}
公钥 (PublicKey): ${public_key}
ShortId: ${short_id}

【一键导入分享链接】:
${vless_link}
========================================================
EOF
    clear
    cat "${NODE_INFO_FILE}"
    echo -e "\n${GREEN}[成功]${PLAIN} 部署完成！配置保存在: ${CONF_DIR}/node_info.txt"
}

deploy_hysteria2() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}    配置 Hysteria 2  ${GREEN}[可完全撤销]${PLAIN}                  ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port
    default_port=$(get_random_port)
    read -rp "请输入 UDP 端口号 [直接回车随机分配: ${default_port}]: " input_port
    local port="${input_port:-$default_port}"

    install_singbox
    local password cert_file key_file server_ip
    password=$(sing-box generate rand --hex 16)
    cert_file="${CONF_DIR}/hy2_cert.pem"
    key_file="${CONF_DIR}/hy2_key.pem"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "${key_file}" -out "${cert_file}" -days 3650 -subj "/CN=bing.com" &>/dev/null
    server_ip=$(get_sys_ip)

    cat <<EOF > "${CONF_FILE}"
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [ { "password": "${password}" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "${cert_file}",
        "key_path": "${key_file}"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

    systemctl restart sing-box
    open_firewall_port "$port" "udp"
    log_action "[可撤销] 部署 Hysteria 2 协议 (UDP 端口: ${port})"

    local hy2_link="hysteria2://${password}@${server_ip}:${port}/?insecure=1&sni=bing.com#Hysteria2"

    cat <<EOF > "${NODE_INFO_FILE}"
===================== 节点连接信息 =====================
协议方案: Hysteria 2 (QUIC 暴力加速)
服务器地址: ${server_ip}
UDP 端口: ${port}
连接密码: ${password}
SNI 伪装: bing.com
跳过证书校验 (insecure): 1

【一键导入分享链接】:
${hy2_link}
========================================================
EOF
    clear
    cat "${NODE_INFO_FILE}"
    echo -e "\n${GREEN}[成功]${PLAIN} 部署完成！配置保存在: ${CONF_DIR}/node_info.txt"
}

protocol_menu() {
    while true; do
        clear
        local status_text
        systemctl is-active sing-box &>/dev/null && status_text="${GREEN}运行中${PLAIN}" || status_text="${RED}未运行 / 未配置${PLAIN}"

        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              [模块 2] 网络协议一键配置            ${PLAIN}"
        echo -e "  服务状态: ${status_text} | 属性: ${GREEN}[本模块所有协议均可彻底卸载]${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 配置 VLESS + Reality  ${GREEN}[可完全撤销]${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 配置 Hysteria 2       ${GREEN}[可完全撤销]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${YELLOW}3.${PLAIN} 查看当前节点配置与导入链接"
        echo -e "  ${RED}4.${PLAIN} 彻底卸载清理协议环境 (仅清除协议与服务)"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${RED}0.${PLAIN} 返回上一级菜单"
        echo -e "${CYAN}====================================================${PLAIN}"

        read -rp "请输入选项 [0-4]: " p_choice
        case "$p_choice" in
            1) deploy_vless_reality; read -rp "按回车键继续..." ;;
            2) deploy_hysteria2; read -rp "按回车键继续..." ;;
            3)
                [[ -f "${NODE_INFO_FILE}" ]] && { clear; cat "${NODE_INFO_FILE}"; } || echo -e "${YELLOW}暂无配置${PLAIN}"
                read -rp "按回车键继续..."
                ;;
            4)
                systemctl stop sing-box &>/dev/null
                rm -rf "${CONF_DIR}" /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
                systemctl daemon-reload
                log_action "[已撤销] 单独卸载清理 sing-box 核心与配置"
                echo -e "${GREEN}[成功]${PLAIN} 已彻底清理干净！"
                read -rp "按回车键继续..."
                ;;
            0) break ;;
        esac
    done
}
protocol_menu
