#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================================
# 系统与高亮配色配置
# ========================================================
export LANG="${LANG:-C.UTF-8}"
CURRENT_VERSION="2.9.3"
# GitHub 仓库配置
GITHUB_USER="yesok6"
GITHUB_REPO="vps-tool"
BRANCH="main"
# 在线版本检查开关：设为 0 可关闭启动时的远端版本检查。
VPS_TOOL_VERSION_CHECK="${VPS_TOOL_VERSION_CHECK:-1}"
LOCAL_ROOT="/opt/vps-tool"
LOCAL_MODULES="${LOCAL_ROOT}/modules"
LOCAL_LIB="${LOCAL_ROOT}/lib"
SHORTCUT="/usr/local/bin/vps"
LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; PLAIN='\033[0m'

[[ ${EUID} -eq 0 ]] || { echo -e "${RED}[错误]${PLAIN} 请使用 root 权限运行。"; exit 1; }

mkdir -p "$LOG_DIR" "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB"
chmod 711 "$LOG_DIR" || true

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
    local base temp file name remote_version catalog_version
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
    download_one "protocol_catalog.json"

    for file in "${temp}/install.sh" "${temp}/lib/common.sh" "${temp}"/modules/*.sh; do
        bash -n "$file"
    done

    remote_version=$(grep '^CURRENT_VERSION=' "${temp}/install.sh" | head -n1 | cut -d'"' -f2 || true)
    [[ -n "$remote_version" ]] || { echo -e "${RED}[错误]${PLAIN} 下载的主程序缺少版本号。"; return 1; }
    [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
        echo -e "${RED}[错误]${PLAIN} 下载的主程序版本号格式异常：${remote_version}"
        return 1
    }

    if ! jq -e '(.schema_version | type == "number") and (.tool_version | type == "string") and (.protocols | type == "array") and all(.protocols[]; (.id | type == "string") and (.name | type == "string") and (.adapter_version | type == "number") and (.status | type == "string") and (.implemented | type == "boolean"))' "${temp}/protocol_catalog.json" >/dev/null 2>&1; then
        echo -e "${RED}[错误]${PLAIN} 下载到的 protocol_catalog.json 格式无效，已拒绝更新。"
        return 1
    fi
    catalog_version=$(jq -r '.tool_version' "${temp}/protocol_catalog.json")
    if [[ "$catalog_version" != "$remote_version" ]]; then
        echo -e "${YELLOW}[警告]${PLAIN} protocol_catalog.json 的 tool_version=${catalog_version} 与 install.sh 的 CURRENT_VERSION=${remote_version} 不一致，已以 install.sh 为准。"
        jq --arg v "$remote_version" '.tool_version = $v' "${temp}/protocol_catalog.json" > "${temp}/protocol_catalog.json.tmp"
        mv -f "${temp}/protocol_catalog.json.tmp" "${temp}/protocol_catalog.json"
    fi

    # 防止“版本号正确但关键 security.sh 实际仍是旧版”再次进入本机。
    # 不依赖中文注释文本，只检查关键函数是否存在，避免未来正常改文案导致误报。
    if ! grep -Eq '^firewall_port_has_service_rule[[:space:]]*\(\)' "${temp}/modules/security.sh"; then
        echo -e "${RED}[错误]${PLAIN} 下载到的 modules/security.sh 缺少关键防火墙归属函数，拒绝覆盖本机安全模块。"
        return 1
    fi

    mkdir -p "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB"
    install -m 755 "${temp}/install.sh" "${LOCAL_ROOT}/install.sh"
    install -m 755 "${temp}/lib/common.sh" "${LOCAL_LIB}/common.sh"
    for name in security protocol optimize apps ip_test; do
        install -m 755 "${temp}/modules/${name}.sh" "${LOCAL_MODULES}/${name}.sh"
    done
    install -m 644 "${temp}/protocol_catalog.json" "${LOCAL_ROOT}/protocol_catalog.json"
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

version_gt() {
    local a="$1" b="$2" a1 a2 a3 b1 b2 b3
    [[ "$a" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([.-][0-9A-Za-z.-]+)?$ ]] || return 2
    a1="${BASH_REMATCH[1]}"; a2="${BASH_REMATCH[2]}"; a3="${BASH_REMATCH[3]}"
    [[ "$b" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([.-][0-9A-Za-z.-]+)?$ ]] || return 2
    b1="${BASH_REMATCH[1]}"; b2="${BASH_REMATCH[2]}"; b3="${BASH_REMATCH[3]}"
    ((10#$a1 > 10#$b1)) && return 0
    ((10#$a1 < 10#$b1)) && return 1
    ((10#$a2 > 10#$b2)) && return 0
    ((10#$a2 < 10#$b2)) && return 1
    ((10#$a3 > 10#$b3))
}

check_version_update() {
    local base remote cache_file cache_age now
    local cache_ttl="${VPS_TOOL_VERSION_CACHE_TTL:-900}"
    VERSION_TIPS="${GREEN}[当前版本 v${CURRENT_VERSION}]${PLAIN}"
    case "${VPS_TOOL_VERSION_CHECK,,}" in
        0|false|no|off)
            VERSION_TIPS="${GREEN}[版本检查已关闭，当前 v${CURRENT_VERSION}]${PLAIN}"
            return 0
            ;;
    esac

    # [体验优化] 启动时不再每次都等待网络；默认 15 分钟内复用一次远端版本结果。
    cache_file="${LOG_DIR}/remote_version.cache"
    now=$(date +%s)
    remote=""
    if [[ -f "$cache_file" ]]; then
        cache_age=$(( now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if (( cache_age >= 0 && cache_age < cache_ttl )); then
            remote=$(cat "$cache_file" 2>/dev/null || true)
        fi
    fi

    if [[ -z "$remote" ]]; then
        base=$(raw_base_url)
        remote=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 1.2 --max-time 2 \
            "${base}/install.sh?t=$(date +%s%N)" 2>/dev/null | grep '^CURRENT_VERSION=' | head -n1 | cut -d'"' -f2 || true)
        if [[ -n "$remote" && "$remote" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
            printf '%s\n' "$remote" > "$cache_file" 2>/dev/null || true
            chmod 600 "$cache_file" 2>/dev/null || true
        fi
    fi

    if [[ -n "$remote" && "$remote" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        if version_gt "$remote" "$CURRENT_VERSION"; then
            VERSION_TIPS="${YELLOW}[发现远端版本 v${remote}，可通过 8 更新]${PLAIN}"
        else
            VERSION_TIPS="${GREEN}[当前已是 v${CURRENT_VERSION}，远端未高于当前版本]${PLAIN}"
        fi
    elif [[ -n "$remote" ]]; then
        log_action "[安全] 忽略格式异常的远端版本号：${remote}"
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
    local reexec=1
    [[ "${1:-}" == "--return" ]] && reexec=0
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                 [在线更新]                        ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "当前版本：${YELLOW}v${CURRENT_VERSION}${PLAIN}"

    local base remote
    base=$(raw_base_url)
    remote=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 3 --max-time 8 \
        "${base}/install.sh?t=$(date +%s%N)" 2>/dev/null | grep '^CURRENT_VERSION=' | head -n1 | cut -d'"' -f2 || true)
    if [[ -z "$remote" ]]; then
        echo -e "${RED}[错误]${PLAIN} 无法获取远端版本号，当前版本保持不变。"
        return 1
    fi
    if [[ ! "$remote" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        echo -e "${RED}[错误]${PLAIN} 远端版本号格式异常：${remote}"
        return 1
    fi
    if ! version_gt "$remote" "$CURRENT_VERSION"; then
        echo -e "${GREEN}[提示]${PLAIN} 当前已是最新版本或远端版本不高于当前版本：v${CURRENT_VERSION}。"
        return 0
    fi

    echo -e "${BLUE}[更新]${PLAIN} 发现新版本：v${remote}，开始同步。"
    if ! sync_bundle; then
        echo -e "${RED}[错误]${PLAIN} 更新失败，当前已安装版本保持不变。"
        return 1
    fi
    echo -e "${GREEN}[成功]${PLAIN} 更新包已完成语法检查并安装到 ${LOCAL_ROOT}。"
    if (( reexec )); then
        sleep 1
        exec "${LOCAL_ROOT}/install.sh"
    fi
    log_action "[在线更新] 由模块 2 触发更新后返回调用方"
}

uninstall_everything() {
    clear
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "${RED}${BOLD}        [系统清理与还原审计] 一键彻底卸载工具箱      ${PLAIN}"
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "说明: Linux 系统的软件升级与新内核属于单向变更，无法时光倒流。"
    echo -e "本脚本将按审计记录撤销本工具可回滚的应用与优化配置，并明确告知哪些属于安全基线/不可逆变更。"
    echo ""
    read -rp "您确定要开始执行还原清理吗？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}[提示] 操作已取消，系统未做任何变更。${PLAIN}"
        return 0
    fi

    echo -e "\n${BLUE}正在执行可撤销项的精准回滚...${PLAIN}"

    # 1. 撤销网络代理服务与核心（仅清理本工具创建并记录的环境）
    [[ -f "${LOCAL_MODULES}/protocol.sh" ]] && { source "${LOCAL_MODULES}/protocol.sh"; uninstall_protocol_environment || true; }

    # 2. 撤销内核与网络调优参数（第三方内核本身不自动卸载）
    [[ -f "${LOCAL_MODULES}/optimize.sh" ]] && { source "${LOCAL_MODULES}/optimize.sh"; reset_all_optimizations || true; }

    firewall_remove_owned_rules || true

    # 3. 移除快捷指令并恢复安装前已存在的 vps 文件
    if [[ -f /etc/vps-tool/backups/shortcut/present && -f /etc/vps-tool/backups/shortcut/original ]]; then
        cp -a /etc/vps-tool/backups/shortcut/original "$SHORTCUT"
    else
        rm -f "$SHORTCUT"
    fi

    echo -e "\n${GREEN}${BOLD}====================================================${PLAIN}"
    echo -e "${GREEN}${BOLD}               系统清理与变更恢复报告               ${PLAIN}"
    echo -e "${GREEN}${BOLD}====================================================${PLAIN}"
    echo -e "\n${GREEN}【已成功清除并恢复的项目】(仅限工具有记录的变更):${PLAIN}"
    echo -e "  ${GREEN}✔${PLAIN} 工具自己创建并记录的协议服务、配置与临时 Swap 已按状态清理（失败项会在上方提示）"
    echo -e "  ${GREEN}✔${PLAIN} 已记录的网络优化参数、RPS/XPS、IPv4 优先与网卡队列尝试恢复为修改前状态"
    echo -e "  ${GREEN}✔${PLAIN} 终端快捷命令 'vps' 及测试产生的工具临时缓存已清理"

    echo -e "\n${YELLOW}【保留且无法/不建议恢复的项目】(底层安全基线):${PLAIN}"
    echo -e "  ${YELLOW}* 系统软件与安全补丁${PLAIN}: 已升级的软件包属于单向不可逆更新，本工具不会自动降级"
    echo -e "  ${YELLOW}* 已安装的 BBRv3 内核${PLAIN}: 内核属于底层不可逆变更，不通过一键卸载自动删除"
    echo -e "  ${YELLOW}* SSH 端口与密钥登录${PLAIN}: 为防止您断联，SSH 安全配置作为部分可撤销/安全保留项不会由一键卸载强制回滚"
    echo -e "  ${YELLOW}* UFW / firewalld 及云平台安全组${PLAIN}: 仅移除本工具明确记录的规则，不强制关闭第三方/用户已有防火墙策略"
    echo -e "  ${YELLOW}* 已导出到其他设备的节点链接/凭据${PLAIN}: 本工具无法撤回已经离开服务器的副本"

    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    echo -e "审计记录保存在: ${CYAN}${LOG_FILE}${PLAIN}"
    echo -e "${GREEN}${BOLD}====================================================${PLAIN}\n"
    rm -rf "$LOCAL_ROOT"
    exit 0
}


main_menu() {
    while true; do
        clear
        check_version_update
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}             VPS 综合运维与网络代理工具箱           ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  当前版本: ${YELLOW}v${CURRENT_VERSION}${PLAIN} ${VERSION_TIPS}"
        echo -e "  提示: 以后可随时在终端输入 ${GREEN}vps${PLAIN} 直接唤起此工具箱"
        echo -e "  标注说明: ${GREEN}[可完全撤销]${PLAIN} 本机配置可完整回滚 | ${YELLOW}[部分可撤销]${PLAIN} 只能恢复工具记录的部分变更 | ${RED}[不可逆]${PLAIN} 无法由工具自动恢复"
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 网络安全 (系统加固/SSH/防火墙)      ${YELLOW}[部分可撤销/安全保留]${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 协议搭建 (VLESS-Reality/Hy2)         ${GREEN}[本机配置可完全撤销]${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 网络优化 (生产级调优/多核中断/BBR)   ${GREEN}[参数可完全撤销/内核变更不可逆]${PLAIN}"
        echo -e "  ${GREEN}4.${PLAIN} 一键安装 (全自动综合流水线交钥匙)    ${CYAN}[混合执行]${PLAIN}"
        echo -e "  ${GREEN}5.${PLAIN} IP 质量测试 (欺诈分/流媒体/回程路由)  ${GREEN}[即用即焚/第三方残留不保证]${PLAIN}"
        echo -e "  ----------------------------------------------------"
        echo -e "  ${BLUE}8.${PLAIN} 检查并一键更新脚本到最新版          ${GREEN}[在线热更新]${PLAIN}"
        echo -e "  ${RED}9.${PLAIN} 一键彻底清理与还原系统 (按记录恢复并出具报告)"
        echo -e "  ${RED}0.${PLAIN} 退出工具箱"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请输入选项 [0-5, 8, 9]: " choice
        case "$choice" in
            1) load_module security || true; read -rp "按回车键返回主菜单..." ;;
            2) load_module protocol || true; read -rp "按回车键返回主菜单..." ;;
            3) load_module optimize || true; read -rp "按回车键返回主菜单..." ;;
            4) load_module apps || true; read -rp "按回车键返回主菜单..." ;;
            5) load_module ip_test || true; read -rp "按回车键返回主菜单..." ;;
            8) update_tool || true ;;
            9) uninstall_everything ;;
            0) echo -e "${GREEN}已退出。${PLAIN}"; return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1 ;;
        esac
    done
}


install_dependencies
if [[ "${1:-}" == "--update-return" ]]; then
    update_tool --return
    exit $?
fi
current_script_path=$(readlink -f -- "${BASH_SOURCE[0]}") || current_script_path="${BASH_SOURCE[0]}"
local_install_path=$(readlink -f -- "${LOCAL_ROOT}/install.sh") || local_install_path="${LOCAL_ROOT}/install.sh"
if [[ "$current_script_path" != "$local_install_path" ]]; then
    # 首次通过网络脚本启动时同步完整本地工具包；已安装版本启动时不再静默更新。
    sync_bundle
fi
install_shortcut
main_menu
