#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

check_hardware_safety() {
    local req_mem_mb="${1:-180}"
    local mem_avail_kb disk_avail_mb mem_avail_mb answer
    mem_avail_kb=$(awk '/MemAvailable/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    mem_avail_mb=$((mem_avail_kb / 1024))
    disk_avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')

    echo -e "${CYAN}[硬件审计]${PLAIN} 可用内存 ${mem_avail_mb}MB，磁盘 ${disk_avail_mb}MB"
    if (( disk_avail_mb < 300 )); then
        echo -e "${RED}[警告]${PLAIN} 根分区剩余空间低于 300MB。"
        read -rp "仍要运行？[y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 1
    fi
    if (( mem_avail_mb < req_mem_mb )); then
        echo -e "${YELLOW}[提示]${PLAIN} 可用内存较低，测试可能产生额外负载。"
        read -rp "继续？[Y/n]: " answer
        [[ "$answer" =~ ^[Nn]$ ]] && return 1
    fi
}

run_remote_diagnostic() {
    local name="$1" url="$2"
    local tmpdir script answer
    tmpdir=$(make_temp_dir vps-ip-test)
    script="${tmpdir}/${name}.sh"
    if ! download_shell_checked "$url" "$script"; then
        echo -e "${RED}[错误]${PLAIN} 第三方脚本下载或语法检查失败。"
        rm -rf "$tmpdir"
        return 1
    fi

    echo -e "${YELLOW}[第三方脚本]${PLAIN} 即将以 root 身份执行："
    echo "  $url"
    read -rp "确认执行？[y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        rm -rf "$tmpdir"
        echo -e "${YELLOW}[取消]${PLAIN} 未执行第三方脚本。"
        return 0
    fi

    log_action "[测试] 执行第三方诊断脚本：${url}"
    local rc=0
    if ! ( cd "$tmpdir" && bash "$script" ); then
        rc=$?
    fi
    rm -rf "$tmpdir"
    return "$rc"
}

run_test_ipquality() {
    clear
    echo -e "${CYAN}================ IPQuality ================${PLAIN}"
    check_hardware_safety 120 || return 0
    # 远程脚本仍然来自第三方，因此默认要求人工确认。
    run_remote_diagnostic ipquality 'https://IP.Check.Place'
}

run_test_streaming_ai() {
    clear
    echo -e "${CYAN}========== RegionRestrictionCheck ==========${PLAIN}"
    check_hardware_safety 100 || return 0
    run_remote_diagnostic region-restriction 'https://check.unlock.media'
}

run_test_route() {
    clear
    echo -e "${CYAN}============== 回程路由诊断 ===============${PLAIN}"
    check_hardware_safety 150 || return 0
    run_remote_diagnostic backtrace 'https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh'
}

ip_test_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              [模块 5] IP 与网络诊断              ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo "1. IPQuality 欺诈/纯净度测试"
        echo "2. 流媒体/AI 可用性测试"
        echo "3. 三网回程路由测试"
        echo "0. 返回"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-3]: " choice
        case "$choice" in
            1) run_test_ipquality || true; read -rp "按回车继续..." ;;
            2) run_test_streaming_ai || true; read -rp "按回车继续..." ;;
            3) run_test_route || true; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ip_test_menu
fi
