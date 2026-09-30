#!/usr/bin/env bash

# ========================================================
# 系统与高亮配色配置
# ========================================================
export LANG=en_US.UTF-8
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

# 当前本地版本号
CURRENT_VERSION="1.0.1"

# GitHub 仓库配置
GITHUB_USER="yesok6"
GITHUB_REPO="vps-tool"
BRANCH="main"

LOG_DIR="/etc/vps-tool"
LOG_FILE="${LOG_DIR}/install.log"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}[错误]${PLAIN} 请使用 root 权限运行此脚本！" && exit 1

# 统一操作审计日志记录器
log_action() {
    local action="$1"
    mkdir -p "${LOG_DIR}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${action}" >> "${LOG_FILE}"
}

# 基础必备依赖检查与安装
check_deps() {
    local need_install=0
    for cmd in curl wget ss bc jq; do
        if ! command -v "$cmd" &>/dev/null; then
            need_install=1
            break
        fi
    done

    if [ "$need_install" -eq 1 ]; then
        echo -e "${BLUE}[准备中]${PLAIN} 正在检查并装载核心依赖组件..."
        if command -v apt-get &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y -q &>/dev/null
            apt-get install -y -q curl wget iproute2 bc jq &>/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y curl wget iproute bc jq &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y curl wget iproute bc jq &>/dev/null
        fi
    fi
}

# 注册本地快捷命令 (输入 vps 即可直接呼出主菜单)
install_shortcut() {
    local shortcut_path="/usr/local/bin/vps"
    cat <<EOF > "$shortcut_path"
#!/usr/bin/env bash
bash <(curl -fsSL "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/install.sh?t=\$(date +%s)")
EOF
    chmod +x "$shortcut_path"
}

# 智能版本比对检查器
check_version_update() {
    local remote_version
    remote_version=$(curl -s4m 1.5 "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/install.sh?t=$(date +%s)" | grep "^CURRENT_VERSION=" | head -n1 | cut -d'"' -f2)
    
    if [[ -n "$remote_version" && "$remote_version" != "$CURRENT_VERSION" ]]; then
        VERSION_TIPS="${RED}${BOLD}[发现新版本 v${remote_version}！建议按 8 更新]${PLAIN}"
    else
        VERSION_TIPS="${GREEN}[当前已是最新版]${PLAIN}"
    fi
}

# 模块动态下载调度器
load_module() {
    local module_name="$1"
    local timestamp
    timestamp=$(date +%s)
    local raw_url="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/modules/${module_name}.sh?t=${timestamp}"
    local mirror_url="https://ghproxy.net/https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/modules/${module_name}.sh?t=${timestamp}"
    
    echo -e "${BLUE}[信息]${PLAIN} 正在调度 ${module_name} 模块..."
    
    if curl -s --connect-timeout 4 "$raw_url" | head -n1 | grep -q "bash"; then
        bash <(curl -fsSL "$raw_url")
    else
        echo -e "${YELLOW}[提示]${PLAIN} 正在通过加速镜像加载模块..."
        bash <(curl -fsSL "$mirror_url")
    fi
    
    echo ""
    read -rp "按回车键返回主菜单..."
    main_menu
}

# 选项 8: 一键更新工具箱代码
update_tool() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}            [在线更新] 检查并更新工具箱源码         ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "当前本地运行版本: ${YELLOW}v${CURRENT_VERSION}${PLAIN}"
    echo -e "${BLUE}[检查中]${PLAIN} 正在连接 GitHub 仓库获取最新版本信息..."

    local timestamp
    timestamp=$(date +%s)
    local raw_entry="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/install.sh?t=${timestamp}"
    local mirror_entry="https://ghproxy.net/https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/install.sh?t=${timestamp}"
    
    local remote_version
    remote_version=$(curl -fsSL --connect-timeout 5 "$raw_entry" 2>/dev/null | grep "^CURRENT_VERSION=" | head -n1 | cut -d'"' -f2)
    
    if [[ -z "$remote_version" ]]; then
        remote_version=$(curl -fsSL --connect-timeout 5 "$mirror_entry" 2>/dev/null | grep "^CURRENT_VERSION=" | head -n1 | cut -d'"' -f2)
    fi

    if [[ -z "$remote_version" ]]; then
        echo -e "${RED}[错误]${PLAIN} 无法连接至 GitHub 获取更新，请检查 VPS 网络！"
        return
    fi

    echo -e "云端最新版本: ${GREEN}v${remote_version}${PLAIN}"

    if [[ "$remote_version" == "$CURRENT_VERSION" ]]; then
        echo -e "\n${GREEN}[提示] 您当前的脚本已经是最新版，无需重复更新！${PLAIN}"
        read -rp "是否依然强制重新拉取最新代码？[y/N]: " force_update
        [[ ! "$force_update" =~ ^[Yy]$ ]] && return
    fi

    echo -e "\n${BLUE}[更新中]${PLAIN} 正在刷新本地快捷命令并拉取最新主程序..."
    install_shortcut
    log_action "[更新] 成功将脚本从 v${CURRENT_VERSION} 更新至 v${remote_version}"
    echo -e "${GREEN}[成功]${PLAIN} 脚本更新成功！正在自动热重启进入新版本..."
    sleep 1

    exec bash <(curl -fsSL "$raw_entry")
}

# 选项 9: 一键彻底清理与系统还原
uninstall_everything() {
    clear
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "${RED}${BOLD}        [系统清理与还原审计] 一键彻底卸载工具箱      ${PLAIN}"
    echo -e "${RED}${BOLD}====================================================${PLAIN}"
    echo -e "说明: Linux 系统的软件升级与新内核属于单向变更，无法时光倒流。"
    echo -e "本脚本将精准撤销应用与优化配置，并明确告知哪些属于安全基线保留项。"
    echo ""
    read -rp "您确定要开始执行还原清理吗？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}[提示] 操作已取消，系统未做任何变更。${PLAIN}"
        return
    fi

    echo -e "\n${BLUE}正在执行可撤销项的精准回滚...${PLAIN}"

    # 1. 撤销网络代理服务与核心
    systemctl stop sing-box &>/dev/null
    systemctl disable sing-box &>/dev/null
    rm -f /etc/systemd/system/sing-box.service
    rm -rf /etc/sing-box
    rm -f /usr/local/bin/sing-box
    systemctl daemon-reload

    # 2. 撤销内核与网络调优参数
    rm -f /etc/sysctl.d/99-vps-optimizer.conf /etc/sysctl.d/99-bbr.conf
    rm -f /etc/security/limits.d/99-nofile.conf
    sed -i '/precedence ::ffff:0:0\/96  100/d' /etc/gai.conf 2>/dev/null

    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    if [[ -n "$iface" ]]; then
        ip link set dev "$iface" txqueuelen 1000 2>/dev/null
    fi
    sed -i '/rps_cpus/d' /etc/rc.local 2>/dev/null
    sed -i '/xps_cpus/d' /etc/rc.local 2>/dev/null
    sysctl --system &>/dev/null

    # 3. 卸载临时创建的 Swap 虚拟内存
    if grep -q "/swapfile" /etc/fstab 2>/dev/null; then
        swapoff /swapfile 2>/dev/null
        sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null
        rm -f /swapfile
    fi

    # 4. 清理测速缓存与测试残留
    rm -rf /tmp/vps_ip_audit_* /tmp/sni_test.txt /tmp/auto_sni.txt /tmp/bbrv3_install
    rm -f /tmp/check.sh /tmp/RegionRestrictionCheck* /tmp/backtrace*

    # 5. 移除快捷指令
    rm -f /usr/local/bin/vps

    # 6. 生成审计清单
    clear
    echo -e "${GREEN}${BOLD}====================================================${PLAIN}"
    echo -e "${GREEN}${BOLD}               系统清理与变更恢复报告               ${PLAIN}"
    echo -e "${GREEN}${BOLD}====================================================${PLAIN}"
    
    echo -e "\n${GREEN}【已成功清除并恢复的项目】(配置已归位):${PLAIN}"
    echo -e "  ${GREEN}✔${PLAIN} 代理服务已停用，核心程序及密钥节点配置文件已彻底抹除"
    echo -e "  ${GREEN}✔${PLAIN} TCP 读写缓冲区、文件并发句柄已恢复为系统初始默认值"
    echo -e "  ${GREEN}✔${PLAIN} 网卡发送队列已从 100000 恢复为标准 1000"
    echo -e "  ${GREEN}✔${PLAIN} 临时生成的 1GB Swap 交换文件已卸载并释放磁盘空间"
    echo -e "  ${GREEN}✔${PLAIN} 终端快捷命令 'vps' 及测试产生的临时缓存已全量删除"

    echo -e "\n${YELLOW}【保留且无法/不建议恢复的项目】(底层安全基线):${PLAIN}"
    echo -e "  ${YELLOW}* 系统软件与安全补丁${PLAIN}: 已升级的软件包属于单向不可逆更新（降级会导致系统依赖崩坏，保留补丁机器更安全）"
    echo -e "  ${YELLOW}* 已安装的 BBRv3 内核${PLAIN}: 内核镜像文件依然保留在系统中，但相关调优参数已撤销"
    echo -e "  ${YELLOW}* SSH 端口与密钥登录${PLAIN}: 为防止您断联被锁在外面，当前生效的 SSH 端口与密钥权限未做变动"
    echo -e "  ${YELLOW}* UFW 本地防火墙状态${PLAIN}: 为保障基础防御，防火墙未被强制关闭，您可执行 'ufw status' 自行查看"

    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    echo -e "历史操作审计记录已归档保存在: ${CYAN}${LOG_FILE}${PLAIN}"
    echo -e "${GREEN}${BOLD}====================================================${PLAIN}\n"
    exit 0
}

# 主菜单界面
main_menu() {
    clear
    check_version_update
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}             VPS 综合运维与网络代理工具箱           ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "  当前版本: ${YELLOW}v${CURRENT_VERSION}${PLAIN} ${VERSION_TIPS}"
    echo -e "  提示: 以后可随时在终端输入 ${GREEN}vps${PLAIN} 直接唤起此工具箱"
    echo -e "  标注说明: ${GREEN}[可完全撤销]${PLAIN} 卸载时复原 | ${YELLOW}[底层/安全保留]${PLAIN} 卸载时保留"
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 网络安全 (系统加固/SSH/防火墙)      ${YELLOW}[底层/安全保留]${PLAIN}"
    echo -e "  ${GREEN}2.${PLAIN} 协议搭建 (VLESS-Reality/Hy2)         ${GREEN}[可完全撤销]${PLAIN}"
    echo -e "  ${GREEN}3.${PLAIN} 网络优化 (生产级调优/多核中断/BBR)   ${GREEN}[参数可撤销/内核保留]${PLAIN}"
    echo -e "  ${GREEN}4.${PLAIN} 一键安装 (全自动综合流水线交钥匙)    ${CYAN}[混合执行]${PLAIN}"
    echo -e "  ${GREEN}5.${PLAIN} IP 质量测试 (欺诈分/流媒体/回程路由)  ${GREEN}[即用即焚/无残留]${PLAIN}"
    echo -e "  ----------------------------------------------------"
    echo -e "  ${BLUE}8.${PLAIN} 检查并一键更新脚本到最新版          ${GREEN}[在线热更新]${PLAIN}"
    echo -e "  ${RED}9.${PLAIN} 一键彻底清理与还原系统 (纯净卸载并出具报告)"
    echo -e "  ${RED}0.${PLAIN} 退出工具箱"
    echo -e "${CYAN}====================================================${PLAIN}"
    
    read -rp "请输入选项 [0-5, 8, 9]: " choice
    case "$choice" in
        1) load_module "security" ;;
        2) load_module "protocol" ;;
        3) load_module "optimize" ;;
        4) load_module "apps" ;;
        5) load_module "ip_test" ;;
        8) update_tool ;;
        9) uninstall_everything ;;
        0) echo -e "${GREEN}已退出。${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}[错误]${PLAIN} 请输入有效选项！"; sleep 1; main_menu ;;
    esac
}

check_deps
install_shortcut
main_menu
