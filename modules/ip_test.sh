#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

TEMP_WORK_DIR="/tmp/vps_ip_audit_$$"
LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

log_action() {
    mkdir -p "${LOG_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

[[ $EUID -ne 0 ]] && echo -e "${RED}[错误]${PLAIN} 请使用 root 权限运行！" && exit 1

check_hardware_safety() {
    local req_mem_mb="${1:-180}"
    local mem_avail_kb
    mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
    if [[ -z "$mem_avail_kb" ]]; then
        local mem_free_kb swap_free_kb
        mem_free_kb=$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null)
        swap_free_kb=$(awk '/SwapFree/ {print $2}' /proc/meminfo 2>/dev/null)
        mem_avail_kb=$((mem_free_kb + swap_free_kb))
    fi
    local mem_avail_mb=$((mem_avail_kb / 1024))
    local disk_avail_mb
    disk_avail_mb=$(df -m / | awk 'NR==2 {print $4}')

    echo -e "${CYAN}[硬件安全审计]${PLAIN} 可用内存: ${GREEN}${mem_avail_mb} MB${PLAIN} | 磁盘剩余: ${GREEN}${disk_avail_mb} MB${PLAIN}"

    if [ "$disk_avail_mb" -lt 300 ]; then
        echo -e "${RED}${BOLD}[严重警告] 磁盘剩余空间小于 300MB，极度危险！${PLAIN}"
        read -rp "依然强制运行？[y/N]: " f_disk
        [[ ! "$f_disk" =~ ^[Yy]$ ]] && return 1
    fi

    if [ "$mem_avail_mb" -lt "$req_mem_mb" ]; then
        echo -e "${YELLOW}[预警] 可用内存偏低 (${mem_avail_mb}MB)，测试可能短暂卡顿。${PLAIN}"
        read -rp "建议确认是否继续？[Y/n]: " proceed_mem
        [[ "$proceed_mem" =~ ^[Nn]$ ]] && return 1
    fi
    return 0
}

cleanup_environment() {
    echo -e "${BLUE}[清理中]${PLAIN} 正在自动回收临时文件..."
    rm -rf "$TEMP_WORK_DIR" /tmp/check.sh /tmp/RegionRestrictionCheck* /tmp/backtrace*
    echo -e "${GREEN}[完成]${PLAIN} 系统环境已安全复原，无任何残留。"
}

run_test_ipquality() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}   选项 1: IPQuality 综合 IP 纯净度与欺诈评分      ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    check_hardware_safety 120 || return

    mkdir -p "$TEMP_WORK_DIR" && cd "$TEMP_WORK_DIR" || return
    log_action "[测试] 运行 IPQuality 欺诈度测试"
    bash <(curl -Ls https://IP.Check.Place) -y
    cd / && cleanup_environment
}

run_test_streaming_ai() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN} 选项 2: RegionRestrictionCheck 流媒体与 AI 解锁   ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    check_hardware_safety 100 || return

    mkdir -p "$TEMP_WORK_DIR" && cd "$TEMP_WORK_DIR" || return
    log_action "[测试] 运行流媒体与 AI 解锁检测"
    bash <(curl -L -s check.unlock.media)
    cd / && cleanup_environment
}

run_test_route() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}    选项 3: 三网回程路由诊断 (识别 CN2/9929/CMI)    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    check_hardware_safety 150 || return

    mkdir -p "$TEMP_WORK_DIR" && cd "$TEMP_WORK_DIR" || return
    log_action "[测试] 运行三网回程路由诊断"
    curl -fsSL https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh -o /tmp/backtrace.sh
    if [[ -f /tmp/backtrace.sh ]]; then
        bash /tmp/backtrace.sh
    else
        wget -qO- https://raw.githubusercontent.com/fscarmen/tools/main/backtrace.sh | bash
    fi
    cd / && cleanup_environment
}

ip_test_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}         [模块 5] VPS 质量体检与 IP 纯净度检测      ${PLAIN}"
        echo -e "  特性属性: ${GREEN}[所有测试均为即用即焚，结束后自动清除缓存无残留]${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} IP 纯净度与欺诈分测定 ${BLUE}[xykt: 查原生/双ISP/风控画像]${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 流媒体与 AI 解锁测试  ${BLUE}[lmc999: 测奈飞/TikTok/ChatGPT]${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 三网回程路由线路识别  ${BLUE}[识别电信CN2/联通9929/移动CMI]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${RED}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}====================================================${PLAIN}"

        read -rp "请输入选项 [0-3]: " test_choice
        case "$test_choice" in
            1) run_test_ipquality; read -rp "按回车键返回菜单..." ;;
            2) run_test_streaming_ai; read -rp "按回车键返回菜单..." ;;
            3) run_test_route; read -rp "按回车键返回菜单..." ;;
            0) break ;;
        esac
    done
}
ip_test_menu
