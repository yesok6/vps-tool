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
    local tmpdir script answer script_sha256 review_dir saved_script
    tmpdir=$(make_temp_dir vps-ip-test)
    script="${tmpdir}/${name}.sh"
    if ! download_shell_checked "$url" "$script"; then
        echo -e "${RED}[错误]${PLAIN} 第三方脚本下载或语法检查失败。"
        rm -rf -- "$tmpdir"
        return 1
    fi

    script_sha256=$(sha256sum "$script" | awk '{print $1}') || { rm -rf -- "$tmpdir"; return 1; }
    review_dir="${VPS_TOOL_ETC}/diagnostics"
    if [[ -L "$review_dir" || ( -e "$review_dir" && ! -d "$review_dir" ) ]]; then
        echo -e "${RED}[错误]${PLAIN} 诊断脚本审阅目录不是安全目录，拒绝保存：${review_dir}" >&2
        rm -rf -- "$tmpdir"
        return 1
    fi
    if ! install -d -o root -g root -m 0700 "$review_dir"; then
        echo -e "${RED}[错误]${PLAIN} 无法创建安全的脚本审阅目录。"
        rm -rf -- "$tmpdir"
        return 1
    fi
    saved_script="${review_dir}/${name}_$(date +%Y%m%dT%H%M%S)_${script_sha256:0:12}.sh"
    if ! install -o root -g root -m 0600 "$script" "$saved_script"; then
        echo -e "${RED}[错误]${PLAIN} 无法保存已下载的诊断脚本。"
        rm -rf -- "$tmpdir"
        return 1
    fi

    echo -e "${YELLOW}[第三方脚本]${PLAIN} 已下载并通过 Bash 语法检查，但默认不会执行。"
    echo "  来源：$url"
    echo "  SHA-256：$script_sha256（记录值，不代表上游可信）"
    echo "  审阅文件：$saved_script"
    echo "  查看命令：less '$saved_script'"
    echo -e "${YELLOW}[安全提示]${PLAIN} 该文件以 root:root、0600 保存；请先审阅内容。语法检查和哈希记录都不等于安全审计。"

    if [[ "${VPS_TOOL_ALLOW_REMOTE_DIAGNOSTIC_EXEC:-0}" != "1" ]]; then
        echo -e "${BLUE}[下载完成]${PLAIN} 如确认脚本可信，请先审阅后再手动执行；自动执行需显式设置 VPS_TOOL_ALLOW_REMOTE_DIAGNOSTIC_EXEC=1。"
        log_action "[诊断脚本] 仅下载未执行：${url} sha256=${script_sha256} path=${saved_script}"
        rm -rf -- "$tmpdir"
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo -e "${RED}[安全阻止]${PLAIN} 远程诊断脚本执行要求交互终端；非交互环境只允许下载。"
        rm -rf -- "$tmpdir"
        return 1
    fi
    echo -e "${RED}[高风险确认]${PLAIN} 即将以 root 执行审阅目录中的第三方脚本。"
    read -r -p "请输入 EXECUTE 才继续执行：" answer || answer=""
    if [[ "$answer" != "EXECUTE" ]]; then
        echo -e "${YELLOW}[取消]${PLAIN} 未执行第三方脚本；已下载文件保留供审阅。"
        rm -rf -- "$tmpdir"
        return 1
    fi

    log_action "[测试] 执行第三方诊断脚本：${url} sha256=${script_sha256} path=${saved_script}"
    local rc=0
    if ( cd "$(dirname -- "$saved_script")" && bash "$saved_script" ); then rc=0; else rc=$?; fi
    rm -rf -- "$tmpdir"
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
            1) run_test_ipquality || true; read -rp "按回车键返回菜单..." ;;
            2) run_test_streaming_ai || true; read -rp "按回车键返回菜单..." ;;
            3) run_test_route || true; read -rp "按回车键返回菜单..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ip_test_menu
fi
