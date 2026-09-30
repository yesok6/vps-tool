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
SYSCTL_CONF="/etc/sysctl.d/99-vps-optimizer.conf"
LIMITS_CONF="/etc/security/limits.d/99-nofile.conf"
LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

log_action() {
    mkdir -p "${LOG_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

[[ $EUID -ne 0 ]] && echo -e "${RED}[错误]${PLAIN} 请使用 root 权限运行！" && exit 1

run_step_system_upgrade() {
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    echo -e "${BLUE}[流水线 1/4]${PLAIN} 升级系统软件与修补安全补丁 ${YELLOW}[不可逆更新]${PLAIN}..."
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"

    timedatectl set-timezone UTC 2>/dev/null
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        apt-get update -y -q
        apt-get dist-upgrade -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
        apt-get autoremove -y -q && apt-get clean
        apt-get install -y -q curl jq openssl bc iproute2 chrony &>/dev/null
    else
        yum install -y curl jq openssl bc iproute chrony &>/dev/null || dnf install -y curl jq openssl bc iproute chrony &>/dev/null
    fi
    systemctl restart chrony 2>/dev/null
    log_action "[流水线/不可逆] 系统全量补丁升级与 UTC 时间校准"
    echo -e "${GREEN}[完成]${PLAIN} 系统软件与安全补丁已全量修补完毕！"
}

run_step_network_tune() {
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    echo -e "${BLUE}[流水线 2/4]${PLAIN} 优化内核底座 (BBR/大缓存/多核) ${GREEN}[可完全撤销]${PLAIN}..."
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"

    local mem_total_mb swap_total_mb
    mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
    swap_total_mb=$(free -m | awk '/Swap:/ {print $2}')
    if [ "$swap_total_mb" -lt 512 ] && [ "$mem_total_mb" -lt 2048 ]; then
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null
        chmod 600 /swapfile && mkswap /swapfile &>/dev/null && swapon /swapfile &>/dev/null
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        log_action "[流水线/可撤销] 自动创建 1GB Swap 交换内存"
    fi

    mkdir -p /etc/security/limits.d/
    cat <<EOF > "$LIMITS_CONF"
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    ulimit -n 1048576 2>/dev/null

    local total_mem_kb rmem_max=33554432 wmem_max=33554432
    total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    [ "$total_mem_kb" -gt 2097152 ] && { rmem_max=67108864; wmem_max=67108864; }

    cat <<EOF > "$SYSCTL_CONF"
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}
net.ipv4.tcp_wmem = 4096 65536 ${wmem_max}
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl -p "$SYSCTL_CONF" &>/dev/null

    touch /etc/gai.conf
    sed -i '/precedence ::ffff:0:0\/96  100/d' /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf

    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    if [[ -n "$iface" ]]; then
        local cpu_count mask
        cpu_count=$(nproc)
        mask=$(printf '%x' $(( (1 << cpu_count) - 1 )))
        for rps_file in /sys/class/net/"${iface}"/queues/rx-*/rps_cpus; do [[ -f "$rps_file" ]] && echo "$mask" > "$rps_file" 2>/dev/null; done
        for xps_file in /sys/class/net/"${iface}"/queues/tx-*/xps_cpus; do [[ -f "$xps_file" ]] && echo "$mask" > "$xps_file" 2>/dev/null; done
    fi
    log_action "[流水线/可撤销] 生产级网络参数调优生效"
    echo -e "${GREEN}[完成]${PLAIN} 生产级网络优化配置全部就绪！"
}

run_step_deploy_reality() {
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    echo -e "${BLUE}[流水线 3/4]${PLAIN} 部署 VLESS + Reality 代理 ${GREEN}[可完全撤销]${PLAIN}..."
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"

    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}[错误]${PLAIN} 不支持的架构！"; exit 1 ;;
    esac

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
    fi

    local default_port
    while true; do
        default_port=$((RANDOM % 50001 + 10000))
        ! ss -tuln | grep -q ":${default_port} " && break
    done

    read -rp "请输入端口号 [直接回车使用随机安全端口: ${default_port}]: " input_port
    local port="${input_port:-$default_port}"

    echo -e "${BLUE}[优选中]${PLAIN} 正在自动筛选最低延迟的大厂伪装域名..."
    local candidate_domains=("gateway.icloud.com" "itunes.apple.com" "addons.mozilla.org" "swdist.apple.com" "www.microsoft.com" "images.unsplash.com")
    local tmp_res="/tmp/auto_sni.txt"
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

    local sni="addons.mozilla.org"
    [[ -f "$tmp_res" ]] && sni=$(sort -n "$tmp_res" | head -n1 | awk '{print $2}')

    local uuid key_pair private_key public_key short_id server_ip
    uuid=$(sing-box generate uuid)
    key_pair=$(sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}')
    short_id=$(sing-box generate rand --hex 8)

    local ip4
    ip4=$(curl -s4m 2 https://api.ipify.org || curl -s4m 2 https://icanhazip.com)
    [[ -n "$ip4" ]] && server_ip="$ip4" || server_ip="[$(curl -s6m 2 https://api6.ipify.org || curl -s6m 2 https://icanhazip.com)]"

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
    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "${port}/tcp" &>/dev/null
    fi
    log_action "[流水线/可撤销] 部署 VLESS+Reality (端口: ${port})"

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
}

run_all_in_one() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}         [模块 4] 一键全自动综合装配流水线          ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "全自动流水线将为您完成:"
    echo -e "  1. 系统补丁与时间校准   ${YELLOW}[不可逆更新]${PLAIN}"
    echo -e "  2. 生产级网络内核调优   ${GREEN}[可完全撤销]${PLAIN}"
    echo -e "  3. VLESS-Reality 协议   ${GREEN}[可完全撤销]${PLAIN}"
    echo -e "  4. 防火墙端口放行       ${YELLOW}[安全保留项]${PLAIN}"
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    read -rp "是否立即开始全套部署？[Y/n]: " start_choice
    [[ "$start_choice" =~ ^[Nn]$ ]] && { echo -e "${YELLOW}操作取消${PLAIN}"; return; }

    run_step_system_upgrade
    run_step_network_tune
    run_step_deploy_reality

    clear
    echo -e "${GREEN}${BOLD}恭喜！全套 VPS 优化与网络协议部署全部就绪！${PLAIN}\n"
    cat "${NODE_INFO_FILE}"
    echo ""
    echo -e "${YELLOW}[提示] 节点信息已长期存档在: ${CONF_DIR}/node_info.txt${PLAIN}"
}

run_all_in_one
