#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

run_step_system_upgrade() {
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    echo -e "${BLUE}[流水线 1/4]${PLAIN} 升级系统软件与修补安全补丁 ${YELLOW}[不可逆更新]${PLAIN}..."
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    sys_full_upgrade
}

run_step_network_tune() {
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    echo -e "${BLUE}[流水线 2/4]${PLAIN} 优化内核底座 (BBR/大缓存/多核) ${GREEN}[参数可完全撤销]${PLAIN}..."
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    VPS_TOOL_PIPELINE=1 bash "${SCRIPT_DIR}/optimize.sh" --pipeline-network
}

run_step_deploy_reality() {
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    echo -e "${BLUE}[流水线 3/4]${PLAIN} 部署 VLESS + Reality ${GREEN}[本机配置可完全撤销]${PLAIN}..."
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"
    VPS_TOOL_PIPELINE=1 bash "${SCRIPT_DIR}/protocol.sh" --pipeline-reality
}

run_step_firewall_note() {
    echo -e "${BLUE}[流水线 4/4]${PLAIN} 防火墙端口放行 ${YELLOW}[部分可撤销/安全保留]${PLAIN}..."
    echo -e "${YELLOW}[提示]${PLAIN} 协议部署阶段会根据现有防火墙状态尝试放行端口；云平台安全组仍需自行确认。"
}

run_all_in_one() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}         [模块 4] 一键全自动综合装配流水线          ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "全自动流水线将为您完成:"
    echo -e "  1. 系统补丁与时间校准   ${YELLOW}[不可逆更新]${PLAIN}"
    echo -e "  2. 生产级网络内核调优   ${GREEN}[参数可完全撤销]${PLAIN}"
    echo -e "  3. VLESS-Reality 协议   ${GREEN}[本机配置可完全撤销/流水线自动选端口]${PLAIN}"
    echo -e "  4. 防火墙端口放行       ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    read -rp "是否立即开始全套部署？[Y/n]: " start_choice
    [[ "$start_choice" =~ ^[Nn]$ ]] && { echo -e "${YELLOW}操作取消${PLAIN}"; return 0; }

    run_step_system_upgrade || {
        echo -e "${YELLOW}[提示]${PLAIN} 系统升级步骤未完成（可能是用户取消确认或升级失败）。"
        echo -e "${RED}[停止]${PLAIN} 流水线已停止，不会继续执行后续步骤。"
        return 1
    }
    run_step_network_tune || { echo -e "${RED}[停止]${PLAIN} 网络优化失败，流水线已停止。"; return 1; }
    run_step_deploy_reality || { echo -e "${RED}[停止]${PLAIN} 协议部署失败，流水线已停止。"; return 1; }
    run_step_firewall_note

    echo -e "${GREEN}${BOLD}恭喜！全套 VPS 优化与网络协议部署已执行完成！${PLAIN}"
    log_action "[流水线] 4 个阶段执行完成（其中系统升级为不可逆变更，协议阶段自动选择端口，防火墙放行为部分可撤销）"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_all_in_one
fi
