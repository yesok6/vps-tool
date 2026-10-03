#!/usr/bin/env bash

# Shared helpers for VPS-Tool.
# This file is sourced by install.sh and all modules.

VPS_TOOL_ROOT="${VPS_TOOL_ROOT:-/opt/vps-tool}"
VPS_TOOL_ETC="${VPS_TOOL_ETC:-/etc/vps-tool}"
VPS_TOOL_STATE="${VPS_TOOL_STATE:-${VPS_TOOL_ETC}/state}"
VPS_TOOL_BACKUPS="${VPS_TOOL_BACKUPS:-${VPS_TOOL_ETC}/backups}"
VPS_TOOL_LOG="${VPS_TOOL_LOG:-${VPS_TOOL_ETC}/install.log}"
# [可完全撤销] 工具专属 Swap；低内存且用户确认时按磁盘余量动态创建 256/512/768/1024 MiB，至少保留 1 GiB 根分区空间。
VPS_TOOL_SWAP_PATH="${VPS_TOOL_SWAP_PATH:-/var/lib/vps-tool/swapfile}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

mkdir -p "${VPS_TOOL_ETC}" "${VPS_TOOL_STATE}" "${VPS_TOOL_BACKUPS}"
chmod 711 "${VPS_TOOL_ETC}" 2>/dev/null || true
chmod 700 "${VPS_TOOL_STATE}" "${VPS_TOOL_BACKUPS}" 2>/dev/null || true

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
    chmod 711 "${VPS_TOOL_ETC}" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${action}" >> "${VPS_TOOL_LOG}"
    chmod 600 "${VPS_TOOL_LOG}" 2>/dev/null || true
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 当前操作系统与包管理器信息（供多个模块共用）
OS_ID="${OS_ID:-}"
OS_PRETTY="${OS_PRETTY:-}"
ARCH="${ARCH:-}"
PKG_MANAGER="${PKG_MANAGER:-}"
SSH_SERVICE="${SSH_SERVICE:-}"

check_os() {
    [[ -r /etc/os-release ]] || { echo -e "${RED}[错误]${PLAIN} 无法识别操作系统！"; return 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    ARCH="$(uname -m)"
    case "${OS_ID}" in
        debian|ubuntu)
            PKG_MANAGER="apt"
            SSH_SERVICE="ssh"
            ;;
        centos|rhel|almalinux|rocky|fedora)
            if command_exists dnf; then PKG_MANAGER="dnf"; else PKG_MANAGER="yum"; fi
            SSH_SERVICE="sshd"
            ;;
        *)
            echo -e "${RED}[错误]${PLAIN} 暂不支持该系统: ${OS_PRETTY}"; return 1
            ;;
    esac

    if ! systemctl cat "${SSH_SERVICE}.service" >/dev/null 2>&1; then
        if systemctl cat ssh.service >/dev/null 2>&1; then SSH_SERVICE="ssh"
        elif systemctl cat sshd.service >/dev/null 2>&1; then SSH_SERVICE="sshd"
        else
            echo -e "${RED}[错误]${PLAIN} 找不到 SSH systemd 服务。"
            return 1
        fi
    fi
}

confirm_safety_prompt() {
    local title="$1"
    local description="$2"
    echo -e "${CYAN}[操作]${PLAIN} ${YELLOW}${title}${PLAIN}"
    echo -e "${BLUE}[说明]${PLAIN} ${description}"
    echo -e "${YELLOW}[注意]${PLAIN} 高风险操作请保留当前 SSH 会话，并确保云平台控制台/VNC 可用。"
    local confirm
    read -rp "继续？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[提示]${PLAIN} 操作已取消。"; return 1; }
}

get_mem_available_mb() {
    awk '/^MemAvailable:/ {printf "%d\n", $2/1024; exit}' /proc/meminfo 2>/dev/null || echo 0
}

get_root_free_mb() {
    df -Pm / 2>/dev/null | awk 'NR==2 {print $4; exit}' || echo 0
}

show_system_resource_summary() {
    local mem_mb disk_mb
    mem_mb=$(get_mem_available_mb)
    disk_mb=$(get_root_free_mb)
    echo -e "${CYAN}[资源]${PLAIN} 可用内存 ${mem_mb} MiB | 根分区可用 ${disk_mb} MiB"
}

current_swap_mb() {
    awk 'NR > 1 {sum += $3} END {printf "%d\n", sum / 1024}' /proc/swaps 2>/dev/null
}

recommend_managed_swap_mb() {
    # [资源策略] 尽量增加可用 Swap，但始终至少保留 1 GiB 根分区空间。
    # [安全保留] 仅按 256 MiB 递增、单次最多补到 1 GiB；不覆盖用户已有 Swap。
    local disk_mb swap_mb room_mb target_mb
    disk_mb=$(get_root_free_mb)
    swap_mb=$(current_swap_mb)
    room_mb=$((disk_mb - 1024))
    target_mb=$((1024 - swap_mb))

    (( room_mb < 256 )) && { echo 0; return 0; }
    (( target_mb <= 0 )) && { echo 0; return 0; }
    (( target_mb > 1024 )) && target_mb=1024
    (( target_mb > room_mb )) && target_mb=$room_mb
    target_mb=$((target_mb / 256 * 256))
    (( target_mb >= 256 )) && echo "$target_mb" || echo 0
}

ensure_managed_swap() {
    # [可完全撤销] 仅创建 VPS-Tool 自己管理的 Swap，不覆盖用户现有 Swap。
    # [说明] Swap 使用磁盘空间模拟额外内存，可缓解内存峰值时的 OOM 风险，但速度明显低于真实 RAM，不能替代内存。
    # [安全保留] 创建后必须至少保留 1 GiB 根分区空间；单次最多创建 1 GiB。
    local requested_mb="${1:-1024}" disk_mb swap_mb create_mb fstab_line
    (( requested_mb >= 256 )) || requested_mb=256
    (( requested_mb > 1024 )) && requested_mb=1024
    (( requested_mb % 256 != 0 )) && requested_mb=$((requested_mb / 256 * 256))

    disk_mb=$(get_root_free_mb)
    swap_mb=$(current_swap_mb)
    create_mb=$requested_mb
    if (( swap_mb >= 1024 )); then
        echo -e "${GREEN}[状态]${PLAIN} 当前已有 ${swap_mb} MiB Swap，无需重复创建。"
        return 0
    fi
    if (( create_mb > 1024 - swap_mb )); then
        create_mb=$((1024 - swap_mb))
    fi
    if (( create_mb > disk_mb - 1024 )); then
        create_mb=$((disk_mb - 1024))
    fi
    create_mb=$((create_mb / 256 * 256))
    if (( create_mb < 256 )); then
        echo -e "${YELLOW}[提示]${PLAIN} 当前根分区可用空间 ${disk_mb} MiB，不足以在保留 1 GiB 安全余量后再创建至少 256 MiB Swap，因此不创建。"
        return 2
    fi

    if [[ -e "$VPS_TOOL_SWAP_PATH" ]] && ! is_owned "$VPS_TOOL_SWAP_PATH"; then
        echo -e "${YELLOW}[提示]${PLAIN} ${VPS_TOOL_SWAP_PATH} 已存在但不是本工具创建的，拒绝覆盖。"
        return 2
    fi
    mkdir -p "$(dirname "$VPS_TOOL_SWAP_PATH")"
    if [[ ! -e "$VPS_TOOL_SWAP_PATH" ]]; then
        if ! (fallocate -l "${create_mb}M" "$VPS_TOOL_SWAP_PATH" 2>/dev/null || dd if=/dev/zero of="$VPS_TOOL_SWAP_PATH" bs=1M count="$create_mb" status=none); then
            rm -f "$VPS_TOOL_SWAP_PATH"
            echo -e "${RED}[错误]${PLAIN} ${create_mb} MiB Swap 文件创建失败。"
            return 1
        fi
        if ! chmod 600 "$VPS_TOOL_SWAP_PATH" || ! mkswap "$VPS_TOOL_SWAP_PATH" >/dev/null; then
            rm -f "$VPS_TOOL_SWAP_PATH"
            echo -e "${RED}[错误]${PLAIN} Swap 初始化失败，已清理临时文件。"
            return 1
        fi
        if ! swapon "$VPS_TOOL_SWAP_PATH"; then
            rm -f "$VPS_TOOL_SWAP_PATH"
            echo -e "${RED}[错误]${PLAIN} swapon 失败，已自动回滚 Swap 文件。"
            return 1
        fi
        fstab_line="$VPS_TOOL_SWAP_PATH none swap sw 0 0"
        if ! grep -Fqx "$fstab_line" /etc/fstab; then
            if ! printf '%s\n' "$fstab_line" >> /etc/fstab; then
                swapoff "$VPS_TOOL_SWAP_PATH" >/dev/null 2>&1 || true
                rm -f "$VPS_TOOL_SWAP_PATH"
                echo -e "${RED}[错误]${PLAIN} 无法写入 /etc/fstab，Swap 已回滚。"
                return 1
            fi
        fi
        if ! mark_owned "$VPS_TOOL_SWAP_PATH" || ! state_set swap_created 1 || ! state_set swap_size_mb "$create_mb"; then
            swapoff "$VPS_TOOL_SWAP_PATH" >/dev/null 2>&1 || true
            sed -i "\#^${VPS_TOOL_SWAP_PATH}[[:space:]]#d" /etc/fstab 2>/dev/null || true
            rm -f "$VPS_TOOL_SWAP_PATH"
            unmark_owned "$VPS_TOOL_SWAP_PATH"
            state_unset swap_created
            state_unset swap_size_mb
            echo -e "${RED}[错误]${PLAIN} Swap 状态记录失败，已回滚创建的 Swap。"
            return 1
        fi
        log_action "[可完全撤销] 创建 VPS-Tool Swap：${create_mb} MiB，路径：${VPS_TOOL_SWAP_PATH}"
        echo -e "${GREEN}[完成]${PLAIN} 已增加 ${create_mb} MiB 工具专属 Swap，用于缓解低内存峰值压力。"
    fi
    return 0
}

ensure_managed_swap_1g() {
    # [兼容入口] 保留原函数名；新逻辑会根据磁盘余量和现有 Swap 动态决定实际创建大小。
    local recommended_mb
    recommended_mb=$(recommend_managed_swap_mb)
    (( recommended_mb > 0 )) || return 2
    ensure_managed_swap "$recommended_mb"
}

check_upgrade_resources() {
    # [安全提示] 这是运行前风险检查，不是发行版硬性最低配置；主要依据可用内存、现有 Swap 与根分区剩余空间判断。
    # [不可恢复] 系统升级本身仍属于不可逆软件包变更。
    local mem_mb disk_mb swap_mb recommended_mb
    mem_mb=$(get_mem_available_mb)
    disk_mb=$(get_root_free_mb)
    swap_mb=$(current_swap_mb)
    show_system_resource_summary

    # [安全底线] 根分区必须至少保留 1GiB；低于此值直接停止。
    if (( disk_mb < 1024 )); then
        echo -e "${RED}[资源过低]${PLAIN} 根分区可用空间仅 ${disk_mb} MiB，必须至少保留 1 GiB 才允许升级。"
        echo -e "${YELLOW}[建议]${PLAIN} 先清理磁盘或扩容，不会为了升级自动牺牲最后 1 GiB 空间。"
        return 1
    fi

    # [推荐] 可用内存达到 256 MiB 以上时，通常不需要额外准备 Swap。
    if (( mem_mb >= 256 )); then
        if (( disk_mb < 2048 )); then
            echo -e "${YELLOW}[资源提示]${PLAIN} 可用内存 ${mem_mb} MiB 尚可，但根分区仅剩 ${disk_mb} MiB。"
            confirm_safety_prompt "低磁盘空间下继续升级" "作用：继续更新系统；风险：升级缓存和软件包可能短时增加磁盘占用。" || return 1
        fi
        return 0
    fi

    # [建议] 128–255 MiB 可用内存属于低内存区；优先根据磁盘余量推荐 256/512/768/1024 MiB Swap。
    if (( mem_mb >= 128 )); then
        echo -e "${YELLOW}[资源提示]${PLAIN} 当前可用内存 ${mem_mb} MiB，低于推荐的 256 MiB。"
        if (( swap_mb < 1024 )); then
            recommended_mb=$(recommend_managed_swap_mb)
            echo -e "${BLUE}[说明]${PLAIN} Swap 是磁盘提供的虚拟内存，可在内存峰值时降低 OOM 风险，但速度低于真实 RAM，不能替代内存。"
            if (( recommended_mb > 0 )); then
                if confirm_safety_prompt "建议增加 ${recommended_mb} MiB Swap" "作用：为升级提供额外内存缓冲；创建后至少保留 1 GiB 根分区空间。"; then
                    ensure_managed_swap "$recommended_mb" || true
                else
                    echo -e "${YELLOW}[提示]${PLAIN} 未创建 Swap，将继续按低内存模式评估。"
                fi
            else
                echo -e "${YELLOW}[提示]${PLAIN} 当前磁盘余量不足以安全增加 Swap，将不会占用最后 1 GiB 空间。"
            fi
        else
            echo -e "${GREEN}[状态]${PLAIN} 已检测到 ${swap_mb} MiB Swap，可作为额外内存缓冲。"
        fi
        confirm_safety_prompt "低内存环境继续升级" "作用：继续更新系统；风险：内存峰值时仍可能变慢或失败。推荐可用内存达到 256 MiB 以上。" || return 1
        return 0
    fi

    # [谨慎阻止] 低于 128 MiB 可用内存时，优先建议根据磁盘余量增加 Swap；只有资源改善后才继续。
    echo -e "${RED}[资源过低]${PLAIN} 当前可用内存仅 ${mem_mb} MiB。"
    if (( swap_mb >= 1024 )); then
        echo -e "${GREEN}[状态]${PLAIN} 检测到 ${swap_mb} MiB Swap，但仍建议先释放内存。"
        confirm_safety_prompt "极低内存环境继续升级" "作用：继续更新系统；风险：仍存在 OOM 或升级失败风险。建议先将可用内存提升到 256 MiB 以上。" || return 1
        return 0
    fi
    recommended_mb=$(recommend_managed_swap_mb)
    if (( recommended_mb > 0 )); then
        echo -e "${YELLOW}[建议]${PLAIN} 当前可用内存极低，可先增加 ${recommended_mb} MiB Swap，再重新评估升级。"
        if confirm_safety_prompt "先创建 ${recommended_mb} MiB Swap" "作用：提供额外内存缓冲；创建后至少保留 1 GiB 根分区空间。"; then
            ensure_managed_swap "$recommended_mb" || return 1
            confirm_safety_prompt "创建 Swap 后继续升级" "作用：继续更新系统；风险：当前真实内存仍很低，升级过程可能变慢。" || return 1
            return 0
        fi
    fi
    echo -e "${YELLOW}[建议]${PLAIN} 请先释放内存或增加 Swap 后再升级。"
    return 1
}

sync_system_time() {
    echo -e "${BLUE}[同步中]${PLAIN} 正在自动校准网络时间..."
    if command_exists timedatectl; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
    fi
    if command_exists chronyc; then
        chronyc -a makestep >/dev/null 2>&1 || true
    elif systemctl cat chronyd.service >/dev/null 2>&1; then
        systemctl restart chronyd >/dev/null 2>&1 || true
    elif systemctl cat chrony.service >/dev/null 2>&1; then
        systemctl restart chrony >/dev/null 2>&1 || true
    fi
    log_action "[可撤销] 仅执行网络时间校准，不修改系统时区"
}

sys_full_upgrade() {
    check_os || return 1
    echo -e "${BLUE}[说明]${PLAIN} 更新系统软件，减少已知 Bug 与安全漏洞。"
    check_upgrade_resources || return 1
    confirm_safety_prompt "升级系统" "作用：更新系统软件与补丁。风险：属于不可逆软件包变更，资源不足时可能失败。" || { echo -e "${YELLOW}[提示]${PLAIN} 已取消完整系统升级。"; return 1; }
    case "${PKG_MANAGER}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get -y upgrade
            ;;
        dnf|yum)
            "${PKG_MANAGER}" -y upgrade
            ;;
    esac
    sync_system_time
    log_action "[不可逆] 全量更新系统软件包及依赖"
    echo -e "${GREEN}[成功]${PLAIN} 全系统基础软件包升级完成！"
}

sys_security_upgrade() {
    check_os || return 1
    echo -e "${BLUE}[说明]${PLAIN} 安装安全补丁，优先减少已知高危漏洞。"
    check_upgrade_resources || return 1
    case "${PKG_MANAGER}" in
        apt)
            # [不可逆更新] Debian/Ubuntu 当前不保证存在独立安全源；本分支实际执行 apt-get upgrade，可能同时升级 openssh-server/内核。
            confirm_safety_prompt "修补安全漏洞（Debian/Ubuntu 为全量升级）" "作用：更新系统软件与安全补丁。风险：可能包含 openssh-server/内核，属于不可逆变更；资源检查已通过。" || { echo -e "${YELLOW}[提示]${PLAIN} 已取消安全补丁升级。"; return 1; }
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get -y upgrade
            ;;
        dnf)
            confirm_safety_prompt "修补安全漏洞" "作用：更新安全补丁。风险：属于不可逆软件包变更，资源不足时可能失败。" || { echo -e "${YELLOW}[提示]${PLAIN} 已取消安全补丁升级。"; return 1; }
            dnf -y upgrade --security || dnf -y upgrade
            ;;
        yum)
            confirm_safety_prompt "修补安全漏洞" "作用：更新安全补丁。风险：属于不可逆软件包变更，资源不足时可能失败。" || { echo -e "${YELLOW}[提示]${PLAIN} 已取消安全补丁升级。"; return 1; }
            yum -y update --security || yum -y update
            ;;
    esac
    log_action "[不可逆] 修补系统 CVE 安全高危补丁"
    echo -e "${GREEN}[成功]${PLAIN} 安全补丁修补完毕！"
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
    local path id restore_failed=0
    [[ -d "$dir" ]] || return 1
    for file in "$dir"/*.path; do
        [[ -f "$file" ]] || continue
        id="${file##*/}"
        id="${id%.path}"
        path=$(cat "$file")
        if [[ -f "${dir}/${id}.missing" ]]; then
            if ! rm -f "$path"; then
                restore_failed=1
            fi
        elif [[ -f "${dir}/${id}.value" ]]; then
            if ! cat "${dir}/${id}.value" > "$path" 2>/dev/null; then
                restore_failed=1
            fi
        fi
    done
    if (( restore_failed )); then
        echo -e "${YELLOW}[警告]${PLAIN} 部分运行时参数恢复失败，原始记录已保留。"
        return 1
    fi
    rm -rf "$dir"
    return 0
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
        if port_in_use "$port" "$proto"; then
            :
        else
            local rc=$?
            case "$rc" in
                1)
                    echo "$port"
                    return 0
                    ;;
                *)
                    echo -e "${RED}[错误]${PLAIN} 无法可靠检查随机端口 ${port}/${proto}，已停止选取。" >&2
                    return 1
                    ;;
            esac
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
    validate_port_any "$port" || return 1
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
            if firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1; then
                return 0
            fi
            # [安全保留] 常见 HTTP/HTTPS/SSH service 已经放行时，不重复创建同端口规则；这些现有 service 不属于本工具所有。
            if [[ "$proto" == "tcp" && "$port" == "80" ]] && firewall-cmd --query-service=http --permanent >/dev/null 2>&1; then
                return 0
            fi
            if [[ "$proto" == "tcp" && "$port" == "443" ]] && firewall-cmd --query-service=https --permanent >/dev/null 2>&1; then
                return 0
            fi
            if [[ "$proto" == "tcp" && "$port" == "22" ]] && firewall-cmd --query-service=ssh --permanent >/dev/null 2>&1; then
                return 0
            fi
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null || return 1
            firewall-cmd --reload >/dev/null || return 1
            mkdir -p "${VPS_TOOL_STATE}/firewall"
            printf 'firewalld\n%s\n%s\n' "$port" "$proto" > "${VPS_TOOL_STATE}/firewall/${proto}_${port}.rule"
            ;;
        none)
            echo -e "${YELLOW}[提示]${PLAIN} 当前未检测到已启用的 UFW/firewalld，未自动开启防火墙。"
            return 0
            ;;
    esac
}

firewall_port_has_service_rule() {
    local backend="$1" port="$2" proto="$3" item rule source
    local -a entries=()
    validate_port_any "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    mapfile -t entries < <(firewall_open_port_entries "$backend" 2>/dev/null || true)
    for item in "${entries[@]}"; do
        rule="${item%%|*}"
        source="${item#*|}"
        if [[ "$rule" == "${port}/${proto}" && "$source" == *"服务:"* ]]; then
            return 0
        fi
    done
    return 1
}

firewall_remove_owned_rule() {
    local backend="$1" port="$2" proto="$3" rule_count
    case "$backend" in
        ufw)
            if firewall_port_has_service_rule "$backend" "$port" "$proto"; then
                echo -e "${YELLOW}[安全保留]${PLAIN} ${port}/${proto} 由 UFW service/profile 管理，拒绝按端口强删。"
                return 1
            fi
            rule_count=$(ufw status numbered 2>/dev/null | \
                sed -E 's/^[[:space:]]*\[[[:space:]]*[0-9]+[[:space:]]*\][[:space:]]*//' | \
                sed -E 's/[[:space:]]+\(v6\)$//' | \
                grep -Ec "^${port}/${proto}([[:space:]]|$)" || true)
            if (( rule_count == 0 )); then
                return 0
            fi
            if (( rule_count != 1 )); then
                echo -e "${YELLOW}[安全保留]${PLAIN} 检测到 ${port}/${proto} 存在多条防火墙规则，拒绝按端口强删，请手动处理。"
                return 1
            fi
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1
            ;;
        firewalld)
            if firewall_port_has_service_rule "$backend" "$port" "$proto"; then
                echo -e "${YELLOW}[安全保留]${PLAIN} ${port}/${proto} 由 firewalld service/profile 管理，拒绝按端口强删。"
                return 1
            fi
            if ! firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1; then
                return 0
            fi
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || return 1
            firewall-cmd --reload >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

firewall_remove_owned_rules() {
    local backend port proto file failed dir="${VPS_TOOL_STATE}/firewall"

    # 传入端口/协议时，只删除该条由工具记录的规则；不传参数则清理全部已记录规则。
    if [[ $# -eq 2 ]]; then
        port="$1"
        proto="$2"
        validate_port_any "$port" || return 1
        case "$proto" in tcp|udp) ;; *) return 1 ;; esac
        file="${dir}/${proto}_${port}.rule"
        [[ -f "$file" ]] || return 1
        backend=$(sed -n '1p' "$file")
        if firewall_remove_owned_rule "$backend" "$port" "$proto"; then
            rm -f "$file"
            return 0
        fi
        echo -e "${YELLOW}[警告]${PLAIN} 防火墙规则 ${port}/${proto} 未能删除，保留记录以便后续重试。"
        return 1
    fi

    [[ -d "$dir" ]] || return 1
    failed=0
    for file in "$dir"/*.rule; do
        [[ -f "$file" ]] || continue
        backend=$(sed -n '1p' "$file")
        port=$(sed -n '2p' "$file")
        proto=$(sed -n '3p' "$file")
        if firewall_remove_owned_rule "$backend" "$port" "$proto"; then
            rm -f "$file"
        else
            failed=1
            echo -e "${YELLOW}[警告]${PLAIN} 防火墙规则 ${port}/${proto} 未能删除，保留记录以便后续重试。"
        fi
    done
    return "$failed"
}

firewall_close_port_rule() {
    local port="$1" proto="$2" backend
    validate_port_any "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    backend=$(firewall_backend)
    case "$backend" in
        ufw)
            ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}([[:space:]]|$)" || return 2
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1
            ;;
        firewalld)
            firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1 || return 2
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || return 1
            firewall-cmd --reload >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

validate_port_any() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

