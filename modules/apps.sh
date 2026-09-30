#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/optimize.sh"
source "${SCRIPT_DIR}/protocol.sh"
require_root

run_step_system_upgrade() {
    echo -e "${BLUE}[流水线 1/3]${PLAIN} 系统软件与安全更新"
    sys_full_upgrade
}

run_step_network_tune() {
    echo -e "${BLUE}[流水线 2/3]${PLAIN} 应用可回滚网络调优"
    apply_production_tune
}

run_step_deploy_reality() {
    echo -e "${BLUE}[流水线 3/3]${PLAIN} 部署 VLESS + Reality"
    deploy_vless_reality
}

run_all_in_one() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}             [模块 4] 一键部署流水线               ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo "1. 系统升级（不可逆）"
    echo "2. 网络调优（有原始配置备份）"
    echo "3. VLESS + Reality（失败恢复配置）"
    echo "防火墙：仅在已有活动防火墙时自动添加端口规则；不会强制开启新的防火墙。"
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    read -rp "确认执行？[Y/n]: " answer
    [[ "$answer" =~ ^[Nn]$ ]] && return 0

    if ! run_step_system_upgrade; then
        echo -e "${RED}[停止]${PLAIN} 系统升级失败，流水线不再继续。"
        return 1
    fi
    if ! run_step_network_tune; then
        echo -e "${RED}[停止]${PLAIN} 网络调优失败，流水线不再继续。"
        return 1
    fi
    if ! run_step_deploy_reality; then
        echo -e "${RED}[停止]${PLAIN} 协议部署失败，流水线不再继续。"
        return 1
    fi

    log_action "[流水线] 3 个阶段全部执行完成"
    echo -e "${GREEN}${BOLD}[完成]${PLAIN} 一键部署流水线执行完成。"
    [[ -f "$NODE_INFO_FILE" ]] && cat "$NODE_INFO_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_all_in_one
fi
