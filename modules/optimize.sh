#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

SYSCTL_CONF="/etc/sysctl.d/99-vps-optimizer.conf"
LIMITS_CONF="/etc/security/limits.d/99-nofile.conf"
GAI_CONF="/etc/gai.conf"
SWAP_PATH="${VPS_TOOL_SWAP_PATH}"

get_default_interface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
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
    # [可完全撤销] 生产级调优沿用公共 Swap 管理；不覆盖用户现有 Swap。
    local mem_available_mb swap_mb recommended_mb
    mem_available_mb=$(get_mem_available_mb)
    swap_mb=$(current_swap_mb)
    if (( mem_available_mb >= 256 || swap_mb >= 1024 )); then
        return 0
    fi
    recommended_mb=$(recommend_managed_swap_mb)
    (( recommended_mb > 0 )) || return 2
    ensure_managed_swap "$recommended_mb"
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
    if ! sysctl -p "$SYSCTL_CONF" >/dev/null; then
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


install_bbrv3_max() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}      安装 BBRv3 Max 激进内核  ${YELLOW}[底层保留/不可逆变更]${PLAIN}   ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    confirm_safety_prompt "安装 BBRv3 Max 激进内核" "内核安装属于底层变更；本工具无法把已安装的新内核完整恢复为安装前状态。请确认云平台控制台/VNC、救援模式或带外管理可用。" || return 1
    check_os || return 1
    if [[ "$PKG_MANAGER" != "apt" ]]; then
        echo -e "${RED}[错误]${PLAIN} 目前该编译内核仅支持 Debian / Ubuntu 系统！"; return 1
    fi
    local arch releases_json max_tag tmp deb_urls url file valid=0
    case "$(uname -m)" in
        x86_64) arch="x86_64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}[错误]${PLAIN} 不支持的架构！"; return 1 ;;
    esac
    ensure_swap_if_needed || return 1
    echo -e "${BLUE}[信息]${PLAIN} 正在拉取最新 BBRv3 Max 构建版本..."
    releases_json=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 https://api.github.com/repos/byJoey/Actions-bbr-v3/releases) || return 1
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$releases_json"; then
        echo -e "${RED}[错误]${PLAIN} GitHub Releases 返回的数据格式异常。"
        return 1
    fi
    max_tag=$(jq -r --arg arch "$arch" '[.[] | select((.tag_name | contains($arch)) and (.tag_name | endswith("-max")))] | .[0].tag_name // empty' <<<"$releases_json")
    [[ -n "$max_tag" ]] || { echo -e "${RED}[错误]${PLAIN} 匹配内核失败！"; return 1; }
    tmp=$(make_temp_dir bbrv3_install)
    deb_urls=$(jq -r --arg tag "$max_tag" '.[] | select(.tag_name == $tag) | .assets[]? | select((.browser_download_url | endswith(".deb")) and ((.name | contains("dbg")) | not)) | .browser_download_url' <<<"$releases_json")
    [[ -n "$deb_urls" ]] || { rm -rf "$tmp"; echo -e "${RED}[错误]${PLAIN} 未找到可用内核安装包。"; return 1; }
    for url in $deb_urls; do
        file="${tmp}/$(basename "$url")"
        if ! download_https "$url" "$file"; then rm -rf "$tmp"; return 1; fi
        if ! dpkg-deb --info "$file" >/dev/null 2>&1; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 下载的内核包校验失败：$(basename "$file")"
            return 1
        fi
        valid=1
    done
    (( valid == 1 )) || { rm -rf "$tmp"; return 1; }
    backup_file_once "/etc/sysctl.d/99-bbr.conf" bbr_sysctl_conf
    if ! apt-get install -y "${tmp}"/*.deb; then
        rm -rf "$tmp"
        echo -e "${RED}[错误]${PLAIN} 内核依赖无法由 apt 自动解决，已停止安装。"
        return 1
    fi
    update-grub 2>/dev/null || update-grub2 2>/dev/null || { rm -rf "$tmp"; return 1; }
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF2'
# VPS-Tool：BBRv3 Max 内核对应的运行参数
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF2
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null || true
    rm -rf "$tmp"
    log_action "[底层保留/不可逆变更] 安装 BBRv3 Max 极限内核版本: ${max_tag}"
    echo -e "${GREEN}[成功]${PLAIN} BBRv3 Max 内核已安装。内核文件本身不会由“一键清理”自动卸载。"
    read -rp "是否立即重启服务器使内核生效？[y/N]: " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

apply_production_tune() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}            [生产级安全网络调优]                 ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local swap_state_before swap_created_now=0
    swap_state_before=$(state_get swap_created 2>/dev/null || true)
    if ! ensure_swap_if_needed; then
        echo -e "${RED}[错误]${PLAIN} 当前内存/Swap 环境无法完成生产级调优，已停止后续优化。"
        return 1
    fi
    [[ "$swap_state_before" == "1" || "$(state_get swap_created 2>/dev/null || true)" != "1" ]] || swap_created_now=1
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
        if (( swap_created_now )); then
            if swapoff "$SWAP_PATH" >/dev/null 2>&1; then
                sed -i "\#^${SWAP_PATH}[[:space:]]#d" /etc/fstab 2>/dev/null || true
                rm -f "$SWAP_PATH"
                unmark_owned "$SWAP_PATH"
                state_unset swap_created
            else
                echo -e "${YELLOW}[警告]${PLAIN} 网络调优失败，但新建 Swap 无法自动关闭，已保留以避免破坏当前系统。"
            fi
        fi
        return 1
    fi
    set_ipv4_priority
    enable_nic_multiqueue
    log_action "[可撤销] 应用生产级网络调优"
    echo -e "${GREEN}[成功]${PLAIN} 生产级调优已完成；所有配置均有原始备份。"
}

restore_nic_txqueuelen() {
    local iface="$1" qlen="$2"
    [[ -n "$iface" && -n "$qlen" ]] || return 1
    ip link set dev "$iface" txqueuelen "$qlen" >/dev/null 2>&1
}

aggressive_speed_mode() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "${RED}${BOLD}   BBR 暴躁/疯批模式  ${GREEN}[参数可完全撤销]${PLAIN}                  ${PLAIN}"
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    confirm_safety_prompt "高强度网络参数" "此模式会显著提高缓冲区与网卡队列；参数本身可回滚，但实际网络效果依赖当前内核与云厂商，请确认有控制台/VNC。" || return 1

    local iface qlen nic_changed=0
    iface=$(get_default_interface)
    if [[ -n "$iface" ]]; then
        qlen=$(ip -o link show dev "$iface" | sed -n 's/.* qlen \([0-9]\+\).*/\1/p')
        [[ -n "$qlen" ]] || { echo -e "${RED}[错误]${PLAIN} 无法读取网卡发送队列长度。"; return 1; }
        state_set "nic_qlen_${iface}" "$qlen"
        if ! ip link set dev "$iface" txqueuelen 100000 >/dev/null 2>&1; then
            state_unset "nic_qlen_${iface}"
            echo -e "${RED}[错误]${PLAIN} 网卡发送队列修改失败，未继续写入高强度参数。"
            return 1
        fi
        nic_changed=1
        state_set aggressive_nic "${iface}"
    fi

    backup_file_once "$SYSCTL_CONF" sysctl_optimizer_conf
    cat > "$SYSCTL_CONF" <<'EOF2'
# VPS-Tool：BBR 暴躁/疯批模式参数
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
    if ! sysctl -p "$SYSCTL_CONF" >/dev/null; then
        restore_file_backup "$SYSCTL_CONF" sysctl_optimizer_conf || true
        if [[ -f "$SYSCTL_CONF" ]]; then sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true; else sysctl --system >/dev/null 2>&1 || true; fi
        if (( nic_changed )); then
            if ! restore_nic_txqueuelen "$iface" "$qlen"; then
                echo -e "${RED}[严重警告]${PLAIN} 网卡队列回滚失败，请手工恢复：${iface} qlen ${qlen}。"
                return 1
            fi
        fi
        state_unset aggressive_nic
        [[ -n "$iface" ]] && state_unset "nic_qlen_${iface}"
        echo -e "${RED}[错误]${PLAIN} 高强度参数被当前内核拒绝，已恢复。"
        return 1
    fi
    log_action "[可撤销] 开启 BBR 暴躁极限模式 (网卡队列100000+全满缓存)"
    echo -e "${GREEN}[成功]${PLAIN} BBR 暴躁/疯批模式已启用。"
}


reset_all_optimizations() {
    local restore_failed=0 iface qlen
    echo -e "${BLUE}[恢复]${PLAIN} 仅恢复 VPS-Tool 自己修改并记录过的项目。"
    restore_file_backup "$SYSCTL_CONF" sysctl_optimizer_conf || true
    restore_file_backup "$LIMITS_CONF" limits_conf || true
    if [[ "$(state_get gai_added_by_tool 2>/dev/null || true)" == "1" ]]; then
        sed -i '\#^precedence ::ffff:0:0\/96[[:space:]]\+100$#d' "$GAI_CONF" 2>/dev/null || restore_failed=1
    fi
    if [[ "$(state_get gai_original_exists 2>/dev/null || true)" == "0" && -f "$GAI_CONF" ]]; then
        [[ ! -s "$GAI_CONF" ]] && rm -f "$GAI_CONF"
    fi
    state_unset gai_added_by_tool
    state_unset gai_original_exists

    if [[ "$(state_get swap_created 2>/dev/null || true)" == "1" ]] && is_owned "$SWAP_PATH"; then
        if swapoff "$SWAP_PATH" >/dev/null 2>&1; then
            rm -f "$SWAP_PATH"
            sed -i "\#^${SWAP_PATH}[[:space:]]#d" /etc/fstab 2>/dev/null || restore_failed=1
            unmark_owned "$SWAP_PATH"
        else
            echo -e "${YELLOW}[警告]${PLAIN} 无法关闭工具创建的 Swap，保留文件以避免破坏当前系统。"
            restore_failed=1
        fi
    fi
    state_unset swap_created
    state_unset swap_size_mb

    restore_runtime_values || true
    iface=$(state_get aggressive_nic 2>/dev/null || true)
    if [[ -n "$iface" ]]; then
        qlen=$(state_get "nic_qlen_${iface}" 2>/dev/null || true)
        if ! restore_nic_txqueuelen "$iface" "$qlen"; then
            echo -e "${RED}[严重警告]${PLAIN} 网卡发送队列恢复失败，请手工执行：ip link set dev ${iface} txqueuelen ${qlen}"
            restore_failed=1
        fi
        state_unset aggressive_nic
        state_unset "nic_qlen_${iface}"
    fi

    if [[ -f "$SYSCTL_CONF" ]]; then sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || restore_failed=1; else sysctl --system >/dev/null 2>&1 || restore_failed=1; fi
    if (( restore_failed )); then
        log_action "[部分撤销] 网络优化恢复存在未能自动完成的项目"
        echo -e "${YELLOW}[警告]${PLAIN} 部分变更未能自动恢复，请查看终端提示与审计日志。"
        return 1
    fi
    log_action "[已撤销] 清除网络优化参数，复原工具修改前状态"
    echo -e "${GREEN}[成功]${PLAIN} 本工具记录的网络优化参数已恢复。"
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
        echo -e "${CYAN}              [模块 3] 网络深度优化                 ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        show_dashboard
        echo -e "  ${GREEN}1.${PLAIN} 生产级综合调优 ${GREEN}[参数可完全撤销]${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 安装 BBRv3 Max 激进内核 ${YELLOW}[底层变更/不可逆]${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 开启 BBR 暴躁/疯批模式 ${GREEN}[参数可完全撤销]${PLAIN}"
        echo -e "  ${GREEN}4.${PLAIN} 独立切换: IPv4 优先解析 ${GREEN}[参数可撤销]${PLAIN}"
        echo -e "  ${GREEN}5.${PLAIN} 独立开启: 网卡软中断多核均衡 ${GREEN}[参数可撤销]${PLAIN}"
        echo -e "  ${YELLOW}6.${PLAIN} 一键清除所有优化，还原本工具记录的原始配置"
        echo -e "  ${RED}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-6]: " choice
        case "$choice" in
            1) apply_production_tune || true; read -rp "按回车继续..." ;;
            2) install_bbrv3_max || true; read -rp "按回车继续..." ;;
            3) aggressive_speed_mode || true; read -rp "按回车继续..." ;;
            4) set_ipv4_priority || true; read -rp "按回车继续..." ;;
            5) enable_nic_multiqueue || true; read -rp "按回车继续..." ;;
            6) reset_all_optimizations || true; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --pipeline-network) apply_production_tune ;;
        --bbrv3-max) install_bbrv3_max ;;
        *) optimize_menu ;;
    esac
fi
