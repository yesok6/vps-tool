#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

log_action() {
    mkdir -p "${LOG_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_PRETTY="${PRETTY_NAME}"
    else
        echo -e "${RED}[错误]${PLAIN} 无法识别操作系统！"; exit 1
    fi

    ARCH=$(uname -m)
    case "${OS_ID}" in
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            export NEEDRESTART_MODE=a
            CMD_UPDATE="apt-get update -y"
            CMD_UPGRADE="apt-get dist-upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
            CMD_CLEAN="apt-get autoremove -y && apt-get clean"
            PKG_MANAGER="apt"
            SSH_SERVICE="ssh"
            ;;
        centos|rhel|almalinux|rocky)
            PKG_MANAGER="dnf"
            command -v dnf &>/dev/null || PKG_MANAGER="yum"
            CMD_UPDATE="${PKG_MANAGER} makecache"
            CMD_UPGRADE="${PKG_MANAGER} upgrade -y"
            CMD_CLEAN="${PKG_MANAGER} autoremove -y && ${PKG_MANAGER} clean all"
            SSH_SERVICE="sshd"
            ;;
        *)
            echo -e "${RED}[错误]${PLAIN} 暂不支持该系统: ${OS_PRETTY}"; exit 1
            ;;
    esac
}

get_current_ssh_port() {
    local port
    port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
    if [[ -z "$port" ]]; then
        port=$(grep -E "^[# ]*Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
    fi
    echo "${port:-22}"
}

confirm_safety_prompt() {
    local title="$1"
    local warning="$2"
    echo -e "${RED}${BOLD}==================== [ 风险操作警告 ] ====================${PLAIN}"
    echo -e "操作名称: ${YELLOW}${title}${PLAIN}"
    echo -e "警告说明: ${RED}${warning}${PLAIN}"
    echo -e "特性提示: ${YELLOW}[底层安全保留项 - 一键卸载时为防失联将保留此项]${PLAIN}"
    echo -e "${RED}${BOLD}==========================================================${PLAIN}"
    read -rp "您确定要继续执行此操作吗？输入 y 确认，其他键取消 [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}[提示]${PLAIN} 操作已取消。"; return 1; }
    return 0
}

sync_system_time() {
    echo -e "${BLUE}[同步中]${PLAIN} 正在自动校准系统时区与网络时间 (UTC)..."
    timedatectl set-timezone UTC 2>/dev/null
    if command -v chrony &>/dev/null; then
        systemctl restart chrony 2>/dev/null
    else
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt-get install -y chrony &>/dev/null && systemctl restart chrony 2>/dev/null
        else
            ${PKG_MANAGER} install -y chrony &>/dev/null && systemctl restart chrony 2>/dev/null
        fi
    fi
    log_action "[底层保留] 同步系统时间并设置时区为 UTC"
}

sys_full_upgrade() {
    echo -e "${BLUE}[信息]${PLAIN} 开始全自动系统更新..."
    sync_system_time
    $CMD_UPDATE && $CMD_UPGRADE && $CMD_CLEAN
    log_action "[不可逆] 全量更新系统软件包及依赖"
    echo -e "${GREEN}[成功]${PLAIN} 全系统基础软件包升级完成！"
}

sys_security_upgrade() {
    echo -e "${BLUE}[信息]${PLAIN} 开始自动修补安全高危漏洞..."
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get update -y
        if ! command -v unattended-upgrade &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
        fi
        unattended-upgrade -d
    else
        ${PKG_MANAGER} update --security -y
    fi
    log_action "[不可逆] 修补系统 CVE 安全高危补丁"
    echo -e "${GREEN}[成功]${PLAIN} 安全补丁修补完毕！"
}

change_ssh_port() {
    local cur_port
    cur_port=$(get_current_ssh_port)
    confirm_safety_prompt "修改 SSH 端口" "修改后未在云平台安全组放行新端口，将导致 SSH 断开且无法连入！" || return

    echo -e "当前 SSH 端口为: ${GREEN}${cur_port}${PLAIN}"
    read -rp "请输入新端口号 [1024-65535]: " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}[错误]${PLAIN} 端口必须在 1024-65535 之间！"; return
    fi

    if ss -tln | grep -q ":${new_port} "; then
        echo -e "${RED}[错误]${PLAIN} 端口 ${new_port} 已被占用！"; return
    fi

    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "${new_port}/tcp" comment "SSH Port"
    fi

    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%T)"

    if grep -qE "^[# ]*Port " /etc/ssh/sshd_config; then
        sed -i -E "s/^[# ]*Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    else
        echo "Port ${new_port}" >> /etc/ssh/sshd_config
    fi

    if systemctl is-active ssh.socket &>/dev/null; then
        systemctl stop ssh.socket
        systemctl disable ssh.socket
        systemctl enable ssh
    fi

    systemctl restart "${SSH_SERVICE}"
    if systemctl is-active "${SSH_SERVICE}" &>/dev/null; then
        log_action "[安全保留] SSH 端口修改为: ${new_port}"
        echo -e "${GREEN}[成功]${PLAIN} SSH 端口已改为 ${GREEN}${new_port}${PLAIN}！"
        echo -e "${RED}${BOLD}[警告] 切勿关闭当前窗口！请新开终端测试登录: ssh -p ${new_port} root@IP${PLAIN}"
    else
        echo -e "${RED}[错误]${PLAIN} 重启失败，已为您自动回滚！"
        mv "/etc/ssh/sshd_config.bak."* /etc/ssh/sshd_config
        systemctl restart "${SSH_SERVICE}"
    fi
}

setup_ufw_firewall() {
    local cur_port
    cur_port=$(get_current_ssh_port)
    confirm_safety_prompt "开启 UFW 防火墙" "防火墙将默认拦截所有入站流量，请确保当前 SSH 端口放行。" || return

    if ! command -v ufw &>/dev/null; then
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt-get update -y && apt-get install -y ufw
        else
            ${PKG_MANAGER} install -y epel-release && ${PKG_MANAGER} install -y ufw
        fi
    fi

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${cur_port}/tcp" comment "SSH Port"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    echo "y" | ufw enable
    log_action "[安全保留] 开启 UFW 防火墙并放行当前 SSH 端口 (${cur_port})"
    echo -e "${GREEN}[成功]${PLAIN} UFW 防火墙已成功激活并放行核心端口！"
}

setup_ssh_key_auth() {
    confirm_safety_prompt "配置密钥登录并禁用密码" "将彻底关闭密码登录！若公钥错误或无私钥，将永久丢失 root 权限！" || return

    echo ""
    read -rp "请在此处粘贴公钥内容 (Public Key): " user_key
    if [[ ! "$user_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
        echo -e "${RED}[错误]${PLAIN} 公钥格式不合规！"; return
    fi

    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    echo "$user_key" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%T)"
    sed -i -E "s/^[# ]*PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

    read -rp "是否立即彻底禁用密码登录？[y/N]: " disable_pwd
    if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
        sed -i -E "s/^[# ]*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
        grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        sed -i -E "s/^[# ]*KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/" /etc/ssh/sshd_config
        echo -e "${YELLOW}[策略]${PLAIN} 密码登录已被禁用。"
        log_action "[安全保留] 部署 SSH 密钥认证并【禁用】密码登录"
    else
        log_action "[安全保留] 部署 SSH 密钥认证（保留密码登录）"
    fi

    systemctl restart "${SSH_SERVICE}"
    echo -e "${GREEN}[成功]${PLAIN} 密钥已部署！请务必新开窗口测试确认可用！"
}

security_menu() {
    check_os
    while true; do
        clear
        local cur_port
        cur_port=$(get_current_ssh_port)
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}            [模块 1] 网络安全与系统加固            ${PLAIN}"
        echo -e "  系统: ${GREEN}${OS_PRETTY} (${ARCH})${PLAIN} | 当前 SSH 端口: ${GREEN}${cur_port}${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 一键全量升级系统软件与时间同步 ${YELLOW}[不可逆更新]${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 一键高危安全漏洞修补升级       ${YELLOW}[不可逆更新]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${YELLOW}3.${PLAIN} 修改 SSH 远程连接端口           ${YELLOW}[安全保留项]${PLAIN}"
        echo -e "  ${YELLOW}4.${PLAIN} 开启 UFW 防火墙基线防御         ${YELLOW}[安全保留项]${PLAIN}"
        echo -e "  ${YELLOW}5.${PLAIN} 部署密钥认证并关闭密码         ${YELLOW}[安全保留项]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${RED}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-5]: " choice
        case "$choice" in
            1) sys_full_upgrade; read -rp "按回车继续..." ;;
            2) sys_security_upgrade; read -rp "按回车继续..." ;;
            3) change_ssh_port; read -rp "按回车继续..." ;;
            4) setup_ufw_firewall; read -rp "按回车继续..." ;;
            5) setup_ssh_key_auth; read -rp "按回车继续..." ;;
            0) break ;;
        esac
    done
}
security_menu
