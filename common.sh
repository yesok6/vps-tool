#!/usr/bin/env bash

# Shared helpers for VPS-Tool.
# This file is sourced by install.sh and all modules.

VPS_TOOL_ROOT="${VPS_TOOL_ROOT:-/opt/vps-tool}"
VPS_TOOL_ETC="${VPS_TOOL_ETC:-/etc/vps-tool}"
VPS_TOOL_STATE="${VPS_TOOL_STATE:-${VPS_TOOL_ETC}/state}"
VPS_TOOL_BACKUPS="${VPS_TOOL_BACKUPS:-${VPS_TOOL_ETC}/backups}"
VPS_TOOL_LOG="${VPS_TOOL_LOG:-${VPS_TOOL_ETC}/install.log}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

mkdir -p "${VPS_TOOL_STATE}" "${VPS_TOOL_BACKUPS}"
chmod 700 "${VPS_TOOL_ETC}" "${VPS_TOOL_STATE}" "${VPS_TOOL_BACKUPS}" 2>/dev/null || true

die() {
    echo -e "${RED}[错误]${PLAIN} $*" >&2
    return 1
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

log_action() {
    local action="${1:-}"
    mkdir -p "${VPS_TOOL_ETC}"
    chmod 700 "${VPS_TOOL_ETC}" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${action}" >> "${VPS_TOOL_LOG}"
    chmod 600 "${VPS_TOOL_LOG}" 2>/dev/null || true
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_commands() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        echo -e "${RED}[错误]${PLAIN} 缺少依赖: ${missing[*]}"
        return 1
    fi
}

make_temp_dir() {
    local prefix="${1:-vps-tool}"
    mkdir -p /tmp
    mktemp -d "/tmp/${prefix}.XXXXXX"
}

download_https() {
    local url="$1"
    local output="$2"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120 \
        --output "$output" "$url"
}

download_shell_checked() {
    local url="$1"
    local output="$2"
    download_https "$url" "$output" || return 1
    bash -n "$output" || {
        echo -e "${RED}[错误]${PLAIN} 下载的脚本语法检查失败: ${url}"
        return 1
    }
    chmod 700 "$output"
}

state_key_file() {
    local key="$1"
    printf '%s/%s' "${VPS_TOOL_STATE}" "${key}"
}

state_set() {
    local key="$1"
    local value="${2:-}"
    local file
    file=$(state_key_file "$key")
    printf '%s' "$value" > "$file"
    chmod 600 "$file"
}

state_get() {
    local key="$1"
    local file
    file=$(state_key_file "$key")
    [[ -f "$file" ]] && cat "$file"
}

state_exists() {
    [[ -f "$(state_key_file "$1")" ]]
}

state_unset() {
    rm -f "$(state_key_file "$1")"
}

backup_file_once() {
    local path="$1"
    local key="$2"
    local backup_dir="${VPS_TOOL_BACKUPS}/${key}"
    local backup_path="${backup_dir}/original"
    local marker="${backup_dir}/present"

    if [[ -e "$backup_path" || -f "$backup_dir/missing" ]]; then
        return 0
    fi

    mkdir -p "$backup_dir"
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a "$path" "$backup_path"
        touch "$marker"
    else
        touch "$backup_dir/missing"
    fi
    chmod 700 "$backup_dir"
}

restore_file_backup() {
    local path="$1"
    local key="$2"
    local backup_dir="${VPS_TOOL_BACKUPS}/${key}"
    local backup_path="${backup_dir}/original"

    if [[ -f "$backup_dir/present" && ( -e "$backup_path" || -L "$backup_path" ) ]]; then
        mkdir -p "$(dirname "$path")"
        rm -rf "$path"
        cp -a "$backup_path" "$path"
        return 0
    fi

    if [[ -f "$backup_dir/missing" ]]; then
        rm -rf "$path"
        return 0
    fi

    return 1
}

mark_owned() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    printf '%s' "$path" > "${VPS_TOOL_STATE}/owned.${id}"
    chmod 600 "${VPS_TOOL_STATE}/owned.${id}"
}

is_owned() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    [[ -f "${VPS_TOOL_STATE}/owned.${id}" ]] && [[ "$(cat "${VPS_TOOL_STATE}/owned.${id}")" == "$path" ]]
}

unmark_owned() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    rm -f "${VPS_TOOL_STATE}/owned.${id}"
}

record_runtime_value() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    local dir="${VPS_TOOL_STATE}/runtime"
    mkdir -p "$dir"
    [[ -f "${dir}/${id}.path" || -f "${dir}/${id}.missing" ]] && return 0
    printf '%s' "$path" > "${dir}/${id}.path"
    if [[ -f "$path" ]]; then
        cat "$path" > "${dir}/${id}.value"
    else
        touch "${dir}/${id}.missing"
    fi
}

restore_runtime_values() {
    local dir="${VPS_TOOL_STATE}/runtime"
    local path id
    [[ -d "$dir" ]] || return 0
    for file in "$dir"/*.path; do
        [[ -f "$file" ]] || continue
        id="${file##*/}"
        id="${id%.path}"
        path=$(cat "$file")
        if [[ -f "${dir}/${id}.missing" ]]; then
            rm -f "$path"
        elif [[ -f "${dir}/${id}.value" ]]; then
            cat "${dir}/${id}.value" > "$path" 2>/dev/null || true
        fi
    done
    rm -rf "$dir"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535))
}

port_in_use() {
    local port="$1"
    local proto="${2:-both}"
    case "$proto" in
        tcp) ss -H -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit found ? 0 : 1}' ;;
        udp) ss -H -lun 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit found ? 0 : 1}' ;;
        both)
            port_in_use "$port" tcp || port_in_use "$port" udp
            ;;
        *) return 2 ;;
    esac
}

random_free_port() {
    local proto="${1:-tcp}"
    local attempts=0
    local port
    while ((attempts < 100)); do
        port=$((RANDOM % 50001 + 10000))
        if ! port_in_use "$port" "$proto"; then
            echo "$port"
            return 0
        fi
        ((attempts += 1))
    done
    return 1
}

service_user_exists() {
    getent passwd vps-tool >/dev/null 2>&1
}

service_group_exists() {
    getent group vps-tool >/dev/null 2>&1
}

ensure_service_user() {
    local nologin
    if service_user_exists; then
        service_group_exists || {
            echo -e "${RED}[错误]${PLAIN} 已存在 vps-tool 用户，但缺少对应组，拒绝自动创建以避免改变已有账号结构。"
            return 1
        }
        if [[ "$(state_get service_user_owned 2>/dev/null || true)" != "1" ]]; then
            state_set service_user_owned 0
        fi
        return 0
    fi

    if ! service_group_exists; then
        groupadd --system vps-tool
        state_set service_group_owned 1
    else
        state_set service_group_owned 0
    fi

    nologin="$(command -v nologin 2>/dev/null || true)"
    [[ -n "$nologin" ]] || nologin="/usr/sbin/nologin"
    useradd --system --gid vps-tool --home-dir /var/lib/vps-tool --create-home --shell "$nologin" vps-tool
    state_set service_user_owned 1
}

remove_owned_service_user() {
    if [[ "$(state_get service_user_owned 2>/dev/null || true)" == "1" ]] && service_user_exists; then
        userdel --remove vps-tool 2>/dev/null || userdel vps-tool 2>/dev/null || true
    fi
    if [[ "$(state_get service_group_owned 2>/dev/null || true)" == "1" ]] && service_group_exists; then
        groupdel vps-tool 2>/dev/null || true
    fi
    state_unset service_user_owned
    state_unset service_group_owned
}

firewall_backend() {
    if command_exists ufw && ufw status 2>/dev/null | grep -qw active; then
        echo ufw
        return 0
    fi
    if command_exists firewall-cmd && firewall-cmd --state 2>/dev/null | grep -qx running; then
        echo firewalld
        return 0
    fi
    echo none
}

firewall_allow() {
    local port="$1"
    local proto="$2"
    local backend
    validate_port "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    backend=$(firewall_backend)

    case "$backend" in
        ufw)
            if ! ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}([[:space:]]|$)"; then
                ufw allow "${port}/${proto}" >/dev/null
                mkdir -p "${VPS_TOOL_STATE}/firewall"
                printf 'ufw\n%s\n%s\n' "$port" "$proto" > "${VPS_TOOL_STATE}/firewall/${proto}_${port}.rule"
            fi
            ;;
        firewalld)
            if ! firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1; then
                firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null
                firewall-cmd --reload >/dev/null
                mkdir -p "${VPS_TOOL_STATE}/firewall"
                printf 'firewalld\n%s\n%s\n' "$port" "$proto" > "${VPS_TOOL_STATE}/firewall/${proto}_${port}.rule"
            fi
            ;;
        none)
            echo -e "${YELLOW}[提示]${PLAIN} 当前未检测到已启用的 UFW/firewalld，未自动开启防火墙。"
            return 0
            ;;
    esac
}

firewall_remove_owned_rule() {
    local port="$1" proto="$2"
    local file="${VPS_TOOL_STATE}/firewall/${proto}_${port}.rule"
    [[ -f "$file" ]] || return 0
    local backend
    backend=$(sed -n '1p' "$file")
    case "$backend" in
        ufw) ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true ;;
        firewalld) firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true ;;
    esac
    rm -f "$file"
}

firewall_remove_owned_rules() {
    local file backend port proto
    local dir="${VPS_TOOL_STATE}/firewall"
    [[ -d "$dir" ]] || return 0
    for file in "$dir"/*.rule; do
        [[ -f "$file" ]] || continue
        backend=$(sed -n '1p' "$file")
        port=$(sed -n '2p' "$file")
        proto=$(sed -n '3p' "$file")
        case "$backend" in
            ufw) ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true ;;
            firewalld) firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true ; firewall-cmd --reload >/dev/null 2>&1 || true ;;
        esac
        rm -f "$file"
    done
}
