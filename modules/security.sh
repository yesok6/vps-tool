#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================================
# 系统安全与 SSH 防失联配置
# ========================================================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"

get_current_ssh_port() {
    local port=""
    if command_exists sshd; then
        port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
    fi
    if [[ -z "$port" ]]; then
        port=$(ss -H -ltnp 2>/dev/null | awk '/sshd|ssh/ {n=split($4,a,":"); print a[n]; exit}' || true)
    fi
    echo "${port:-22}"
}

ssh_port_listening() {
    local port="$1"
    ss -H -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit found ? 0 : 1}'
}

active_ssh_socket() {
    local unit
    for unit in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            echo "$unit"
            return 0
        fi
    done
    return 1
}

backup_current_ssh_files() {
    local action_dir="$1"
    mkdir -p "$action_dir"
    cp -a "$SSHD_CONFIG" "${action_dir}/sshd_config"
    if [[ -f /root/.ssh/authorized_keys ]]; then
        mkdir -p "${action_dir}/ssh"
        cp -a /root/.ssh/authorized_keys "${action_dir}/authorized_keys"
        printf 'present\n' > "${action_dir}/authorized_keys.state"
    else
        printf 'missing\n' > "${action_dir}/authorized_keys.state"
    fi
}

restore_action_ssh_files() {
    local action_dir="$1"
    [[ -f "${action_dir}/sshd_config" ]] && cp -a "${action_dir}/sshd_config" "$SSHD_CONFIG"
    if [[ "$(cat "${action_dir}/authorized_keys.state" 2>/dev/null || true)" == "present" ]]; then
        mkdir -p /root/.ssh
        cp -a "${action_dir}/authorized_keys" /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    else
        rm -f /root/.ssh/authorized_keys
    fi
}

validate_sshd_config() {
    command_exists sshd || { echo -e "${RED}[错误]${PLAIN} 未找到 sshd。"; return 1; }
    sshd -t -f "$SSHD_CONFIG"
}

set_sshd_option_global() {
    local key="$1" value="$2" tmp out
    tmp=$(mktemp) || return 1
    out="${tmp}.out"

    if ! awk -v key="$key" '
        BEGIN { in_match=0 }
        /^[[:space:]]*Match([[:space:]]|$)/ { in_match=1 }
        !in_match && $1 == key { next }
        { print }
    ' "$SSHD_CONFIG" > "$tmp"; then
        rm -f "$tmp" "$out"
        return 1
    fi

    if ! {
        printf '%s\n' '# Managed by VPS-Tool' "${key} ${value}"
        cat "$tmp"
    } > "$out"; then
        rm -f "$tmp" "$out"
        return 1
    fi

    if ! chmod 600 "$out"; then
        rm -f "$tmp" "$out"
        return 1
    fi
    if ! cat "$out" > "$SSHD_CONFIG"; then
        rm -f "$tmp" "$out"
        return 1
    fi

    rm -f "$tmp" "$out"
    return 0
}

restart_or_reload_ssh() {
    if systemctl reload "${SSH_SERVICE}" >/dev/null 2>&1; then
        return 0
    fi
    systemctl restart "${SSH_SERVICE}"
}

change_ssh_port() {
    local cur_port new_port action_dir socket_unit
    check_os || return
    cur_port=$(get_current_ssh_port)

    if socket_unit=$(active_ssh_socket 2>/dev/null); then
        echo -e "${RED}[停止]${PLAIN} 检测到 ${socket_unit} 正在使用 socket activation。"
        echo -e "${YELLOW}为避免切换 socket 时导致失联，本工具不会自动改动这种模式。${PLAIN}"
        echo -e "请先在云控制台确认访问方式，再手工停用 socket 后重新执行。"
        return 1
    fi

    confirm_safety_prompt "修改 SSH 端口" "必须同时修改云平台安全组/防火墙；旧端口不会由本工具主动删除。" || return 1
    read -rp "当前 SSH 端口 ${cur_port}，请输入新端口 [1024-65535]: " new_port
    validate_port "$new_port" || { echo -e "${RED}[错误]${PLAIN} 端口必须在 1024-65535。"; return 1; }
    [[ "$new_port" != "$cur_port" ]] || { echo -e "${YELLOW}[提示]${PLAIN} 新旧端口相同。"; return 0; }
    if port_in_use "$new_port" tcp; then
        echo -e "${RED}[错误]${PLAIN} 端口 ${new_port} 已被占用。"
        return 1
    fi

    action_dir=$(make_temp_dir ssh-change)
    if ! backup_current_ssh_files "$action_dir"; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法备份当前 SSH 配置，操作已取消。"
        return 1
    fi
    if ! backup_file_once "$SSHD_CONFIG" ssh_sshd_config; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法保存 SSH 配置备份，操作已取消。"
        return 1
    fi

    if ! set_sshd_option_global Port "$new_port"; then
        restore_action_ssh_files "$action_dir" || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法写入 SSH 端口配置，已恢复。"
        return 1
    fi
    if ! validate_sshd_config; then
        restore_action_ssh_files "$action_dir"
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} sshd 配置检查失败，已恢复。"
        return 1
    fi

    firewall_allow "$new_port" tcp || true
    if ! restart_or_reload_ssh; then
        restore_action_ssh_files "$action_dir"
        restart_or_reload_ssh >/dev/null 2>&1 || true
        firewall_remove_owned_rules "$new_port" tcp || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} SSH 服务重载/重启失败，已恢复原配置。"
        return 1
    fi

    if ! ssh_port_listening "$new_port"; then
        restore_action_ssh_files "$action_dir"
        restart_or_reload_ssh >/dev/null 2>&1 || true
        firewall_remove_owned_rules "$new_port" tcp || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 新端口未监听，已恢复原配置。"
        return 1
    fi

    log_action "[安全保留] SSH 端口由 ${cur_port} 修改为 ${new_port}；原始配置已备份。"
    echo -e "${GREEN}[成功]${PLAIN} SSH 已监听新端口 ${new_port}。"
    echo -e "${YELLOW}[重要]${PLAIN} 请新开一个终端实际测试新端口登录，确认成功后再断开当前连接。"
    echo -e "${YELLOW}[提示]${PLAIN} 旧端口不会自动删除，以避免在云安全组未同步时把自己锁在外面。"
    rm -rf "$action_dir"
}

setup_firewall() {
    check_os || return
    local cur_port backend answer
    cur_port=$(get_current_ssh_port)
    backend=$(firewall_backend)

    if [[ "$backend" == "ufw" ]]; then
        ufw allow "${cur_port}/tcp" >/dev/null
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null
        read -rp "UFW 当前已安装。立即启用？[y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            ufw --force enable
        fi
        log_action "[安全保留] 配置 UFW，SSH=${cur_port}, 80/tcp, 443/tcp"
        echo -e "${GREEN}[完成]${PLAIN} UFW 规则已准备。"
        return 0
    fi

    if [[ "$backend" == "firewalld" ]]; then
        firewall-cmd --permanent --add-port="${cur_port}/tcp" >/dev/null
        firewall-cmd --permanent --add-service=http >/dev/null
        firewall-cmd --permanent --add-service=https >/dev/null
        firewall-cmd --reload >/dev/null
        log_action "[安全保留] 配置 firewalld，SSH=${cur_port}, HTTP/HTTPS"
        echo -e "${GREEN}[完成]${PLAIN} firewalld 规则已准备。"
        return 0
    fi

    echo -e "${YELLOW}[提示]${PLAIN} 当前没有已启用的 UFW/firewalld。"
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        echo "如需启用 UFW，请先确认云平台安全组允许当前 SSH 端口。"
        read -rp "是否安装并配置 UFW（随后由你确认是否启用）？[y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y ufw
            ufw allow "${cur_port}/tcp" >/dev/null
            ufw allow 80/tcp >/dev/null
            ufw allow 443/tcp >/dev/null
            ufw default deny incoming >/dev/null
            ufw default allow outgoing >/dev/null
            read -rp "规则已配置，是否现在启用 UFW？[y/N]: " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then ufw --force enable; fi
        fi
    else
        echo -e "${YELLOW}[提示]${PLAIN} 本工具不会在 RHEL 系系统上强制安装/启用新的防火墙，以避免无云控制台时锁死 SSH。"
    fi
}

setup_ssh_key_auth() {
    local user_key disable_pwd action_dir
    confirm_safety_prompt "配置 root 公钥登录" "若同时关闭密码登录，必须先确认新公钥可用；请保留当前 SSH 会话直到新会话验证成功。" || return 1
    command_exists sshd || { echo -e "${RED}[错误]${PLAIN} 未找到 sshd。"; return 1; }
    command_exists ssh-keygen || { echo -e "${RED}[错误]${PLAIN} 未找到 ssh-keygen。"; return 1; }

    read -rp "请粘贴一整行 SSH 公钥：" user_key
    [[ "$user_key" != *$'\n'* && "$user_key" != *$'\r'* ]] || { echo -e "${RED}[错误]${PLAIN} 公钥必须是一整行。"; return 1; }
    local key_tmp
    key_tmp=$(mktemp)
    printf '%s\n' "$user_key" > "$key_tmp"
    if ! ssh-keygen -lf "$key_tmp" >/dev/null 2>&1; then
        rm -f "$key_tmp"
        echo -e "${RED}[错误]${PLAIN} 公钥格式无效。"
        return 1
    fi
    rm -f "$key_tmp"

    action_dir=$(make_temp_dir ssh-key)
    if ! backup_current_ssh_files "$action_dir"; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法备份当前 SSH 配置，操作已取消。"
        return 1
    fi
    if ! backup_file_once "$SSHD_CONFIG" ssh_sshd_config; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法保存 SSH 配置备份，操作已取消。"
        return 1
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh /root/.ssh/authorized_keys
    grep -Fqx -- "$user_key" /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$user_key" >> /root/.ssh/authorized_keys

    if ! set_sshd_option_global PubkeyAuthentication yes || ! set_sshd_option_global PermitRootLogin prohibit-password; then
        restore_action_ssh_files "$action_dir" || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法写入 SSH 公钥认证配置，已恢复。"
        return 1
    fi

    read -rp "是否关闭 root 密码登录？[y/N]: " disable_pwd
    if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
        if ! set_sshd_option_global PasswordAuthentication no || ! set_sshd_option_global KbdInteractiveAuthentication no || ! set_sshd_option_global ChallengeResponseAuthentication no; then
            restore_action_ssh_files "$action_dir" || true
            rm -rf "$action_dir"
            echo -e "${RED}[错误]${PLAIN} 无法写入密码登录关闭配置，已恢复。"
            return 1
        fi
    fi

    if ! validate_sshd_config; then
        restore_action_ssh_files "$action_dir"
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} sshd 配置检查失败，已自动恢复。"
        return 1
    fi

    local effective
    effective=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1,laddr=127.0.0.1 2>/dev/null)
    grep -qx 'pubkeyauthentication yes' <<< "$effective" || { restore_action_ssh_files "$action_dir"; rm -rf "$action_dir"; return 1; }
    grep -qx 'permitrootlogin prohibit-password' <<< "$effective" || { restore_action_ssh_files "$action_dir"; rm -rf "$action_dir"; return 1; }
    if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
        grep -qx 'passwordauthentication no' <<< "$effective" || { restore_action_ssh_files "$action_dir"; rm -rf "$action_dir"; return 1; }
        grep -qx 'kbdinteractiveauthentication no' <<< "$effective" || { restore_action_ssh_files "$action_dir"; rm -rf "$action_dir"; return 1; }
    fi

    if ! restart_or_reload_ssh; then
        restore_action_ssh_files "$action_dir"
        restart_or_reload_ssh >/dev/null 2>&1 || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} SSH 重载/重启失败，已恢复。"
        return 1
    fi
    if ! systemctl is-active --quiet "$SSH_SERVICE"; then
        restore_action_ssh_files "$action_dir"
        restart_or_reload_ssh >/dev/null 2>&1 || true
        rm -rf "$action_dir"
        return 1
    fi

    log_action "[安全保留] 已配置 root 公钥认证，密码登录=$([[ "$disable_pwd" =~ ^[Yy]$ ]] && echo disabled || echo enabled)"
    echo -e "${GREEN}[成功]${PLAIN} SSH 公钥认证配置已生效。"
    echo -e "${YELLOW}[重要]${PLAIN} 请新开终端用该私钥登录成功后，再关闭当前会话。"
    rm -rf "$action_dir"
}

security_menu() {
    check_os || return 1
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
        echo -e "  ${YELLOW}3.${PLAIN} 修改 SSH 远程连接端口           ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ${YELLOW}4.${PLAIN} 开启 UFW 防火墙基线防御         ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ${YELLOW}5.${PLAIN} 部署密钥认证并关闭密码         ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${RED}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-5]: " choice
        case "$choice" in
            1) sys_full_upgrade; read -rp "按回车继续..." ;;
            2) sys_security_upgrade; read -rp "按回车继续..." ;;
            3) change_ssh_port; read -rp "按回车继续..." ;;
            4) setup_firewall; read -rp "按回车继续..." ;;
            5) setup_ssh_key_auth; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    security_menu
fi
