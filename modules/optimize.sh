#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

SYSCTL_CONF="/etc/sysctl.d/99-vps-optimizer.conf"
LIMITS_CONF="/etc/security/limits.d/99-nofile.conf"
GAI_CONF="/etc/gai.conf"
SWAP_PATH="/var/lib/vps-tool/swapfile"

get_default_interface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

current_swap_mb() {
    awk 'NR > 1 {sum += $3} END {printf "%d\n", sum / 1024}' /proc/swaps 2>/dev/null
}

create_all_cpu_mask() {
    local cpu_count="$1" words=() cpu word bit value i out=""
    for ((cpu=0; cpu<cpu_count; cpu++)); do
        word=$((cpu / 32)); bit=$((cpu % 32))
        value=${words[$word]:-0}
        value=$((value | (1 << bit)))
        words[$word]=$value
    done
    for ((i=${#words[@]}-1; i>=0; i--)); do
        printf -v value '%08x' "${words[$i]}"
        out+="${out:+,}${value}"
    done
    printf '%s\n' "$out" | sed 's/^0*//' | sed 's/^$/0/'
}

ensure_swap_if_needed() {
    local mem_total_mb swap_mb
    mem_total_mb=$(free -m | awk '/Mem:/ {print $2}')
    swap_mb=$(current_swap_mb)
    if (( mem_total_mb >= 2048 || swap_mb >= 512 )); then
        return 0
    fi

    if [[ -e "$SWAP_PATH" ]] && ! is_owned "$SWAP_PATH"; then
        echo -e "${YELLOW}[提示]${PLAIN} ${SWAP_PATH} 已存在但不是本工具创建的，拒绝覆盖。"
        return 0
    fi

    mkdir -p "$(dirname "$SWAP_PATH")"
    if [[ ! -e "$SWAP_PATH" ]]; then
        fallocate -l 1G "$SWAP_PATH" 2>/dev/null || dd if=/dev/zero of="$SWAP_PATH" bs=1M count=1024 status=none
        chmod 600 "$SWAP_PATH"
        mkswap "$SWAP_PATH" >/dev/null
        swapon "$SWAP_PATH"
        grep -Fqx "$SWAP_PATH none swap sw 0 0" /etc/fstab || printf '%s\n' "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
        mark_owned "$SWAP_PATH"
        state_set swap_created 1
        log_action "[可撤销] 创建 VPS-Tool Swap：${SWAP_PATH}"
        echo -e "${GREEN}[完成]${PLAIN} 低内存 VPS 已增加 1GB 工具专属 Swap。"
    fi
}

write_sysctl_config() {
    local cc="$1"
    local rmem_max=33554432 wmem_max=33554432
    local total_mem_kb
    total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    (( total_mem_kb > 2097152 )) && { rmem_max=67108864; wmem_max=67108864; }

    backup_file_once "$SYSCTL_CONF" sysctl_optimizer_conf
    cat > "$SYSCTL_CONF" <<EOF2
# Managed by VPS-Tool; original file is backed up under /etc/vps-tool/backups.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}
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
net.ipv4.tcp_mtu_probing = 1
EOF2
    chmod 644 "$SYSCTL_CONF"
    if ! sysctl --load "$SYSCTL_CONF" >/dev/null; then
        restore_file_backup "$SYSCTL_CONF" sysctl_optimizer_conf || true
        sysctl --system >/dev/null 2>&1 || true
        echo -e "${RED}[错误]${PLAIN} 当前内核不接受全部优化参数，已自动恢复原配置。"
        return 1
    fi
}

apply_gai_ipv4_priority() {
    local original_exists=0
    [[ -e "$GAI_CONF" ]] && original_exists=1
    backup_file_once "$GAI_CONF" gai_conf
    touch "$GAI_CONF"
    if ! grep -Fqx 'precedence ::ffff:0:0/96  100' "$GAI_CONF"; then
        printf '%s\n' 'precedence ::ffff:0:0/96  100' >> "$GAI_CONF"
        state_set gai_added_by_tool 1
    else
        state_set gai_added_by_tool 0
    fi
    state_set gai_original_exists "$original_exists"
}

enable_nic_multiqueue() {
    local iface cpu_count mask file changed=0
    iface=$(get_default_interface)
    [[ -n "$iface" ]] || { echo -e "${YELLOW}[提示]${PLAIN} 未找到默认网卡。"; return 0; }
    cpu_count=$(nproc)
    (( cpu_count > 1 )) || { echo -e "${YELLOW}[提示]${PLAIN} 单核 CPU 无需 RPS/XPS。"; return 0; }
    mask=$(create_all_cpu_mask "$cpu_count")

    for file in /sys/class/net/${iface}/queues/rx-*/rps_cpus /sys/class/net/${iface}/queues/tx-*/xps_cpus; do
        [[ -f "$file" ]] || continue
        record_runtime_value "$file"
        if printf '%s\n' "$mask" > "$file" 2>/dev/null; then
            ((changed += 1))
        fi
    done
    log_action "[可撤销] RPS/XPS 应用到 ${iface}，CPU=${cpu_count}，mask=${mask}"
    echo -e "${GREEN}[完成]${PLAIN} 已成功修改 ${changed} 个 RPS/XPS 队列。"
}

set_ipv4_priority() {
    apply_gai_ipv4_priority
    log_action "[可撤销] 启用 IPv4 优先解析"
    echo -e "${GREEN}[成功]${PLAIN} IPv4 优先解析已启用。"
}

apply_production_tune() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}            [生产级安全网络调优]                 ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    ensure_swap_if_needed
    backup_file_once "$LIMITS_CONF" limits_conf
    mkdir -p "$(dirname "$LIMITS_CONF")"
    cat > "$LIMITS_CONF" <<'EOF2'
# Managed by VPS-Tool.
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF2
    chmod 644 "$LIMITS_CONF"

    local available_cc current_cc
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<< "$available_cc"; then current_cc=bbr; fi
    current_cc="${current_cc:-cubic}"

    if ! write_sysctl_config "$current_cc"; then
        return 1
    fi
    set_ipv4_priority
    enable_nic_multiqueue
    log_action "[可撤销] 应用生产级网络调优"
    echo -e "${GREEN}[成功]${PLAIN} 生产级调优已完成；所有配置均有原始备份。"
}

safe_bbr_current_kernel() {
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! grep -qw bbr <<< "$available"; then
        echo -e "${YELLOW}[提示]${PLAIN} 当前内核没有 BBR，不会自动更换内核。"
        return 1
    fi
    backup_file_once "$SYSCTL_CONF" sysctl_optimizer_conf
    cat > "$SYSCTL_CONF" <<'EOF2'
# Managed by VPS-Tool.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF2
    if ! sysctl --load "$SYSCTL_CONF" >/dev/null; then
        restore_file_backup "$SYSCTL_CONF" sysctl_optimizer_conf || true
        sysctl --system >/dev/null 2>&1 || true
        return 1
    fi
    log_action "[可撤销] 启用当前内核自带 BBR；未更换内核"
    echo -e "${GREEN}[成功]${PLAIN} 已启用当前内核支持的 BBR；没有安装第三方内核。"
}

aggressive_speed_mode() {
    clear
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "${RED}${BOLD}             [高强度队列/缓存模式]               ${PLAIN}"
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    confirm_safety_prompt "高强度网络参数" "此模式会显著提高缓冲区与网卡队列，适合有明确测试目标的机器。" || return 0

    local iface qlen
    iface=$(get_default_interface)
    if [[ -n "$iface" ]]; then
        qlen=$(ip -o link show dev "$iface" | sed -n 's/.* qlen \([0-9]\+\).*/\1/p')
        [[ -n "$qlen" ]] && state_set "nic_qlen_${iface}" "$qlen"
        ip link set dev "$iface" txqueuelen 100000
        state_set aggressive_nic "${iface}"
    fi

    backup_file_once "$SYSCTL_CONF" sysctl_optimizer_conf
    cat > "$SYSCTL_CONF" <<'EOF2'
# Managed by VPS-Tool.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_limit_output_bytes = 1048576
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOF2
    if ! sysctl --load "$SYSCTL_CONF" >/dev/null; then
        restore_file_backup "$SYSCTL_CONF" sysctl_optimizer_conf || true
        sysctl --system >/dev/null 2>&1 || true
        if [[ -n "$iface" && -n "$qlen" ]]; then ip link set dev "$iface" txqueuelen "$qlen" >/dev/null 2>&1 || true; fi
        state_unset aggressive_nic
        [[ -n "$iface" ]] && state_unset "nic_qlen_${iface}"
        echo -e "${RED}[错误]${PLAIN} 高强度参数被当前内核拒绝，已恢复。"
        return 1
    fi
    log_action "[可撤销] 开启高强度队列/缓存模式"
    echo -e "${GREEN}[成功]${PLAIN} 高强度模式已启用。"
}

reset_all_optimizations() {
    echo -e "${BLUE}[恢复]${PLAIN} 仅恢复 VPS-Tool 自己修改并记录过的项目。"
    restore_file_backup "$SYSCTL_CONF" sysctl_optimizer_conf || true
    restore_file_backup "$LIMITS_CONF" limits_conf || true
    if [[ "$(state_get gai_added_by_tool 2>/dev/null || true)" == "1" ]]; then
        sed -i '/^precedence ::ffff:0:0\/96[[:space:]]\+100$/d' "$GAI_CONF" 2>/dev/null || true
    fi
    if [[ "$(state_get gai_original_exists 2>/dev/null || true)" == "0" && -f "$GAI_CONF" ]]; then
        [[ ! -s "$GAI_CONF" ]] && rm -f "$GAI_CONF"
    fi
    state_unset gai_added_by_tool
    state_unset gai_original_exists

    if [[ "$(state_get swap_created 2>/dev/null || true)" == "1" ]] && is_owned "$SWAP_PATH"; then
        swapoff "$SWAP_PATH" >/dev/null 2>&1 || true
        rm -f "$SWAP_PATH"
        sed -i \#"^${SWAP_PATH}[[:space:]]"#d /etc/fstab 2>/dev/null || true
        unmark_owned "$SWAP_PATH"
    fi
    state_unset swap_created

    restore_runtime_values
    local iface qlen
    iface=$(state_get aggressive_nic 2>/dev/null || true)
    if [[ -n "$iface" ]]; then
        qlen=$(state_get "nic_qlen_${iface}" 2>/dev/null || true)
        if [[ -n "$qlen" ]]; then ip link set dev "$iface" txqueuelen "$qlen" >/dev/null 2>&1 || true; fi
        state_unset aggressive_nic
        state_unset "nic_qlen_${iface}"
    fi

    sysctl --system >/dev/null 2>&1 || true
    log_action "[已撤销] 恢复 VPS-Tool 记录的网络优化配置"
    echo -e "${GREEN}[完成]${PLAIN} 已恢复本工具记录过的原始配置。未被本工具备份的用户自定义配置不会被删除。"
}

show_dashboard() {
    local cur_kernel cc qdisc avail iface
    cur_kernel=$(uname -r)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)
    iface=$(get_default_interface)
    echo -e "${CYAN}------------------- 当前状态 -------------------${PLAIN}"
    echo "内核：$cur_kernel"
    echo "拥塞控制：$cc    默认 qdisc：$qdisc"
    echo "可用拥塞控制：$avail"
    echo "默认网卡：${iface:-unknown}"
    echo "Swap：$(current_swap_mb) MB"
    echo -e "${CYAN}-----------------------------------------------${PLAIN}"
}

optimize_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              [模块 3] 网络深度优化              ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        show_dashboard
        echo "  1. 生产级综合调优（带备份/失败恢复）"
        echo "  2. 启用当前内核 BBR（不更换第三方内核）"
        echo "  3. 高强度队列/缓存模式（可恢复）"
        echo "  4. IPv4 优先解析"
        echo "  5. RPS/XPS 多核均衡"
        echo "  6. 恢复本工具记录过的优化"
        echo "  0. 返回"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-6]: " choice
        case "$choice" in
            1) apply_production_tune; read -rp "按回车继续..." ;;
            2) safe_bbr_current_kernel; read -rp "按回车继续..." ;;
            3) aggressive_speed_mode; read -rp "按回车继续..." ;;
            4) set_ipv4_priority; read -rp "按回车继续..." ;;
            5) enable_nic_multiqueue; read -rp "按回车继续..." ;;
            6) reset_all_optimizations; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    optimize_menu
fi
