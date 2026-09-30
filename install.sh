#!/usr/bin/env bash
set -Eeuo pipefail

export LANG="${LANG:-C.UTF-8}"
CURRENT_VERSION="2.0.0"
GITHUB_USER="yesok6"
GITHUB_REPO="vps-tool"
BRANCH="main"
LOCAL_ROOT="/opt/vps-tool"
LOCAL_MODULES="${LOCAL_ROOT}/modules"
LOCAL_LIB="${LOCAL_ROOT}/lib"
SHORTCUT="/usr/local/bin/vps"
LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; PLAIN='\033[0m'

[[ ${EUID} -eq 0 ]] || { echo -e "${RED}[错误]${PLAIN} 请使用 root 权限运行。"; exit 1; }

mkdir -p "$LOG_DIR" "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB"
chmod 700 "$LOG_DIR" || true

log_action() {
    local action="${1:-}"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$action" >> "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

on_error() {
    local code=$?
    echo -e "${RED}[错误]${PLAIN} 操作失败（退出码 ${code}，位置 ${BASH_SOURCE[1]}:${BASH_LINENO[0]}）。"
    echo -e "${YELLOW}[提示]${PLAIN} 详细日志：${LOG_FILE}"
    log_action "[失败] exit=${code} source=${BASH_SOURCE[1]} line=${BASH_LINENO[0]}"
    return "$code"
}
trap on_error ERR

raw_base_url() {
    printf 'https://raw.githubusercontent.com/%s/%s/%s' "$GITHUB_USER" "$GITHUB_REPO" "$BRANCH"
}

install_dependencies() {
    local missing=()
    local cmd
    for cmd in curl jq bc ss openssl tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0

    echo -e "${BLUE}[准备中]${PLAIN} 安装运行依赖：${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y -q
        apt-get install -y -q curl jq bc iproute2 openssl tar
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq bc iproute openssl tar
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq bc iproute openssl tar
    else
        echo -e "${RED}[错误]${PLAIN} 未识别 apt/dnf/yum，无法自动安装依赖。"
        return 1
    fi

    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { echo -e "${RED}[错误]${PLAIN} 依赖仍缺失：$cmd"; return 1; }
    done
}

sync_bundle() (
    set -Eeuo pipefail
    local base temp file name remote_version
    base=$(raw_base_url)
    temp=$(mktemp -d /tmp/vps-tool-sync.XXXXXX)
    trap 'rm -rf "${temp}"' EXIT

    echo -e "${BLUE}[同步]${PLAIN} 下载并检查本地工具包..."
    download_one() {
        local relative="$1"
        local out="${temp}/${relative}"
        mkdir -p "$(dirname "$out")"
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 10 --max-time 120 \
            -o "$out" "${base}/${relative}?t=$(date +%s%N)"
    }

    download_one "install.sh"
    download_one "lib/common.sh"
    for name in security protocol optimize apps ip_test; do
        download_one "modules/${name}.sh"
    done

    for file in "${temp}/install.sh" "${temp}/lib/common.sh" "${temp}"/modules/*.sh; do
        bash -n "$file"
    done

    remote_version=$(grep '^CURRENT_VERSION=' "${temp}/install.sh" | head -n1 | cut -d'"' -f2 || true)
    [[ -n "$remote_version" ]] || { echo -e "${RED}[错误]${PLAIN} 下载的主程序缺少版本号。"; return 1; }

    mkdir -p "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB"
    install -m 755 "${temp}/install.sh" "${LOCAL_ROOT}/install.sh"
    install -m 755 "${temp}/lib/common.sh" "${LOCAL_LIB}/common.sh"
    for name in security protocol optimize apps ip_test; do
        install -m 755 "${temp}/modules/${name}.sh" "${LOCAL_MODULES}/${name}.sh"
    done
    printf '%s\n' "$remote_version" > "${LOCAL_ROOT}/VERSION"
    chmod 644 "${LOCAL_ROOT}/VERSION"
    log_action "[安装/更新] 本地工具包同步完成，版本=${remote_version}"
)

install_shortcut() {
    local tmp
    if [[ -e "$SHORTCUT" && ! -f "$SHORTCUT" ]]; then
        echo -e "${RED}[错误]${PLAIN} ${SHORTCUT} 已存在且不是普通文件，拒绝覆盖。"
        return 1
    fi
    if [[ -f "$SHORTCUT" ]] && ! grep -Eq '/opt/vps-tool/install.sh|yesok6/vps-tool/.*/install.sh' "$SHORTCUT"; then
        mkdir -p /etc/vps-tool/backups/shortcut
        [[ -f /etc/vps-tool/backups/shortcut/original ]] || cp -a "$SHORTCUT" /etc/vps-tool/backups/shortcut/original
        touch /etc/vps-tool/backups/shortcut/present
    fi

    tmp=$(mktemp)
    cat > "$tmp" <<'SH'
#!/usr/bin/env bash
exec /opt/vps-tool/install.sh "$@"
SH
    install -m 755 "$tmp" "$SHORTCUT"
    rm -f "$tmp"
}

check_version_update() {
    local base remote
    VERSION_TIPS="${GREEN}[当前版本 v${CURRENT_VERSION}]${PLAIN}"
    base=$(raw_base_url)
    remote=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 2 --max-time 5 \
        "${base}/install.sh?t=$(date +%s%N)" 2>/dev/null | grep '^CURRENT_VERSION=' | head -n1 | cut -d'"' -f2 || true)
    if [[ -n "$remote" && "$remote" != "$CURRENT_VERSION" ]]; then
        VERSION_TIPS="${YELLOW}[发现远端版本 v${remote}，可通过 8 更新]${PLAIN}"
    fi
}

load_module() {
    local module="$1"
    local file="${LOCAL_MODULES}/${module}.sh"
    [[ -f "$file" ]] || { sync_bundle || return 1; }
    [[ -f "$file" ]] || return 1
    if ! bash -n "$file"; then
        echo -e "${RED}[错误]${PLAIN} 模块语法检查失败：${module}"
        return 1
    fi
    bash "$file"
}

update_tool() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                 [在线更新]                        ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "当前版本：${YELLOW}v${CURRENT_VERSION}${PLAIN}"
    if ! sync_bundle; then
        echo -e "${RED}[错误]${PLAIN} 更新失败，当前已安装版本保持不变。"
        return 1
    fi
    echo -e "${GREEN}[成功]${PLAIN} 更新包已完成语法检查并安装到 ${LOCAL_ROOT}。"
    sleep 1
    exec "${LOCAL_ROOT}/install.sh"
}

uninstall_everything() {
    local answer
    clear
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "${RED}${BOLD}               [彻底清理与安全还原]               ${PLAIN}"
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo "只会撤销 VPS-Tool 自己记录的变更；不会删除用户原有 sing-box、swap、SSH 配置或第三方防火墙规则。"
    read -rp "确认继续？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    # Source modules without entering their menus; each module has a direct-execution guard.
    [[ -f "${LOCAL_LIB}/common.sh" ]] && source "${LOCAL_LIB}/common.sh"
    if [[ -f "${LOCAL_MODULES}/protocol.sh" ]]; then source "${LOCAL_MODULES}/protocol.sh"; uninstall_protocol_environment || true; fi
    if [[ -f "${LOCAL_MODULES}/optimize.sh" ]]; then source "${LOCAL_MODULES}/optimize.sh"; reset_all_optimizations || true; fi
    firewall_remove_owned_rules || true

    if [[ -f /etc/vps-tool/backups/shortcut/present && -f /etc/vps-tool/backups/shortcut/original ]]; then
        cp -a /etc/vps-tool/backups/shortcut/original "$SHORTCUT"
    else
        rm -f "$SHORTCUT"
    fi

    rm -rf "$LOCAL_ROOT"
    echo -e "${GREEN}[完成]${PLAIN} 已撤销工具自身记录的运行时变更。"
    echo -e "${YELLOW}[保留]${PLAIN} ${LOG_DIR} 下的备份与审计日志，便于追溯和手工恢复。"
    exit 0
}

main_menu() {
    while true; do
        clear
        check_version_update
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}             VPS 综合运维与网络工具箱              ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  版本: ${YELLOW}v${CURRENT_VERSION}${PLAIN} ${VERSION_TIPS}"
        echo -e "  本地安装目录: ${BLUE}${LOCAL_ROOT}${PLAIN}"
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 网络安全 / SSH / 防火墙"
        echo -e "  ${GREEN}2.${PLAIN} VLESS-Reality / Hysteria 2"
        echo -e "  ${GREEN}3.${PLAIN} 网络优化 / BBR / RPS-XPS"
        echo -e "  ${GREEN}4.${PLAIN} 一键部署流水线"
        echo -e "  ${GREEN}5.${PLAIN} IP 质量与网络诊断"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${BLUE}8.${PLAIN} 安全更新本地工具包"
        echo -e "  ${RED}9.${PLAIN} 撤销工具自己记录的变更并卸载"
        echo -e "  ${RED}0.${PLAIN} 退出"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-5,8,9]: " choice
        case "$choice" in
            1) load_module security || true; read -rp "按回车返回主菜单..." ;;
            2) load_module protocol || true; read -rp "按回车返回主菜单..." ;;
            3) load_module optimize || true; read -rp "按回车返回主菜单..." ;;
            4) load_module apps || true; read -rp "按回车返回主菜单..." ;;
            5) load_module ip_test || true; read -rp "按回车返回主菜单..." ;;
            8) update_tool || true ;;
            9) uninstall_everything ;;
            0) echo "已退出。"; return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

install_dependencies
sync_bundle
install_shortcut
main_menu
