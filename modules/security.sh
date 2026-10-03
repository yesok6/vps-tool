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
    # [安全真相源] 优先读取 sshd 实际生效端口；探测失败时绝不猜测默认 22。
    # [安全保护] 探测失败必须由调用方明确处理，避免启用防火墙时把错误的 22 当成 SSH 入口。
    local port=""
    if command_exists sshd; then
        port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
    fi
    if validate_ssh_port "${port:-}"; then
        printf '%s\n' "$port"
        return 0
    fi

    port=$(ss -H -ltnp 2>/dev/null | awk '/sshd|ssh/ {n=split($4,a,":"); print a[n]; exit}' || true)
    if validate_ssh_port "${port:-}"; then
        printf '%s\n' "$port"
        return 0
    fi

    echo -e "${RED}[错误]${PLAIN} 无法可靠探测当前 SSH 端口，请先检查 sshd 配置与监听状态。" >&2
    return 1
}

get_current_ssh_ports() {
    # [安全真相源] 以 sshd 当前实际生效配置为准。
    # [迁移状态] SSH 迁移期间 sshd 同时监听旧/新端口，因此这里会自然返回两个端口。
    # [安全保留] 本函数只读取状态，不修改 SSH、防火墙或 Fail2Ban。
    local output port count=0
    if command_exists sshd && output=$(sshd -T 2>/dev/null); then
        while read -r port; do
            if validate_ssh_port "$port"; then
                printf '%s\n' "$port"
                count=$((count + 1))
            fi
        done < <(awk '$1 == "port" {print $2}' <<< "$output" | sort -n -u)
        (( count > 0 )) && return 0
        return 1
    fi

    if ! port=$(get_current_ssh_port 2>/dev/null); then
        return 1
    fi
    validate_ssh_port "$port" && printf '%s\n' "$port"
}

ssh_port_listening() {
    local port="$1"
    ss -H -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit found ? 0 : 1}'
}

validate_ssh_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
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

    # [修复 Bug] 更新 awk 正则，支持无空格写法的 PasswordAuthentication=yes 的成功捕获与清除
    if ! awk -v key="$key" '
        BEGIN { in_match=0 }
        /^[[:space:]]*Match([[:space:]]|$)/ { in_match=1 }
        !in_match && $0 ~ "^[[:space:]]*" key "(=|[[:space:]]|$)" { next }
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

current_ssh_session_port() {
    # [修复 Bug] 彻底解决 tmux/screen/sudo su 等环境丢失 SSH_CONNECTION 导致的迁移死锁
    local remote_ip remote_port local_ip local_port
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r remote_ip remote_port local_ip local_port _ <<< "${SSH_CONNECTION}"
        if [[ "$local_port" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$local_port"
            return 0
        fi
    fi
    # 回退方案：向上追溯进程树寻找 sshd，然后读取其真实端口
    local ppid=$$ sshd_pid=""
    while [[ $ppid -gt 1 ]]; do
        local comm
        comm=$(ps -p $ppid -o comm= 2>/dev/null || true)
        if [[ "$comm" == *"sshd"* ]]; then
            sshd_pid=$ppid
            break
        fi
        ppid=$(ps -p $ppid -o ppid= 2>/dev/null | tr -d ' ' || echo 0)
    done
    if [[ -n "$sshd_pid" ]]; then
        local_port=$(ss -Htnp 2>/dev/null | awk -v pid="pid=${sshd_pid}," '$0 ~ pid {split($4, a, ":"); print a[length(a)]; exit}')
        if [[ "$local_port" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$local_port"
            return 0
        fi
    fi
    return 1
}

current_ssh_session_uses_port() {
    local expected="$1"
    local current_port
    current_port=$(current_ssh_session_port 2>/dev/null || true)
    if [[ -z "$current_port" ]]; then
        # 极度异常环境，给调用方留后门判断
        return 2
    fi
    [[ "$current_port" == "$expected" ]]
}

ssh_current_source_ip() {
    local remote_ip
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r remote_ip _ _ _ _ <<< "${SSH_CONNECTION}"
        if [[ -n "$remote_ip" ]]; then
            printf '%s\n' "$remote_ip"
            return 0
        fi
    fi
    local ppid=$$ sshd_pid=""
    while [[ $ppid -gt 1 ]]; do
        local comm
        comm=$(ps -p $ppid -o comm= 2>/dev/null || true)
        if [[ "$comm" == *"sshd"* ]]; then sshd_pid=$ppid; break; fi
        ppid=$(ps -p $ppid -o ppid= 2>/dev/null | tr -d ' ' || echo 0)
    done
    if [[ -n "$sshd_pid" ]]; then
        remote_ip=$(ss -Htnp 2>/dev/null | awk -v pid="pid=${sshd_pid}," '$0 ~ pid {split($5, a, ":"); print a[1]; exit}')
        if [[ -n "$remote_ip" ]]; then
            printf '%s\n' "$remote_ip"
            return 0
        fi
    fi
    return 1
}

ssh_endpoint_port() {
    local endpoint="$1"
    if [[ "$endpoint" =~ :([0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

ssh_endpoint_host() {
    local endpoint="$1"
    # IPv6 推荐使用 [addr]:port；对 ss 极端输出的未加方括号 IPv6，仍按“最后一个冒号后的数字”为端口处理。
    if [[ "$endpoint" =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$endpoint" =~ ^(.+):[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

ssh_new_session_detected() {
    local expected_port="$1"
    local remote_ip current_session_local_port
    local local_endpoint peer_endpoint local_port_now peer_host peer_port

    remote_ip=$(ssh_current_source_ip 2>/dev/null) || return 1
    [[ -n "$remote_ip" ]] || return 1
    current_session_local_port=$(current_ssh_session_port 2>/dev/null) || return 1

    while read -r _ _ _ local_endpoint peer_endpoint; do
        [[ -n "$local_endpoint" && -n "$peer_endpoint" ]] || continue
        local_port_now=$(ssh_endpoint_port "$local_endpoint" 2>/dev/null || true)
        peer_host=$(ssh_endpoint_host "$peer_endpoint" 2>/dev/null || true)
        peer_port=$(ssh_endpoint_port "$peer_endpoint" 2>/dev/null || true)
        [[ "$local_port_now" == "$expected_port" ]] || continue
        [[ "$peer_host" == "$remote_ip" ]] || continue

        # 通过“来源 IP + 本机端口”精确排除当前工具会话，避免把自己误判成“新会话”。
        if [[ "$peer_host" == "$remote_ip" && "$local_port_now" == "$current_session_local_port" ]]; then
            continue
        fi
        return 0
    done < <(ss -Htn state established 2>/dev/null || true)

    return 1
}

set_sshd_ports_global() {
    local old_port="$1" new_port="$2"
    local tmp out existing_port
    local -a existing_ports=()
    tmp=$(mktemp) || return 1
    out="${tmp}.out"

    mapfile -t existing_ports < <(
        awk '
            BEGIN { in_match=0 }
            /^[[:space:]]*Match([[:space:]]|$)/ { in_match=1 }
            !in_match && $0 !~ /^[[:space:]]*#/ && $1 ~ /^Port(=|[[:space:]]|$)/ {
                value=$0
                sub(/^[[:space:]]*Port/, "", value)
                sub(/^[[:space:]]*=[[:space:]]*/, "", value)
                sub(/^[[:space:]]+/, "", value)
                if (value != "") print value
            }
        ' "$SSHD_CONFIG"
    )

    if ! awk '
        BEGIN { in_match=0 }
        /^[[:space:]]*Match([[:space:]]|$)/ { in_match=1 }
        !in_match && $0 !~ /^[[:space:]]*#/ && $1 ~ /^Port(=|[[:space:]]|$)/ { next }
        { print }
    ' "$SSHD_CONFIG" > "$tmp"; then
        rm -f "$tmp" "$out"
        return 1
    fi

    {
        printf '%s\n' '# Managed by VPS-Tool' "Port ${old_port}" "Port ${new_port}"
        for existing_port in "${existing_ports[@]}"; do
            [[ "$existing_port" == "$old_port" || "$existing_port" == "$new_port" ]] && continue
            printf 'Port %s\n' "$existing_port"
        done
        cat "$tmp"
    } > "$out" || { rm -f "$tmp" "$out"; return 1; }

    chmod 600 "$out" || { rm -f "$tmp" "$out"; return 1; }
    cat "$out" > "$SSHD_CONFIG" || { rm -f "$tmp" "$out"; return 1; }
    rm -f "$tmp" "$out"
}

remove_sshd_port_global() {
    local remove_port="$1"
    local tmp
    tmp=$(mktemp) || return 1
    if ! awk -v remove_port="$remove_port" '
        BEGIN { in_match=0 }
        /^[[:space:]]*Match([[:space:]]|$)/ { in_match=1 }
        !in_match && $0 !~ /^[[:space:]]*#/ && $1 ~ /^Port(=|[[:space:]]|$)/ {
            value=$0
            sub(/^[[:space:]]*Port/, "", value)
            sub(/^[[:space:]]*=[[:space:]]*/, "", value)
            sub(/^[[:space:]]+/, "", value)
            if (value == remove_port) next
        }
        { print }
    ' "$SSHD_CONFIG" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if ! cat "$tmp" > "$SSHD_CONFIG"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

sshd_has_port() {
    local port="$1" output
    if ! output=$(sshd -T 2>&1); then
        echo -e "${RED}[错误]${PLAIN} sshd 无法展开当前配置，无法可靠判断 SSH 端口 ${port} 的状态。"
        echo -e "${YELLOW}[提示]${PLAIN} 请先检查 sshd 配置语法，再进行端口迁移。"
        return 1
    fi
    awk -v p="$port" '$1 == "port" && $2 == p {found=1} END {exit found ? 0 : 1}' <<< "$output"
}

remove_old_ssh_port() {
    local old_port new_port action_dir backend use_rc
    old_port="${1:-$(state_get ssh_migration_old_port 2>/dev/null || true)}"
    new_port="${2:-$(state_get ssh_migration_new_port 2>/dev/null || true)}"

    validate_ssh_port "$old_port" || { echo -e "${RED}[错误]${PLAIN} 未找到有效的旧 SSH 端口记录。"; return 1; }
    validate_ssh_port "$new_port" || { echo -e "${RED}[错误]${PLAIN} 未找到有效的新 SSH 端口记录。"; return 1; }
    [[ "$old_port" != "$new_port" ]] || { echo -e "${RED}[错误]${PLAIN} 新旧 SSH 端口不能相同。"; return 1; }

    current_ssh_session_uses_port "$new_port"
    use_rc=$?
    if (( use_rc == 1 )); then
        echo -e "${RED}[禁止删除]${PLAIN} 当前这次 SSH 会话是通过旧端口或其它端口登录的，未通过新端口 ${new_port} 登录。"
        echo -e "${YELLOW}[安全条件]${PLAIN} 必须先用新端口建立一个全新的 SSH 会话，再从那个新会话进入此工具删除旧端口。"
        return 1
    elif (( use_rc == 2 )); then
        echo -e "${YELLOW}[警告]${PLAIN} 无法可靠探测当前会话的本地登录端口（可能处于特殊容器或极简终端环境）。"
        confirm_safety_prompt "盲目删除旧 SSH 端口" "工具无法确定你是否已用新端口 ${new_port} 成功登入；如果尚未登入，此操作将导致服务器失联！" || return 1
    fi

    if ! sshd_has_port "$old_port" || ! sshd_has_port "$new_port"; then
        echo -e "${RED}[禁止删除]${PLAIN} 当前 sshd 配置未同时检测到旧端口 ${old_port} 和新端口 ${new_port}。"
        return 1
    fi
    if ! ssh_port_listening "$old_port" || ! ssh_port_listening "$new_port"; then
        echo -e "${RED}[禁止删除]${PLAIN} 当前系统未同时监听旧端口 ${old_port} 和新端口 ${new_port}。"
        return 1
    fi

    echo -e "${RED}${BOLD}[高风险操作]${PLAIN} 即将删除旧 SSH 端口 ${old_port}。"
    echo -e "${YELLOW}[警告]${PLAIN} 删除后 SSH 将不再监听 ${old_port}；当前会话已确认通过新端口 ${new_port} 登录。"
    echo -e "${YELLOW}[警告]${PLAIN} 请再次确认云安全组/外部防火墙已经允许新端口 ${new_port}。"
    confirm_safety_prompt "删除旧 SSH 端口 ${old_port}" "作用：只保留新端口 ${new_port}；成功后会同步关闭可安全识别的旧端口防火墙放行。" || return 1

    action_dir=$(make_temp_dir ssh-remove-old)
    if ! backup_current_ssh_files "$action_dir"; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法备份当前 SSH 配置，删除操作已取消。"
        return 1
    fi

    if ! remove_sshd_port_global "$old_port" || ! validate_sshd_config; then
        restore_action_ssh_files "$action_dir" || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 删除旧端口后的 sshd 配置检查失败，已恢复。"
        return 1
    fi

    if ! restart_or_reload_ssh; then
        restore_action_ssh_files "$action_dir" || true
        restart_or_reload_ssh >/dev/null 2>&1 || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} SSH 重载/重启失败，已恢复。"
        return 1
    fi

    if ssh_port_listening "$old_port" || ! ssh_port_listening "$new_port"; then
        restore_action_ssh_files "$action_dir" || true
        restart_or_reload_ssh >/dev/null 2>&1 || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 删除旧端口后的监听状态异常，已恢复。"
        return 1
    fi

    if [[ "$(firewall_backend)" == "ufw" || "$(firewall_backend)" == "firewalld" ]]; then
        backend=$(firewall_backend)
        if ! firewall_rule_exists "$backend" "$new_port" tcp; then
            state_set ssh_migration_firewall_cleanup_pending "$old_port"
            echo -e "${YELLOW}[安全保留]${PLAIN} 新 SSH 端口 ${new_port}/tcp 当前未被本机防火墙确认放行，旧端口 ${old_port}/tcp 不会关闭。请先放行新端口后再清理旧规则。"
        elif firewall_port_has_service_rule "$backend" "$old_port" tcp; then
            state_set ssh_migration_firewall_cleanup_pending "$old_port"
            echo -e "${YELLOW}[安全保留]${PLAIN} 旧端口 ${old_port}/tcp 由防火墙 service/profile 管理，不会强制删除；请手动调整该 service。"
        elif firewall_remove_owned_rules "$old_port" tcp; then
            state_unset ssh_migration_firewall_cleanup_pending
            echo -e "${GREEN}[完成]${PLAIN} SSH 旧端口 ${old_port} 已删除，对应的工具防火墙放行也已关闭。"
        elif ! port_in_use "$old_port" tcp && firewall_close_port_rule "$old_port" tcp; then
            state_unset ssh_migration_firewall_cleanup_pending
            echo -e "${GREEN}[完成]${PLAIN} SSH 旧端口 ${old_port} 已删除，检测到旧端口无本机监听后，现有明确的端口放行规则也已关闭。"
        else
            state_set ssh_migration_firewall_cleanup_pending "$old_port"
            echo -e "${YELLOW}[提示]${PLAIN} SSH 已停止监听旧端口 ${old_port}，但防火墙规则未能安全自动关闭（可能由其它规则管理）。可在“查看/管理已放行端口”中手动处理。"
        fi
    fi

    if command_exists fail2ban-client && [[ -f "$FAIL2BAN_CONFIG" ]] && is_owned "$FAIL2BAN_CONFIG"; then
        if ! fail2ban_sync_ssh_protection; then
            echo -e "${YELLOW}[提示]${PLAIN} 旧 SSH 端口已删除，但 Fail2Ban 尚未完成端口同步；后续进入模块 1 会自动重试。"
        fi
    fi

    state_unset ssh_migration_old_port
    state_unset ssh_migration_new_port
    rm -rf "${VPS_TOOL_BACKUPS}/ssh_migration_sshd_config"
    log_action "[安全保留] SSH 旧端口 ${old_port} 已在确认当前会话通过新端口 ${new_port} 登录后完成删除。"
    rm -rf "$action_dir"
    echo -e "${GREEN}[成功]${PLAIN} 旧 SSH 端口 ${old_port} 已删除，新端口 ${new_port} 仍在监听。"
}

change_ssh_port() {
    local cur_port new_port action_dir socket_unit
    check_os || return 1
    if ! cur_port=$(get_current_ssh_port 2>/dev/null); then
        echo -e "${RED}[错误]${PLAIN} 无法确定当前 SSH 端口，已停止端口迁移。"
        return 1
    fi

    if socket_unit=$(active_ssh_socket 2>/dev/null); then
        echo -e "${RED}[停止]${PLAIN} 检测到 ${socket_unit} 正在使用 socket activation。"
        echo -e "${YELLOW}为避免切换 socket 时导致失联，本工具不会自动改动这种模式。${PLAIN}"
        echo -e "请先在云控制台确认访问方式，再手工停用 socket 后重新执行。"
        return 1
    fi

    if state_exists ssh_migration_old_port; then
        echo -e "${YELLOW}[提示]${PLAIN} 已存在待处理的 SSH 端口迁移：旧端口 $(state_get ssh_migration_old_port) → 新端口 $(state_get ssh_migration_new_port)。"
        echo -e "请先通过选项 2 或选项 3 处理当前迁移状态，再开始新的迁移。"
        return 1
    fi

    confirm_safety_prompt "修改 SSH 端口（保留旧端口）" "旧端口会与新端口同时保留；你必须新开终端通过新端口登录成功。之后再次进入本选项并选择 2，才会删除旧端口。" || return 1

    read -rp "当前 SSH 端口 ${cur_port}，请输入新端口 [1024-65535]: " new_port
    validate_port "$new_port" || { echo -e "${RED}[错误]${PLAIN} 端口必须在 1024-65535。"; return 1; }
    [[ "$new_port" != "$cur_port" ]] || { echo -e "${YELLOW}[提示]${PLAIN} 新旧端口相同。"; return 0; }
    if port_in_use "$new_port" tcp; then
        echo -e "${RED}[错误]${PLAIN} 端口 ${new_port} 已被占用。"
        return 1
    fi

    action_dir=$(make_temp_dir ssh-change)
    rm -rf "${VPS_TOOL_BACKUPS}/ssh_migration_sshd_config"
    if ! backup_current_ssh_files "$action_dir"; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法备份当前 SSH 配置，操作已取消。"
        return 1
    fi
    if ! backup_file_once "$SSHD_CONFIG" ssh_migration_sshd_config; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法保存本次 SSH 迁移的原始配置，操作已取消。"
        return 1
    fi

    if ! set_sshd_ports_global "$cur_port" "$new_port"; then
        restore_action_ssh_files "$action_dir" || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法写入 SSH 双端口配置，已恢复。"
        return 1
    fi
    if ! validate_sshd_config; then
        restore_action_ssh_files "$action_dir" || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} sshd 配置检查失败，已恢复。"
        return 1
    fi

    firewall_allow "$new_port" tcp || true
    if ! restart_or_reload_ssh; then
        restore_action_ssh_files "$action_dir" || true
        restart_or_reload_ssh >/dev/null 2>&1 || true
        firewall_remove_owned_rules "$new_port" tcp || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} SSH 服务重载/重启失败，已恢复原配置。"
        return 1
    fi

    if ! ssh_port_listening "$cur_port" || ! ssh_port_listening "$new_port"; then
        restore_action_ssh_files "$action_dir" || true
        restart_or_reload_ssh >/dev/null 2>&1 || true
        firewall_remove_owned_rules "$new_port" tcp || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 双端口监听状态不符合预期，已恢复原配置。"
        return 1
    fi

    if command_exists fail2ban-client && [[ -f "$FAIL2BAN_CONFIG" ]] && is_owned "$FAIL2BAN_CONFIG"; then
        if ! fail2ban_sync_ssh_protection; then
            echo -e "${YELLOW}[提示]${PLAIN} SSH 双端口已建立，但 Fail2Ban 尚未完成新旧端口同步；后续进入模块 1 会自动重试。"
        fi
    fi

    state_set ssh_migration_old_port "$cur_port"
    state_set ssh_migration_new_port "$new_port"
    log_action "[安全保留] SSH 端口由 ${cur_port} 切换为双端口 ${cur_port},${new_port}；等待新端口真实登录验证。"
    rm -rf "$action_dir"

    echo -e "${GREEN}[成功]${PLAIN} SSH 现在同时监听旧端口 ${cur_port} 和新端口 ${new_port}。"
    echo -e "${YELLOW}[重要警告]${PLAIN} 当前连接不要关闭；请新开一个终端，通过 ${new_port} 实际登录 VPS。"
    echo -e "${YELLOW}[必须操作]${PLAIN} 新端口登录成功后，再回到模块 1 → 3 → 选项 2 删除旧端口 ${cur_port}。"
    echo -e "${YELLOW}[安全说明]${PLAIN} 旧端口现在不会自动删除。"
}


cancel_ssh_port_migration() {
    local old_port new_port current_port backup_dir action_dir backend
    old_port="$(state_get ssh_migration_old_port 2>/dev/null || true)"
    new_port="$(state_get ssh_migration_new_port 2>/dev/null || true)"
    validate_ssh_port "$old_port" || { echo -e "${RED}[错误]${PLAIN} 未找到有效的迁移旧端口记录。"; return 1; }
    validate_ssh_port "$new_port" || { echo -e "${RED}[错误]${PLAIN} 未找到有效的迁移新端口记录。"; return 1; }
    backup_dir="${VPS_TOOL_BACKUPS}/ssh_migration_sshd_config"
    [[ -f "${backup_dir}/present" && ( -e "${backup_dir}/original" || -L "${backup_dir}/original" ) ]] || {
        echo -e "${RED}[错误]${PLAIN} 找不到本次迁移的原始 SSH 配置备份，无法安全回退。"
        echo -e "${YELLOW}[回退指引]${PLAIN} 请保留当前新旧双端口状态，不要手动删除旧端口，并保留云控制台/VNC 访问方式。"
        return 1
    }

    current_port=$(current_ssh_session_port 2>/dev/null || true)
    echo -e "${RED}${BOLD}[放弃迁移]${PLAIN} 将把 SSH 恢复到原来的单端口 ${old_port}，并取消本次迁移 ${old_port} → ${new_port}。"
    echo -e "${YELLOW}[警告]${PLAIN} 新端口 ${new_port} 将停止监听。"
    if [[ "$current_port" == "$new_port" ]]; then
        echo -e "${RED}[特别警告]${PLAIN} 当前 SSH 会话正通过新端口 ${new_port} 连接。回退后当前会话很可能立即断开，请确保你能从旧端口 ${old_port} 重新连接。"
    elif [[ "$current_port" == "$old_port" ]]; then
        echo -e "${GREEN}[安全提示]${PLAIN} 当前 SSH 会话仍通过旧端口 ${old_port} 连接，可以安全回退。"
    else
        echo -e "${YELLOW}[提示]${PLAIN} 当前会话不是可识别的旧/新 SSH 端口，将要求你确认是否继续回退。"
    fi
    confirm_safety_prompt "放弃 SSH 端口迁移并恢复原端口" "回退会停止新端口 ${new_port}；如果当前会话来自新端口，当前连接可能会被立即断开。" || return 1

    action_dir=$(make_temp_dir ssh-cancel-migration)
    if ! backup_current_ssh_files "$action_dir"; then
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 无法创建回退前备份，未执行回退。"
        return 1
    fi
    if ! restore_file_backup "$SSHD_CONFIG" ssh_migration_sshd_config || ! validate_sshd_config; then
        restore_action_ssh_files "$action_dir" || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 原始 SSH 配置恢复失败，已尽量保持当前可用状态。"
        return 1
    fi
    if ! restart_or_reload_ssh; then
        restore_action_ssh_files "$action_dir" || true
        restart_or_reload_ssh >/dev/null 2>&1 || true
        rm -rf "$action_dir"
        echo -e "${RED}[错误]${PLAIN} 回退后的 SSH 重载/重启失败，已恢复回退前配置。"
        return 1
    fi

    if ! firewall_remove_owned_rules "$new_port" tcp; then
        rm -rf "$action_dir"
        echo -e "${YELLOW}[警告]${PLAIN} SSH 配置已经恢复为原端口 ${old_port}，但新端口 ${new_port}/tcp 的工具防火墙规则未能清理。"
        echo -e "${YELLOW}[状态保留]${PLAIN} 本次迁移 state 将保留，方便后续重试；请确认防火墙状态后再处理。"
        return 1
    fi
    backend=$(firewall_backend)
    if [[ "$backend" == "ufw" || "$backend" == "firewalld" ]]; then
        if ! firewall_allow "$old_port" tcp; then
            rm -rf "$action_dir"
            echo -e "${YELLOW}[警告]${PLAIN} SSH 配置已恢复原端口 ${old_port}，但无法确认旧端口防火墙放行。请立即检查防火墙状态。"
            echo -e "${YELLOW}[状态保留]${PLAIN} 本次迁移 state 将保留，以便继续处理。"
            return 1
        fi
    fi

    if command_exists fail2ban-client && [[ -f "$FAIL2BAN_CONFIG" ]] && is_owned "$FAIL2BAN_CONFIG"; then
        if ! fail2ban_sync_ssh_protection; then
            echo -e "${YELLOW}[提示]${PLAIN} SSH 已恢复，但 Fail2Ban 尚未完成端口同步；后续进入模块 1 会自动重试。"
        fi
    fi

    state_unset ssh_migration_old_port
    state_unset ssh_migration_new_port
    rm -rf "$action_dir" "$backup_dir"
    log_action "[安全保留] 已放弃 SSH 端口迁移，恢复原端口 ${old_port}。"
    echo -e "${GREEN}[成功]${PLAIN} SSH 端口迁移已取消，当前恢复为原端口 ${old_port}。"
    echo -e "${YELLOW}[提示]${PLAIN} 如需再次迁移，请重新进入模块 1 → 3。"
}

ssh_success_login_entries() {
    local journal_line journal_entries file_line login_count=0
    if command_exists journalctl; then
        journal_line=$(journalctl --no-pager -o short-iso \
            -u ssh.service -u sshd.service -n 5000 2>/dev/null || true)
        if [[ -n "$journal_line" ]]; then
            login_count=$(awk '$0 ~ /sshd[^:]*:.*Accepted (password|publickey|keyboard-interactive)/ {count++} END {print count+0}' <<< "$journal_line")
            if (( login_count >= 500 )); then
                echo -e "${YELLOW}[提示]${PLAIN} 最近 5000 条 SSH 日志中约有 ${login_count} 条成功登录记录，正在整理并合并重复 IP，可能需要一些时间..." >&2
            fi
            journal_entries=$(awk '$0 ~ /sshd[^:]*:.*Accepted (password|publickey|keyboard-interactive)/ {
                ip="";
                for (i=1; i<NF; i++) if ($i=="from") { ip=$(i+1); break }
                if (ip!="") print $1 "|" ip
            }' <<< "$journal_line")
            if [[ -n "$journal_entries" ]]; then
                printf '%s\n' "$journal_entries"
                return 0
            fi
        fi
    fi

    # [修复 Bug] 引入月份映射矩阵，把 Oct 3 转换为 YYYY-MM-DD 确保字符串正序排列，解决跨月排序乱套。
    for file_line in /var/log/auth.log /var/log/secure; do
        if [[ -f "$file_line" ]]; then
            awk 'BEGIN {
                m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04"; m["May"]="05"; m["Jun"]="06";
                m["Jul"]="07"; m["Aug"]="08"; m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12";
                "date +%Y" | getline year; close("date +%Y");
            }
            /sshd.*Accepted (password|publickey|keyboard-interactive)/ {
                ip="";
                for (i=1; i<NF; i++) if ($i=="from") { ip=$(i+1); break }
                if (ip!="") {
                    mon=m[$1]; if(mon=="") mon=$1;
                    day=$2; if(length(day)==1) day="0"day;
                    print year "-" mon "-" day "T" $3 "|" ip
                }
            }' "$file_line"
        fi
    done
}

show_successful_ssh_login_ips() {
    local -a entries=()
    local line rank stamp ip count page=0 page_size=10 total_pages start end choice
    mapfile -t entries < <(ssh_success_login_entries | awk -F'|' '{ip=$2; if (!(ip in latest) || $1 > latest[ip]) latest[ip]=$1; count[ip]++} END {for (ip in latest) print latest[ip] "|" ip "|" count[ip]}' | sort -t'|' -k1,1r)

    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}             [SSH 成功登录来源 IP]                 ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${BLUE}[说明]${PLAIN} 重复 IP 已合并，按最近一次成功登录时间从近到远排列。"
        echo -e "${BLUE}[范围]${PLAIN} 读取最近 5000 条 SSH 服务日志。"
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        if ((${#entries[@]} == 0)); then
            echo -e "${YELLOW}暂无可读取的 SSH 成功登录记录。${PLAIN}"
            echo -e "${CYAN}----------------------------------------------------${PLAIN}"
            read -rp "按回车返回..."
            return 0
        fi

        total_pages=$(( (${#entries[@]} + page_size - 1) / page_size ))
        if (( page >= total_pages )); then
            page=$((total_pages - 1))
        fi
        start=$((page * page_size))
        end=$((start + page_size))
        if (( end > ${#entries[@]} )); then
            end=${#entries[@]}
        fi

        printf '%-4s %-22s %-40s %s\n' '序号' '最近登录' 'IP 地址' '登录次数'
        for ((rank=start+1; rank<=end; rank++)); do
            line=${entries[rank-1]}
            stamp=${line%%|*}
            ip=${line#*|}; ip=${ip%%|*}
            count=${line##*|}
            printf '%-4s %-22s %-40s %s\n' "$rank" "$stamp" "$ip" "$count"
        done
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "第 $((page + 1)) / ${total_pages} 页，共 ${#entries[@]} 个 IP"
        if (( total_pages > 1 )); then
            echo -e "${GREEN}n${PLAIN}. 下一页   ${GREEN}p${PLAIN}. 上一页   ${GREEN}q${PLAIN}. 返回"
            read -rp "请选择：[n/p/q] " choice
            case "${choice,,}" in
                n)
                    if (( page < total_pages - 1 )); then
                        page=$((page + 1))
                    fi
                    ;;
                p)
                    if (( page > 0 )); then
                        page=$((page - 1))
                    fi
                    ;;
                q|0) return 0 ;;
                *) ;;
            esac
        else
            read -rp "按回车返回..."
            return 0
        fi
    done
}

ssh_port_menu() {
    while true; do
        clear
        local old_port new_port
        old_port="$(state_get ssh_migration_old_port 2>/dev/null || true)"
        new_port="$(state_get ssh_migration_new_port 2>/dev/null || true)"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              [SSH 远程连接端口管理]               ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        if [[ -n "$old_port" && -n "$new_port" ]]; then
            echo -e "  当前待处理迁移: ${YELLOW}${old_port} → ${new_port}${PLAIN}"
            echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        fi
        echo -e "  ${GREEN}1.${PLAIN} 修改 SSH 端口（保留旧端口）"
        echo -e "     ${YELLOW}新端口登录成功后，必须回来选择 2 手动删除旧端口。${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 删除已验证的旧 SSH 端口"
        echo -e "     ${YELLOW}必须同时检测到新旧两个端口正在监听，且当前会话必须通过新端口登录。${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 查看成功登录 SSH 的 IP"
        echo -e "     ${YELLOW}重复 IP 自动合并，并按最近一次成功登录时间排序。${PLAIN}"
        echo -e "  ${GREEN}4.${PLAIN} 放弃本次迁移并恢复原 SSH 端口"
        echo -e "     ${YELLOW}用于解除迁移状态卡住的问题；如果当前会话来自新端口，回退可能导致当前连接断开。${PLAIN}"
        echo -e "  ${GREEN}0.${PLAIN} 返回上一级"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-4]: " choice
        case "$choice" in
            1) change_ssh_port || true; read -rp "按回车继续..." ;;
            2) remove_old_ssh_port || true; read -rp "按回车继续..." ;;
            3) show_successful_ssh_login_ips ;;
            4) cancel_ssh_port_migration || true; read -rp "按回车继续..." ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}

firewall_show_allowed() {
    local backend="$1"
    case "$backend" in
        ufw)
            echo -e "${CYAN}当前 UFW 放行规则：${PLAIN}"
            ufw status | sed -n '/^Status:/,$p' || true
            ;;
        firewalld)
            echo -e "${CYAN}当前 firewalld 放行端口/服务：${PLAIN}"
            echo -e "  ports:   $(firewall-cmd --list-ports 2>/dev/null || echo '（无）')"
            echo -e "  services: $(firewall-cmd --list-services 2>/dev/null || echo '（无）')"
            ;;
        none)
            echo -e "${YELLOW}当前没有已启用的 UFW/firewalld。${PLAIN}"
            ;;
    esac
}

firewall_rule_exists() {
    local backend="$1" port="$2" proto="$3"
    case "$backend" in
        ufw)
            ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}([[:space:]]|$)"
            ;;
        firewalld)
            if firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1; then
                return 0
            fi
            if [[ "$proto" == "tcp" && "$port" == "80" ]]; then
                firewall-cmd --query-service=http --permanent >/dev/null 2>&1
                return $?
            fi
            if [[ "$proto" == "tcp" && "$port" == "443" ]]; then
                firewall-cmd --query-service=https --permanent >/dev/null 2>&1
                return $?
            fi
            if [[ "$proto" == "tcp" && "$port" == "22" ]]; then
                firewall-cmd --query-service=ssh --permanent >/dev/null 2>&1
                return $?
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

firewall_port_purpose() {
    local port_proto="$1"
    local port="${port_proto%/*}" proto="${port_proto#*/}"
    case "$port_proto" in
        22/tcp) echo "SSH 远程管理" ;;
        80/tcp) echo "HTTP 网站" ;;
        443/tcp) echo "HTTPS 网站" ;;
        53/tcp|53/udp) echo "DNS 域名解析" ;;
        21/tcp) echo "FTP 文件传输" ;;
        25/tcp) echo "SMTP 邮件" ;;
        110/tcp) echo "POP3 邮件" ;;
        143/tcp) echo "IMAP 邮件" ;;
        465/tcp) echo "SMTPS 加密邮件" ;;
        587/tcp) echo "邮件提交" ;;
        993/tcp) echo "IMAPS 加密邮件" ;;
        995/tcp) echo "POP3S 加密邮件" ;;
        3306/tcp) echo "MySQL/MariaDB" ;;
        5432/tcp) echo "PostgreSQL" ;;
        6379/tcp) echo "Redis" ;;
        8080/tcp) echo "常见 Web/面板备用端口" ;;
        8443/tcp) echo "常见 HTTPS/面板备用端口" ;;
        51820/udp) echo "WireGuard" ;;
        25565/tcp) echo "Minecraft 服务" ;;
        *) echo "自定义/用途未知" ;;
    esac
}

firewall_open_port_entries() {
    local backend="$1" file tmp profile token svc info
    tmp=$(make_temp_dir firewall-list) || return 1
    trap 'rm -rf -- "$tmp"' RETURN
    file="${tmp}/entries"
    : > "$file" || return 1

    case "$backend" in
        ufw)
            while read -r token; do
                [[ -n "$token" ]] || continue
                echo "${token}|UFW 端口规则" >> "$file"
            done < <(ufw status 2>/dev/null | grep -oE '[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)' | sort -u)
            while IFS= read -r profile; do
                profile="${profile#  }"
                [[ -n "$profile" ]] || continue
                while read -r token; do
                    [[ -n "$token" ]] || continue
                    echo "${token}|UFW 服务:${profile}" >> "$file"
                done < <(ufw app info "$profile" 2>/dev/null | grep -oE '[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)' | sort -u)
            done < <(ufw app list 2>/dev/null | sed -n '/Available applications:/,$p' | sed -n 's/^  //p')
            ;;
        firewalld)
            while read -r token; do
                [[ -n "$token" ]] || continue
                echo "${token}|firewalld 端口规则" >> "$file"
            done < <(firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)$' | sort -u)
            while read -r svc; do
                [[ -n "$svc" ]] || continue
                info=$(firewall-cmd --info-service="$svc" --permanent 2>/dev/null || true)
                while read -r token; do
                    [[ -n "$token" ]] || continue
                    echo "${token}|firewalld 服务:${svc}" >> "$file"
                done < <(printf '%s\n' "$info" | grep -oE '[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)' | sort -u)
            done < <(firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | sort -u)
            ;;
        *)
            rm -rf "$tmp"
            return 1
            ;;
    esac

    sort -t'|' -k1,1 -k2,2 -u "$file"
    trap - RETURN
    rm -rf -- "$tmp"
}

firewall_show_open_ports() {
    local backend="$1" count=0 item rule source purpose
    local -a lines=()
    backend="${backend:-$(firewall_backend)}"
    echo -e "${CYAN}当前防火墙放行端口：${PLAIN}"
    if [[ "$backend" == "none" ]]; then
        echo -e "  ${YELLOW}当前没有启用 UFW/firewalld。${PLAIN}"
        return 0
    fi
    mapfile -t lines < <(firewall_open_port_entries "$backend" 2>/dev/null || true)
    if ((${#lines[@]} == 0)); then
        echo -e "  ${YELLOW}未识别到数字端口放行规则。${PLAIN}"
        return 0
    fi
    for item in "${lines[@]}"; do
        rule="${item%%|*}"; source="${item#*|}"; purpose=$(firewall_port_purpose "$rule")
        count=$((count + 1))
        printf '  %2d. %-12s %-18s %s\n' "$count" "$rule" "$purpose" "$source"
    done
    echo -e "${GREEN}共 ${count} 个已识别的端口规则。${PLAIN}"
}

firewall_manage_disable() {
    local backend="$1" choice rule source purpose profile svc token
    local -a entries=()
    mapfile -t entries < <(firewall_open_port_entries "$backend" 2>/dev/null || true)
    ((${#entries[@]} > 0)) || { echo -e "${YELLOW}[提示]${PLAIN} 当前没有可管理的数字端口规则。"; return 1; }
    echo -e "${YELLOW}[警告]${PLAIN} 关闭端口会立即影响对应服务；当前 SSH 端口禁止关闭。"
    read -rp "输入要禁用的编号 [1-${#entries[@]}，其他取消]: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return 0
    (( choice >= 1 && choice <= ${#entries[@]} )) || return 1
    rule="${entries[$((choice-1))]%|*}"
    source="${entries[$((choice-1))]#*|}"
    purpose=$(firewall_port_purpose "$rule")
    local port="${rule%/*}" proto="${rule#*/}" ssh_ports_raw
    local -a current_ssh_ports=()
    if [[ "$proto" == "tcp" ]]; then
        if ! ssh_ports_raw=$(get_current_ssh_ports 2>/dev/null); then
            echo -e "${RED}[禁止操作]${PLAIN} 无法可靠识别当前 SSH 端口集合，为避免误断 SSH，暂不允许关闭 TCP 端口。"
            return 1
        fi
        if [[ -z "$ssh_ports_raw" ]]; then
            echo -e "${RED}[禁止操作]${PLAIN} 未检测到有效 SSH 端口，为避免误断 SSH，暂不允许关闭 TCP 端口。"
            return 1
        fi
        mapfile -t current_ssh_ports <<< "$ssh_ports_raw"
        for current_ssh in "${current_ssh_ports[@]}"; do
            if [[ "$port" == "$current_ssh" ]]; then
                echo -e "${RED}[禁止操作]${PLAIN} ${rule} 是当前 SSH 端口，不能从这里关闭。"
                return 1
            fi
        done
    fi
    echo -e "${YELLOW}[目标]${PLAIN} ${rule} — ${purpose}"
    echo -e "${BLUE}[来源]${PLAIN} ${source}"
    if [[ "$source" == UFW\ 服务:* || "$source" == firewalld\ 服务:* ]]; then
        local svc_name="${source#*:}"
        local -a service_port_list=()
        if [[ "$backend" == "ufw" ]]; then
            mapfile -t service_port_list < <(ufw app info "$svc_name" 2>/dev/null | grep -oE '[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)' | sort -u)
        else
            mapfile -t service_port_list < <(firewall-cmd --info-service="$svc_name" --permanent 2>/dev/null | grep -oE '[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)' | sort -u)
        fi
        if ((${#service_port_list[@]} != 1)) || [[ "${service_port_list[0]:-}" != "${rule}" ]]; then
            echo -e "${YELLOW}[提示]${PLAIN} 该端口由服务规则 ${svc_name} 提供，关闭端口可能同时影响其它端口。为避免误删，请直接在对应防火墙服务中管理。"
            return 1
        fi
        confirm_safety_prompt "关闭 ${rule}" "作用：关闭 ${purpose} 的防火墙放行；此操作会移除服务规则 ${svc_name}。" || return 1
        if [[ "$backend" == "ufw" ]]; then
            ufw delete allow "$svc_name" >/dev/null || return 1
        else
            firewall-cmd --permanent --remove-service="$svc_name" >/dev/null || return 1
            firewall-cmd --reload >/dev/null || return 1
        fi
    else
        confirm_safety_prompt "关闭 ${rule}" "作用：停止对 ${purpose} 的入站放行；不会停止服务本身。" || return 1
        firewall_close_port_rule "$port" "$proto" || return 1
    fi
    if firewall_rule_exists "$backend" "$port" "$proto"; then
        echo -e "${YELLOW}[提示]${PLAIN} ${rule} 仍被其它规则或服务放行，未宣布为“已关闭”。请根据上方来源继续处理。"
        return 1
    fi
    echo -e "${GREEN}[完成]${PLAIN} ${rule} 已停止防火墙放行。"
    log_action "[防火墙] 手动关闭 ${rule}（${purpose}）"
}

firewall_manage_add() {
    local port proto purpose
    read -rp "输入要放行的端口 [1-65535]: " port
    validate_port_any "$port" || { echo -e "${RED}[错误]${PLAIN} 端口必须在 1-65535。"; return 1; }
    read -rp "协议 [tcp/udp，默认 tcp]: " proto
    proto="${proto:-tcp}"
    [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { echo -e "${RED}[错误]${PLAIN} 协议只能是 tcp/udp。"; return 1; }
    purpose=$(firewall_port_purpose "${port}/${proto}")
    confirm_safety_prompt "放行 ${port}/${proto}" "作用：允许 ${purpose} 的入站流量；不会自动启动对应服务。" || return 1
    firewall_allow "$port" "$proto" || { echo -e "${RED}[错误]${PLAIN} 无法放行 ${port}/${proto}。"; return 1; }
    echo -e "${GREEN}[完成]${PLAIN} ${port}/${proto} 已放行。"
    log_action "[防火墙] 手动放行 ${port}/${proto}（${purpose}）"
}

firewall_port_manager_menu() {
    local backend
    while true; do
        clear
        backend=$(firewall_backend)
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}            [防火墙] 已放行端口与规则管理           ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        if [[ "$backend" == "none" ]]; then
            echo -e "${YELLOW}[状态]${PLAIN} 当前未启用 UFW/firewalld。先在选项 4 启用防火墙。"
        else
            firewall_show_open_ports "$backend"
        fi
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看已放行端口"
        echo -e "  ${GREEN}2.${PLAIN} 新增放行端口"
        echo -e "  ${GREEN}3.${PLAIN} 禁用放行端口"
        echo -e "  ${RED}0.${PLAIN} 返回"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-3]: " choice
        case "$choice" in
            1) clear; firewall_show_open_ports "$backend" || true; read -rp "按回车继续..." ;;
            2) if [[ "$backend" == "none" ]]; then echo -e "${YELLOW}[提示]${PLAIN} 请先启用防火墙。"; sleep 1; else firewall_manage_add || true; read -rp "按回车继续..."; fi ;;
            3) if [[ "$backend" == "none" ]]; then echo -e "${YELLOW}[提示]${PLAIN} 当前没有已启用的防火墙。"; sleep 1; else firewall_manage_disable "$backend" || true; read -rp "按回车继续..."; fi ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}

setup_firewall() {
    check_os || return 1
    local cur_port backend answer port proto session_port rule
    local -a ssh_ports=() required_rules=() missing_rules=()

    if ! mapfile -t ssh_ports < <(get_current_ssh_ports); then
        echo -e "${RED}[错误]${PLAIN} 无法可靠探测当前 SSH 端口集合，已停止防火墙配置；现有防火墙不会被启用或重置。"
        return 1
    fi
    ((${#ssh_ports[@]} > 0)) || { echo -e "${RED}[错误]${PLAIN} 未检测到任何有效 SSH 端口，已停止防火墙配置。"; return 1; }
    for cur_port in "${ssh_ports[@]}"; do
        required_rules+=("${cur_port}/tcp")
    done
    if session_port=$(current_ssh_session_port 2>/dev/null) && validate_ssh_port "$session_port"; then
        local found_session_port=0
        for cur_port in "${ssh_ports[@]}"; do
            [[ "$cur_port" == "$session_port" ]] && found_session_port=1 && break
        done
        (( found_session_port )) || required_rules+=("${session_port}/tcp")
    fi
    required_rules+=("80/tcp" "443/tcp")
    cur_port="${ssh_ports[0]}"
    backend=$(firewall_backend)

    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}              [防火墙基线状态检查]                 ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    if [[ "$backend" == "ufw" ]]; then
        echo -e "${GREEN}[状态]${PLAIN} UFW 已启用。"
        firewall_show_open_ports ufw
        for rule in "${required_rules[@]}"; do
            port="${rule%/*}"; proto="${rule#*/}"
            if ! firewall_rule_exists ufw "$port" "$proto"; then
                missing_rules+=("$rule")
            fi
        done
        if ((${#missing_rules[@]} == 0)); then
            echo -e "${GREEN}[完成]${PLAIN} 当前 SSH 端口集合与 HTTP/HTTPS 基线均已放行，无需重复操作。"
            return 0
        fi
        echo -e "${YELLOW}[待补充]${PLAIN} 以下规则尚未放行：${missing_rules[*]}"
        read -rp "是否现在补充这些规则？[y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[提示]${PLAIN} 未修改现有防火墙规则。"; return 1; }
        for rule in "${missing_rules[@]}"; do
            port="${rule%/*}"; proto="${rule#*/}"
            firewall_allow "$port" "$proto" || { echo -e "${RED}[错误]${PLAIN} 无法放行 ${rule}。"; return 1; }
        done
        firewall_show_open_ports ufw
        log_action "[安全保留] UFW 已启用，本次补充基线规则：${missing_rules[*]}"
        echo -e "${GREEN}[完成]${PLAIN} 基线规则已补充并立即生效。"
        return 0
    fi

    if [[ "$backend" == "firewalld" ]]; then
        echo -e "${GREEN}[状态]${PLAIN} firewalld 已运行。"
        firewall_show_open_ports firewalld
        for rule in "${required_rules[@]}"; do
            port="${rule%/*}"; proto="${rule#*/}"
            if ! firewall_rule_exists firewalld "$port" "$proto"; then
                missing_rules+=("$rule")
            fi
        done
        if ((${#missing_rules[@]} == 0)); then
            echo -e "${GREEN}[完成]${PLAIN} 当前 SSH 端口集合与 HTTP/HTTPS 基线均已具备，无需重复操作。"
            return 0
        fi
        echo -e "${YELLOW}[待补充]${PLAIN} 以下规则尚未放行：${missing_rules[*]}"
        read -rp "是否现在补充这些规则？[y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[提示]${PLAIN} 未修改现有防火墙规则。"; return 1; }
        for rule in "${missing_rules[@]}"; do
            port="${rule%/*}"; proto="${rule#*/}"
            firewall_allow "$port" "$proto" || { echo -e "${RED}[错误]${PLAIN} 无法放行 ${rule}。"; return 1; }
        done
        firewall_show_open_ports firewalld
        log_action "[安全保留] firewalld 已运行，本次补充基线规则：${missing_rules[*]}"
        echo -e "${GREEN}[完成]${PLAIN} 基线规则已补充并立即生效。"
        return 0
    fi

    echo -e "${YELLOW}[状态]${PLAIN} 当前没有已启用的 UFW/firewalld。"
    echo -e "${BLUE}[说明]${PLAIN} 作用：建立 SSH/HTTP/HTTPS 最小入站基线；外部安全组仍需单独确认。"
    firewall_show_open_ports none
    echo -e "${YELLOW}[计划]${PLAIN} 将放行：${required_rules[*]}"
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        if command_exists ufw; then
            echo -e "${YELLOW}[状态]${PLAIN} 检测到 UFW 已安装但当前未启用。"
            read -rp "是否配置并立即启用现有 UFW？[y/N]: " answer
        else
            echo -e "${YELLOW}[计划]${PLAIN} 将安装、配置并立即启用 UFW，默认采用上述放行清单。"
            read -rp "是否安装、配置并立即启用 UFW？[y/N]: " answer
        fi
        echo -e "${RED}[重要警告]${PLAIN} 执行后入站默认策略将变为 deny；请先确认云平台安全组已允许上述所有 SSH 端口。"
        [[ "$answer" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[提示]${PLAIN} 未执行防火墙安装/启用。"; return 1; }
        export DEBIAN_FRONTEND=noninteractive
        if ! command_exists ufw; then
            apt-get update
            apt-get install -y ufw
        fi
        ufw default deny incoming >/dev/null
        for rule in "${required_rules[@]}"; do
            port="${rule%/*}"; proto="${rule#*/}"
            firewall_allow "$port" "$proto" || { echo -e "${RED}[错误]${PLAIN} 无法放行 ${rule}。已停止启用操作，请检查现有规则。"; return 1; }
        done
        ufw default allow outgoing >/dev/null
        ufw --force enable
        firewall_show_open_ports ufw
        log_action "[安全保留] 配置并启用 UFW，基线=${required_rules[*]}"
        echo -e "${GREEN}[完成]${PLAIN} UFW 已启用，以上规则现在已经生效。"
    elif command_exists firewall-cmd; then
        echo -e "${YELLOW}[状态]${PLAIN} 检测到 firewalld 已安装，但当前未运行。"
        read -rp "是否启动、配置并立即应用 firewalld？[y/N]: " answer
        echo -e "${RED}[重要警告]${PLAIN} 启动后入站访问将受 firewalld 管理；请先确认云平台安全组已允许上述所有 SSH 端口。"
        [[ "$answer" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[提示]${PLAIN} 未启动或修改 firewalld。"; return 1; }
        systemctl enable --now firewalld
        for rule in "${required_rules[@]}"; do
            port="${rule%/*}"; proto="${rule#*/}"
            firewall_allow "$port" "$proto" || { echo -e "${RED}[错误]${PLAIN} 无法放行 ${rule}。请检查 firewalld 当前状态。"; return 1; }
        done
        firewall_show_open_ports firewalld
        log_action "[安全保留] 启动并配置 firewalld，基线=${required_rules[*]}"
        echo -e "${GREEN}[完成]${PLAIN} firewalld 已运行，以上规则现在已经生效。"
    else
        echo -e "${YELLOW}[提示]${PLAIN} 本工具不会在 RHEL 系系统上强制安装全新的防火墙，以避免无云控制台时锁死 SSH。请先准备 firewalld 后再使用本选项。"
        return 0
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

retry_pending_ssh_firewall_cleanup() {
    local old_port backend
    old_port="$(state_get ssh_migration_firewall_cleanup_pending 2>/dev/null || true)"
    [[ -n "$old_port" ]] || return 0
    validate_port_any "$old_port" || { state_unset ssh_migration_firewall_cleanup_pending; return 0; }
    backend=$(firewall_backend)
    [[ "$backend" != "none" ]] || return 0
    port_in_use "$old_port" tcp && return 0
    if firewall_remove_owned_rules "$old_port" tcp >/dev/null 2>&1; then
        state_unset ssh_migration_firewall_cleanup_pending
        echo -e "${GREEN}[清理完成]${PLAIN} 旧 SSH 端口 ${old_port}/tcp 的工具防火墙规则已关闭。"
    fi
}


# ========================================================
# SSH 防爆破保护（Fail2Ban）
# ========================================================
FAIL2BAN_JAIL_NAME="${FAIL2BAN_JAIL_NAME:-vps-tool-sshd}"
FAIL2BAN_CONFIG="${FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/${FAIL2BAN_JAIL_NAME}.local}"

fail2ban_package_name() {
    printf '%s\n' "fail2ban"
}

fail2ban_service_name() {
    printf '%s\n' "fail2ban"
}

fail2ban_install_package() {
    local pkg
    pkg=$(fail2ban_package_name)
    check_os || return 1
    if command_exists fail2ban-client; then
        return 0
    fi

    echo -e "${BLUE}[准备]${PLAIN} 未检测到 Fail2Ban，将尝试安装。"
    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y "$pkg"
            ;;
        dnf|yum)
            "${PKG_MANAGER}" -y install "$pkg"
            ;;
        *)
            echo -e "${RED}[错误]${PLAIN} 当前系统没有可用的 Fail2Ban 安装方式。"
            return 1
            ;;
    esac
    command_exists fail2ban-client || {
        echo -e "${RED}[错误]${PLAIN} Fail2Ban 安装后仍无法找到 fail2ban-client。"
        return 1
    }
}

fail2ban_detect_log_config() {
    if [[ -f /var/log/auth.log ]]; then
        printf '%s\n' 'backend = auto' 'logpath = /var/log/auth.log'
        return 0
    fi
    if [[ -f /var/log/secure ]]; then
        printf '%s\n' 'backend = auto' 'logpath = /var/log/secure'
        return 0
    fi
    if command_exists journalctl; then
        printf '%s\n' 'backend = systemd' 'journalmatch = _COMM=sshd + _COMM=sshd-session'
        return 0
    fi
    return 1
}

fail2ban_detect_banaction() {
    local backend action_file
    backend=$(firewall_backend)
    case "$backend" in
        ufw)
            action_file="/etc/fail2ban/action.d/ufw.conf"
            [[ -f "$action_file" ]] && { printf '%s\n' 'banaction = ufw'; return 0; }
            ;;
        firewalld)
            action_file="/etc/fail2ban/action.d/firewallcmd-ipset.conf"
            [[ -f "$action_file" ]] && { printf '%s\n' 'banaction = firewallcmd-ipset'; return 0; }
            ;;
    esac
    return 0
}

fail2ban_current_source_ignoreip() {
    local source_ip=""
    source_ip=$(ssh_current_source_ip 2>/dev/null || true)
    if [[ -n "$source_ip" ]]; then
        printf '%s\n' "127.0.0.1/8 ::1 ${source_ip}"
    else
        printf '%s\n' '127.0.0.1/8 ::1'
    fi
}

fail2ban_target_ssh_ports() {
    local -a ports=() valid_ports=()
    local port csv
    mapfile -t ports < <(get_current_ssh_ports)
    ((${#ports[@]} > 0)) || return 1
    for port in "${ports[@]}"; do
        validate_ssh_port "$port" || continue
        valid_ports+=("$port")
    done
    ((${#valid_ports[@]} > 0)) || return 1
    csv=$(IFS=,; echo "${valid_ports[*]}")
    printf '%s\n' "$csv"
}

validate_fail2ban_port_list() {
    local csv="$1" port
    local -a ports=()
    IFS=',' read -r -a ports <<< "$csv"
    ((${#ports[@]} > 0)) || return 1
    for port in "${ports[@]}"; do
        validate_ssh_port "$port" || return 1
    done
}

fail2ban_write_config() {
    local ssh_ports="$1" tmp log_lines banaction_line ignoreip
    validate_fail2ban_port_list "$ssh_ports" || return 1
    mkdir -p "$(dirname "$FAIL2BAN_CONFIG")" || return 1

    if [[ -e "$FAIL2BAN_CONFIG" ]] && ! is_owned "$FAIL2BAN_CONFIG"; then
        echo -e "${RED}[错误]${PLAIN} 已存在非本工具创建的 Fail2Ban 配置：${FAIL2BAN_CONFIG}"
        echo -e "${YELLOW}[提示]${PLAIN} 为避免覆盖用户现有防护配置，本工具不会修改它。"
        return 1
    fi

    local log_config
    log_config=$(fail2ban_detect_log_config) || {
        echo -e "${RED}[错误]${PLAIN} 无法找到 SSH 认证日志或 systemd journal，无法安全配置 Fail2Ban。"
        return 1
    }
    mapfile -t log_lines <<< "$log_config"
    banaction_line=$(fail2ban_detect_banaction || true)
    ignoreip=$(fail2ban_current_source_ignoreip)
    tmp=$(mktemp) || return 1

    {
        printf '%s\n' "# Managed by VPS-Tool: SSH brute-force protection" \
            "# [部分可撤销] 删除本文件即可撤销本工具创建的 Fail2Ban SSH jail；Fail2Ban 软件包本身不自动卸载。" \
            "# [状态同步] port 始终按 sshd 当前实际生效端口同步；迁移期间会同时保护旧/新端口。" \
            "[${FAIL2BAN_JAIL_NAME}]" \
            'enabled = true' \
            'filter = sshd' \
            "port = ${ssh_ports}" \
            'findtime = 10m' \
            'maxretry = 5' \
            'bantime = 1d' \
            "ignoreip = ${ignoreip}"
        printf '%s\n' "${log_lines[@]}"
        if [[ -n "$banaction_line" ]]; then
            printf '%s\n' "$banaction_line"
        fi
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$FAIL2BAN_CONFIG" || { rm -f "$tmp"; return 1; }
    mark_owned "$FAIL2BAN_CONFIG" || { rm -f "$FAIL2BAN_CONFIG"; return 1; }
    state_set fail2ban_sshd_config_owned 1
}

fail2ban_sync_ssh_protection() {
    local target_ports current_ports backup_tmp=""
    command_exists fail2ban-client || return 0
    [[ -f "$FAIL2BAN_CONFIG" ]] || return 0
    is_owned "$FAIL2BAN_CONFIG" || return 0

    target_ports=$(fail2ban_target_ssh_ports) || return 1
    current_ports=$(awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$FAIL2BAN_CONFIG" 2>/dev/null || true)
    [[ "$current_ports" == "$target_ports" ]] && { state_unset fail2ban_ssh_sync_pending; return 0; }

    backup_tmp=$(mktemp) || return 1
    cp -a "$FAIL2BAN_CONFIG" "$backup_tmp" || { rm -f "$backup_tmp"; return 1; }
    if ! fail2ban_write_config "$target_ports" || ! fail2ban_apply_config; then
        cp -a "$backup_tmp" "$FAIL2BAN_CONFIG" 2>/dev/null || true
        rm -f "$backup_tmp"
        state_set fail2ban_ssh_sync_pending 1
        echo -e "${YELLOW}[提示]${PLAIN} Fail2Ban 未能同步当前 SSH 端口 ${target_ports}，旧防爆破配置仍保留。"
        return 1
    fi
    rm -f "$backup_tmp"
    state_unset fail2ban_ssh_sync_pending
    log_action "[安全同步] Fail2Ban SSH 防爆破端口已同步为 ${target_ports}"
    echo -e "${GREEN}[F2 同步]${PLAIN} SSH 防爆破已同步保护：${target_ports}/tcp。"
    return 0
}

fail2ban_apply_config() {
    local service
    service=$(fail2ban_service_name)
    command_exists fail2ban-client || return 1

    if ! fail2ban-client -t >/dev/null 2>&1; then
        echo -e "${RED}[错误]${PLAIN} Fail2Ban 配置检查失败，已拒绝启动新的 SSH 防护。"
        return 1
    fi

    systemctl enable --now "$service" >/dev/null 2>&1 || {
        echo -e "${RED}[错误]${PLAIN} 无法启动 Fail2Ban 服务。"
        return 1
    }
    fail2ban-client reload >/dev/null 2>&1 || {
        echo -e "${RED}[错误]${PLAIN} Fail2Ban 重载失败。"
        return 1
    }
    fail2ban-client status "$FAIL2BAN_JAIL_NAME" >/dev/null 2>&1 || {
        echo -e "${RED}[错误]${PLAIN} SSH 防爆破 jail 未成功启用。"
        return 1
    }
}

fail2ban_enable_ssh_protection() {
    local ssh_ports old_config config_created=0 backup_tmp=""
    check_os || return 1
    ssh_ports=$(fail2ban_target_ssh_ports) || {
        echo -e "${RED}[错误]${PLAIN} 无法可靠确定当前 SSH 端口，暂不启用 Fail2Ban。"
        return 1
    }

    echo -e "${CYAN}[当前策略]${PLAIN} SSH 失败 ${YELLOW}5 次 / 10 分钟${PLAIN} → 封禁 ${YELLOW}1 天${PLAIN}。"
    echo -e "${BLUE}[说明]${PLAIN} 作用：连续登录失败的来源 IP 会被临时封禁，减少 SSH 爆破干扰。"
    echo -e "${YELLOW}[安全提示]${PLAIN} 当前 SSH 来源 IP 会加入忽略列表，避免误封本次管理连接。"
    if ! confirm_safety_prompt "启用 SSH 防爆破保护" "Fail2Ban 将监控当前 SSH 认证失败并自动封禁高频失败来源。默认 5 次/10 分钟封禁 1 天；封禁按来源 IP 生效。"; then
        return 1
    fi

    fail2ban_install_package || return 1

    old_config=0
    if [[ -f "$FAIL2BAN_CONFIG" ]]; then
        old_config=1
        if ! is_owned "$FAIL2BAN_CONFIG"; then
            echo -e "${RED}[错误]${PLAIN} 已存在非本工具创建的 Fail2Ban 配置，拒绝覆盖。"
            return 1
        fi
        backup_tmp=$(mktemp) || return 1
        cp -a "$FAIL2BAN_CONFIG" "$backup_tmp" || { rm -f "$backup_tmp"; return 1; }
    fi
    if ! fail2ban_write_config "$ssh_ports"; then
        rm -f "$backup_tmp"
        return 1
    fi
    config_created=1

    if ! fail2ban_apply_config; then
        if (( old_config == 1 )); then
            cp -a "$backup_tmp" "$FAIL2BAN_CONFIG" 2>/dev/null || true
            mark_owned "$FAIL2BAN_CONFIG" || true
            state_set fail2ban_sshd_config_owned 1
        else
            rm -f "$FAIL2BAN_CONFIG"
            unmark_owned "$FAIL2BAN_CONFIG"
            state_unset fail2ban_sshd_config_owned
        fi
        rm -f "$backup_tmp"
        return 1
    fi
    rm -f "$backup_tmp"

    echo -e "${GREEN}[完成]${PLAIN} SSH 防爆破已启用：5 次失败 / 10 分钟，封禁 1 天。"
    echo -e "${BLUE}[状态]${PLAIN} 当前保护端口：${ssh_ports}/tcp | jail：${FAIL2BAN_JAIL_NAME}"
    log_action "[安全保留] 启用 Fail2Ban SSH 防爆破（5/10m，ban=1d，port=${ssh_ports})"
}

fail2ban_current_ban_summary() {
    local status_line
    fail2ban-client status "$FAIL2BAN_JAIL_NAME" 2>/dev/null | awk -F: '/Currently banned/ {gsub(/^ +/,"",$2); print $2; exit}'
}

fail2ban_total_ban_actions() {
    fail2ban-client status "$FAIL2BAN_JAIL_NAME" 2>/dev/null | awk -F: '/Total banned/ {gsub(/^ +/,"",$2); print $2; exit}'
}

fail2ban_current_banned_ips() {
    local list
    list=$(fail2ban-client status "$FAIL2BAN_JAIL_NAME" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p' | head -n1 || true)
    [[ -n "$list" ]] || return 0
    tr ' ' '\n' <<< "$list" | awk 'NF' | sort -u
}

fail2ban_ban_events() {
    local since="$1" line entries
    if command_exists journalctl; then
        if [[ -n "$since" ]]; then
            line=$(journalctl --no-pager -o short-iso -u "$(fail2ban_service_name)" --since "$since" 2>/dev/null || true)
        else
            line=$(journalctl --no-pager -o short-iso -u "$(fail2ban_service_name)" 2>/dev/null || true)
        fi
        if [[ -n "$line" ]]; then
            entries=$(awk '/[[:space:]]Ban[[:space:]]/ {
                ip="";
                for (i=1; i<NF; i++) if ($i=="Ban") { ip=$(i+1); break }
                if (ip!="") print $1 "|" ip
            }' <<< "$line")
            if [[ -n "$entries" ]]; then
                printf '%s\n' "$entries"
                return 0
            fi
        fi
    fi

    if [[ -f /var/log/fail2ban.log ]]; then
        awk '/[[:space:]]Ban[[:space:]]/ {
            ip="";
            for (i=1; i<NF; i++) if ($i=="Ban") { ip=$(i+1); break }
            if (ip!="") print $1 " " $2 " " $3 "|" ip
        }' /var/log/fail2ban.log
    fi
}

fail2ban_recent_banned_ips() {
    local -a entries=()
    mapfile -t entries < <(fail2ban_ban_events '5 minutes ago' | awk -F'|' '{ip=$2; if (!(ip in latest) || $1 > latest[ip]) latest[ip]=$1} END {for (ip in latest) print latest[ip] "|" ip}' | sort -t'|' -k1,1r)
    printf '%s\n' "${entries[@]}"
}

fail2ban_show_ssh_status() {
    local target_ports current_banned total_banned
    target_ports=$(fail2ban_target_ssh_ports 2>/dev/null || echo '未知')
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}              [SSH 防爆破状态]                     ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    if ! command_exists fail2ban-client; then
        echo -e "${YELLOW}[状态]${PLAIN} 尚未安装 Fail2Ban。"
        return 1
    fi
    if ! fail2ban-client status "$FAIL2BAN_JAIL_NAME" >/dev/null 2>&1; then
        echo -e "${YELLOW}[状态]${PLAIN} SSH 防爆破当前未启用。"
        echo -e "${BLUE}[当前应保护端口]${PLAIN} ${target_ports}/tcp"
        return 1
    fi

    current_banned=$(fail2ban_current_ban_summary | head -n1)
    total_banned=$(fail2ban_total_ban_actions | head -n1)
    echo -e "${GREEN}[运行状态]${PLAIN} SSH 防爆破已启用"
    echo -e "${BLUE}[当前保护端口]${PLAIN} ${target_ports}/tcp"
    echo -e "${BLUE}[策略]${PLAIN} 10 分钟内失败 5 次 → 封禁 1 天"
    echo -e "${BLUE}[当前封禁 IP]${PLAIN} ${current_banned:-0}"
    echo -e "${BLUE}[累计封禁次数]${PLAIN} ${total_banned:-0}"
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 查看当前封禁 IP 总数"
    echo -e "  ${GREEN}2.${PLAIN} 查看近 5 分钟新封禁 IP"
    echo -e "  ${GREEN}3.${PLAIN} 查看当前封禁 IP 详细"
    echo -e "  ${GREEN}0.${PLAIN} 返回 F2 菜单"
    echo -e "${CYAN}====================================================${PLAIN}"
    read -rp "请输入选项 [0-3]: " choice
    case "$choice" in
        1)
            clear
            echo -e "${CYAN}====================================================${PLAIN}"
            echo -e "${CYAN}              [当前封禁 IP 总数]                   ${PLAIN}"
            echo -e "${CYAN}====================================================${PLAIN}"
            echo -e "${GREEN}当前封禁 IP：${PLAIN}${current_banned:-0}"
            echo -e "${GREEN}累计封禁次数：${PLAIN}${total_banned:-0}"
            echo -e "${BLUE}当前保护端口：${PLAIN}${target_ports}/tcp"
            ;;
        2)
            clear
            echo -e "${CYAN}====================================================${PLAIN}"
            echo -e "${CYAN}              [近 5 分钟新封禁 IP]                 ${PLAIN}"
            echo -e "${CYAN}====================================================${PLAIN}"
            local -a recent_ips=()
            mapfile -t recent_ips < <(fail2ban_recent_banned_ips)
            if ((${#recent_ips[@]} == 0)); then
                echo -e "${YELLOW}近 5 分钟没有新的封禁记录。${PLAIN}"
            else
                local i=1 entry stamp ip
                for entry in "${recent_ips[@]}"; do
                    stamp=${entry%%|*}
                    ip=${entry#*|}
                    printf '  %s. %s  %s\n' "$i" "$stamp" "$ip"
                    i=$((i+1))
                done
            fi
            ;;
        3)
            clear
            echo -e "${CYAN}====================================================${PLAIN}"
            echo -e "${CYAN}              [当前封禁 IP 详细]                   ${PLAIN}"
            echo -e "${CYAN}====================================================${PLAIN}"
            local -a banned_ips=()
            mapfile -t banned_ips < <(fail2ban_current_banned_ips)
            if ((${#banned_ips[@]} == 0)); then
                echo -e "${YELLOW}暂无当前封禁 IP。${PLAIN}"
            else
                local i=1 ip
                for ip in "${banned_ips[@]}"; do
                    printf '  %s. %s\n' "$i" "$ip"
                    i=$((i+1))
                done
            fi
            ;;
        0) return 0 ;;
        *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; return 1 ;;
    esac
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    read -rp "按回车返回 F2 菜单..."
}

fail2ban_unban_ssh_ip() {
    local ip
    command_exists fail2ban-client || { echo -e "${YELLOW}[提示]${PLAIN} Fail2Ban 尚未安装。"; return 1; }
    read -rp "输入要解除封禁的 IPv4/IPv6 地址：" ip
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || { echo -e "${RED}[错误]${PLAIN} IP 地址格式不正确。"; return 1; }
    fail2ban-client set "$FAIL2BAN_JAIL_NAME" unbanip "$ip" >/dev/null 2>&1 || {
        echo -e "${RED}[错误]${PLAIN} 未能解除 ${ip} 的封禁，请检查它是否在当前 jail 中。"
        return 1
    }
    echo -e "${GREEN}[完成]${PLAIN} 已请求解除 ${ip} 的封禁。"
}

fail2ban_disable_ssh_protection() {
    if ! command_exists fail2ban-client; then
        state_unset fail2ban_sshd_config_owned
        return 0
    fi
    if [[ -f "$FAIL2BAN_CONFIG" ]] && ! is_owned "$FAIL2BAN_CONFIG"; then
        echo -e "${RED}[错误]${PLAIN} 当前配置并非本工具创建，拒绝自动删除。"
        return 1
    fi
    confirm_safety_prompt "停用 SSH 防爆破保护" "作用：停止本工具创建的 SSH Fail2Ban jail；不会卸载 Fail2Ban 软件，也不会删除其它 jail。" || return 1
    fail2ban-client stop "$FAIL2BAN_JAIL_NAME" >/dev/null 2>&1 || true
    if [[ -f "$FAIL2BAN_CONFIG" ]]; then
        rm -f "$FAIL2BAN_CONFIG" || return 1
        unmark_owned "$FAIL2BAN_CONFIG"
    fi
    state_unset fail2ban_sshd_config_owned
    fail2ban-client reload >/dev/null 2>&1 || true
    echo -e "${GREEN}[完成]${PLAIN} 本工具创建的 SSH 防爆破 jail 已停用。Fail2Ban 软件包保留，便于其它防护继续使用。"
    log_action "[安全保留] 停用本工具的 Fail2Ban SSH 防爆破 jail"
}

ssh_bruteforce_menu() {
    while true; do
        fail2ban_sync_ssh_protection || true
        clear
        local protected_ports
        protected_ports=$(fail2ban_target_ssh_ports 2>/dev/null || echo "未知")
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              [SSH 防爆破保护] Fail2Ban              ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  当前保护端口: ${GREEN}${protected_ports}/tcp${PLAIN}"
        echo -e "  当前策略: ${YELLOW}10 分钟内失败 5 次 → 封禁 1 天${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 启用/更新 SSH 防爆破"
        echo -e "  ${GREEN}2.${PLAIN} 查看防爆破状态"
        echo -e "  ${GREEN}3.${PLAIN} 解除指定 IP 封禁"
        echo -e "  ${GREEN}4.${PLAIN} 停用本工具的 SSH 防爆破"
        echo -e "  ${RED}0.${PLAIN} 返回"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-4]: " choice
        case "$choice" in
            1) fail2ban_enable_ssh_protection || true; read -rp "按回车继续..." ;;
            2) clear; fail2ban_show_ssh_status || true; read -rp "按回车继续..." ;;
            3) fail2ban_unban_ssh_ip || true; read -rp "按回车继续..." ;;
            4) fail2ban_disable_ssh_protection || true; read -rp "按回车继续..." ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}

security_menu() {
    check_os || return 1
    while true; do
        retry_pending_ssh_firewall_cleanup || true
        if command_exists fail2ban-client && [[ -f "$FAIL2BAN_CONFIG" ]] && is_owned "$FAIL2BAN_CONFIG"; then
            fail2ban_sync_ssh_protection || true
        fi
        clear
        local cur_port
        cur_port=$(get_current_ssh_port 2>/dev/null || true)
        cur_port="${cur_port:-未知}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}            [模块 1] 网络安全与系统加固            ${PLAIN}"
        echo -e "  系统: ${GREEN}${OS_PRETTY} (${ARCH})${PLAIN} | 当前 SSH 端口: ${GREEN}${cur_port}${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 一键全量升级系统软件与时间同步 ${YELLOW}[不可逆更新]${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 一键高危安全漏洞修补升级       ${YELLOW}[不可逆更新]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${YELLOW}3.${PLAIN} 修改 SSH 远程连接端口           ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ${YELLOW}4.${PLAIN} SSH 防爆破保护（Fail2Ban）        ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ${YELLOW}5.${PLAIN} 防火墙基线与端口管理             ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ${YELLOW}6.${PLAIN} 查看/管理已放行端口               ${GREEN}[本机规则可撤销]${PLAIN}"
        echo -e "  ${YELLOW}7.${PLAIN} 部署密钥认证并关闭密码         ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${RED}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-7]: " choice
        case "$choice" in
            1) sys_full_upgrade || true; read -rp "按回车继续..." ;;
            2) sys_security_upgrade || true; read -rp "按回车继续..." ;;
            3) ssh_port_menu || true ;;
            4) ssh_bruteforce_menu || true ;;
            5) setup_firewall || true; read -rp "按回车继续..." ;;
            6) firewall_port_manager_menu || true ;;
            7) setup_ssh_key_auth || true; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    security_menu
fi
