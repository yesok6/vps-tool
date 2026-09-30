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
        return 1
    fi

    log_action "[测试] 执行第三方诊断脚本：${url}"
    local rc=0
    if ( cd "$tmpdir" && bash "$script" ); then
        rc=0
    else
        rc=$?
    fi
    rm -rf "$tmpdir"
    return "$rc"
}

run_test_ipquality() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}   选项 1: IPQuality 综合 IP 纯净度与欺诈评分      ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    check_hardware_safety 120 || return 0
    log_action "[测试] 运行 IPQuality 欺诈度测试"
    run_remote_diagnostic ipquality 'https://IP.Check.Place'
}

run_test_streaming_ai() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN} 选项 2: RegionRestrictionCheck 流媒体与 AI 解锁   ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    check_hardware_safety 100 || return 0
    log_action "[测试] 运行流媒体与 AI 解锁检测"
    run_remote_diagnostic region-restriction 'https://check.unlock.media'
}

run_test_route() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}    选项 3: 三网回程路由诊断 (识别 CN2/9929/CMI)    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    check_hardware_safety 150 || return 0
    log_action "[测试] 运行三网回程路由诊断"
    run_remote_diagnostic backtrace 'https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh'
}


ip_test_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}         [模块 5] VPS 质量体检与 IP 纯净度检测      ${PLAIN}"
        echo -e "  特性属性: ${GREEN}[即用即焚/仅清理本工具临时文件]${PLAIN}"
        echo -e "  ${YELLOW}提示：第三方诊断脚本可能自行创建文件，本工具无法保证其外部残留全部可撤销。${PLAIN}"
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
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ip_test_menu
fi
