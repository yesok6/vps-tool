#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

SYSCTL_CONF="/etc/sysctl.d/99-vps-optimizer.conf"
LIMITS_CONF="/etc/security/limits.d/99-nofile.conf"
LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

log_action() {
    mkdir -p "${LOG_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

[[ $EUID -ne 0 ]] && echo -e "${RED}[错误]${PLAIN} 请使用 root 权限运行！" && exit 1

get_default_interface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1
}

auto_setup_swap() {
    local mem_total_mb swap_total_mb
    mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
    swap_total_mb=$(free -m | awk '/Swap:/ {print $2}')
    
    if [ "$swap_total_mb" -lt 512 ] && [ "$mem_total_mb" -lt 2048 ]; then
        echo -e "${BLUE}[内存防护]${PLAIN} 内存较低 (${mem_total_mb}MB)，自动生成 1GB Swap..."
        swapoff -a 2>/dev/null
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null
        chmod 600 /swapfile && mkswap /swapfile &>/dev/null && swapon /swapfile &>/dev/null
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        sysctl vm.swappiness=15 &>/dev/null
        log_action "[可撤销] 自动创建 1GB Swap 虚拟交换文件"
    fi
}

show_dashboard() {
    local cur_kernel cur_cc cur_qdisc cur_limits ipv4_status rps_status bbr_ver
    cur_kernel=$(uname -r)
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    cur_limits=$(ulimit -n)

    if modinfo tcp_bbr 2>/dev/null | grep -q 'version:.*3'; then
        bbr_ver="${GREEN}BBRv3 激进内核${PLAIN}"
    elif lsmod | grep -q bbr; then
        bbr_ver="${GREEN}已激活 (BBR 内核)${PLAIN}"
    else
        bbr_ver="${YELLOW}未激活 / 默认${PLAIN}"
    fi

    grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null && ipv4_status="${GREEN}已开启 (IPv4 优先)${PLAIN}" || ipv4_status="${YELLOW}系统默认 (IPv6 优先)${PLAIN}"

    local iface
    iface=$(get_default_interface)
    if [[ -n "$iface" ]] && compgen -G "/sys/class/net/${iface}/queues/rx-*/rps_cpus" > /dev/null; then
        rps_status="${GREEN}已启用全核负载均衡${PLAIN}"
    else
        rps_status="${BLUE}单核/无需配置${PLAIN}"
    fi

    echo -e "${CYAN}------------------- [ 网络与内核核心状态 ] -------------------${PLAIN}"
    echo -e "  当前内核版本: ${BOLD}${cur_kernel}${PLAIN}"
    echo -e "  拥塞控制/队列: ${GREEN}${cur_cc}${PLAIN} + ${GREEN}${cur_qdisc}${PLAIN} (${bbr_ver})"
    echo -e "  文件描述符上限: ${GREEN}${cur_limits}${PLAIN}"
    echo -e "  网络解析优先级: ${ipv4_status}"
    echo -e "  CPU 中断多队列: ${rps_status} (网卡: ${iface})"
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
}

set_ipv4_priority() {
    touch /etc/gai.conf
    sed -i '/precedence ::ffff:0:0\/96  100/d' /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    log_action "[可撤销] 开启 IPv4 解析优先"
    echo -e "${GREEN}[成功]${PLAIN} IPv4 优先解析已生效！"
}

enable_nic_multiqueue() {
    local iface
    iface=$(get_default_interface)
    [[ -z "$iface" ]] && return
    local cpu_count mask
    cpu_count=$(nproc)
    mask=$(printf '%x' $(( (1 << cpu_count) - 1 )))

    for rps_file in /sys/class/net/"${iface}"/queues/rx-*/rps_cpus; do
        [[ -f "$rps_file" ]] && echo "$mask" > "$rps_file" 2>/dev/null
    done
    for xps_file in /sys/class/net/"${iface}"/queues/tx-*/xps_cpus; do
        [[ -f "$xps_file" ]] && echo "$mask" > "$xps_file" 2>/dev/null
    done
    log_action "[可撤销] 开启网卡 SoftIRQ 软中断全核打散均衡"
    echo -e "${GREEN}[成功]${PLAIN} 已将网卡中断负载均匀分发至全系统的 ${cpu_count} 个 CPU 核心！"
}

install_bbrv3_max() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}      安装 BBRv3 Max 激进内核  ${YELLOW}[底层保留/不可撤销]${PLAIN}   ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    if ! command -v dpkg &>/dev/null; then
        echo -e "${RED}[错误]${PLAIN} 目前该编译内核仅支持 Debian / Ubuntu 系统！"; return
    fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}[错误]${PLAIN} 不支持的架构！"; return ;;
    esac

    auto_setup_swap
    echo -e "${BLUE}[信息]${PLAIN} 正在拉取最新 BBRv3 Max 构建版本..."
    local releases_json max_tag
    releases_json=$(curl -s https://api.github.com/repos/byJoey/Actions-bbr-v3/releases)
    max_tag=$(echo "$releases_json" | grep -o "\"tag_name\": *\"[^\"]*${arch}[^\"]*-max\"" | head -n1 | cut -d'"' -f4)

    [[ -z "$max_tag" ]] && { echo -e "${RED}[错误]${PLAIN} 匹配内核失败！"; return; }

    mkdir -p /tmp/bbrv3_install && cd /tmp/bbrv3_install || return
    local deb_urls
    deb_urls=$(echo "$releases_json" | awk "/\"tag_name\": *\"${max_tag}\"/,/\"assets\":/" RS= | grep "browser_download_url.*\.deb" | cut -d'"' -f4 | grep -v "dbg")

    for url in $deb_urls; do
        curl -fSL "$url" -o "$(basename "$url")"
    done

    dpkg -i ./*.deb
    update-grub 2>/dev/null || update-grub2 2>/dev/null

    cat <<EOF > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system &>/dev/null
    cd / && rm -rf /tmp/bbrv3_install
    log_action "[底层保留] 安装 BBRv3 Max 极限内核版本: ${max_tag}"
    echo -e "${GREEN}[成功]${PLAIN} BBRv3 Max 部署完成！"
    read -rp "是否立即重启服务器使内核生效？[y/N]: " reboot_choice
    [[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot
}

apply_production_tune() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}   生产级自适应综合调优  ${GREEN}[可完全撤销]${PLAIN}               ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    auto_setup_swap

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
    set_ipv4_priority
    enable_nic_multiqueue
    log_action "[可撤销] 注入生产级网络优化参数 (百万句柄+自适应缓存+BBR)"
    echo -e "\n${GREEN}[成功]${PLAIN} 生产级综合调优已全部加载完成！"
}

aggressive_speed_mode() {
    clear
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "${RED}${BOLD}   BBR 暴躁/疯批模式  ${GREEN}[可完全撤销]${PLAIN}                  ${PLAIN}"
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    local iface
    iface=$(get_default_interface)
    if [[ -n "$iface" ]]; then
        ip link set dev "$iface" txqueuelen 100000 2>/dev/null
        tc qdisc replace dev "$iface" root fq 2>/dev/null
    fi

    cat <<EOF > "$SYSCTL_CONF"
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.core.optmem_max = 2048576
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_limit_output_bytes = 1048576
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_moderate_rcvbuf = 1
EOF
    sysctl -p "$SYSCTL_CONF" &>/dev/null
    log_action "[可撤销] 开启 BBR 暴躁极限模式 (网卡队列100000+全满缓存)"
    echo -e "${GREEN}[成功]${PLAIN} 暴躁模式已启动！物理队列与缓冲区已全部推满。"
}

reset_all_optimizations() {
    rm -f "$SYSCTL_CONF" "$LIMITS_CONF" /etc/sysctl.d/99-bbr.conf
    sed -i '/precedence ::ffff:0:0\/96  100/d' /etc/gai.conf 2>/dev/null
    local iface
    iface=$(get_default_interface)
    [[ -n "$iface" ]] && ip link set dev "$iface" txqueuelen 1000 2>/dev/null
    sysctl --system &>/dev/null
    log_action "[已撤销] 清除网络优化参数，复原为系统默认值"
    echo -e "${GREEN}[成功]${PLAIN} 所有优化参数已安全清除，恢复系统原生初始状态！"
}

optimize_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}            [模块 3] 网络深度优化与内核调优        ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        show_dashboard
        echo -e "  ${GREEN}1.${PLAIN} 生产级综合调优 ${GREEN}[推荐/参数可完全撤销]${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 安装 BBRv3 Max 极限激进内核 ${YELLOW}[底层内核保留]${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 开启 BBR 暴躁/疯批模式 ${GREEN}[压榨跑分/参数可完全撤销]${PLAIN}"
        echo -e "  ${GREEN}4.${PLAIN} 独立切换: IPv4 优先解析 ${GREEN}[参数可撤销]${PLAIN}"
        echo -e "  ${GREEN}5.${PLAIN} 独立开启: 网卡软中断多核均衡 ${GREEN}[参数可撤销]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${YELLOW}6.${PLAIN} 一键清除所有优化，还原系统默认配置"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${RED}0.${PLAIN} 返回上一级菜单"
        echo -e "${CYAN}====================================================${PLAIN}"

        read -rp "请输入选项 [0-6]: " opt_choice
        case "$opt_choice" in
            1) apply_production_tune; read -rp "按回车键继续..." ;;
            2) install_bbrv3_max; read -rp "按回车键继续..." ;;
            3) aggressive_speed_mode; read -rp "按回车键继续..." ;;
            4) set_ipv4_priority; read -rp "按回车键继续..." ;;
            5) enable_nic_multiqueue; read -rp "按回车键继续..." ;;
            6) reset_all_optimizations; read -rp "按回车键继续..." ;;
            0) break ;;
        esac
    done
}
optimize_menu
