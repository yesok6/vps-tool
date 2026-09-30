#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

CONF_DIR="/etc/vps-tool/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
NODE_INFO_FILE="${CONF_DIR}/node_info.txt"
SERVICE_UNIT="vps-tool-sing-box.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_UNIT}"
SINGBOX_BIN=""

resolve_singbox() {
    if [[ -n "${SINGBOX_BIN:-}" && -x "$SINGBOX_BIN" ]]; then return 0; fi
    if command_exists sing-box; then
        SINGBOX_BIN="$(command -v sing-box)"
        return 0
    fi
    if [[ -x "${VPS_TOOL_ROOT}/bin/sing-box" ]]; then
        SINGBOX_BIN="${VPS_TOOL_ROOT}/bin/sing-box"
        return 0
    fi
    return 1
}

latest_singbox_version() {
    local tag
    tag=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    [[ -n "$tag" && "$tag" != "null" ]] || return 1
    printf '%s' "${tag#v}"
}

fetch_checksums_file() {
    local version="$1" out="$2" name url
    for name in sha256sums.txt sha256sums SHA256SUMS checksums.txt; do
        url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${name}"
        if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 -o "$out" "$url"; then
            [[ -s "$out" ]] && return 0
        fi
    done
    return 1
}

install_singbox() {
    if resolve_singbox; then
        echo -e "${GREEN}[环境]${PLAIN} 使用系统已有 sing-box：${SINGBOX_BIN}"
    else
        local version arch asset_url asset checksum_file tmp
        case "$(uname -m)" in
            x86_64) arch=amd64 ;;
            aarch64) arch=arm64 ;;
            *) echo -e "${RED}[错误]${PLAIN} 不支持的 CPU 架构。"; return 1 ;;
        esac
        version="${SINGBOX_VERSION:-}"
        [[ -n "$version" ]] || version=$(latest_singbox_version)
        asset="sing-box-${version}-linux-${arch}.tar.gz"
        asset_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"
        tmp=$(make_temp_dir singbox-install)
        trap 'rm -rf "${tmp}"' EXIT

        echo -e "${BLUE}[环境]${PLAIN} 下载 sing-box v${version} 并校验 SHA-256..."
        download_https "$asset_url" "${tmp}/${asset}"
        fetch_checksums_file "$version" "${tmp}/checksums.txt" || {
            echo -e "${RED}[错误]${PLAIN} 无法取得官方校验文件，拒绝安装未经校验的二进制。"
            return 1
        }
        checksum=$(grep -E "[[:space:]]${asset}$" "${tmp}/checksums.txt" | awk '{print $1}' | head -n1)
        [[ "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]] || {
            echo -e "${RED}[错误]${PLAIN} 校验文件中找不到 ${asset} 的 SHA-256。"
            return 1
        }
        echo "${checksum}  ${tmp}/${asset}" | sha256sum -c - >/dev/null

        mkdir -p "${VPS_TOOL_ROOT}/bin"
        tar -xzf "${tmp}/${asset}" -C "$tmp"
        local extracted
        extracted=$(find "$tmp" -type f -name sing-box -perm -u=x | head -n1)
        [[ -n "$extracted" ]] || { echo -e "${RED}[错误]${PLAIN} 压缩包中没有找到 sing-box。"; return 1; }
        install -m 0755 "$extracted" "${VPS_TOOL_ROOT}/bin/sing-box"
        mark_owned "${VPS_TOOL_ROOT}/bin/sing-box"
        SINGBOX_BIN="${VPS_TOOL_ROOT}/bin/sing-box"
        rm -rf "$tmp"
        trap - EXIT
        log_action "[可撤销] 安装经 SHA-256 校验的 sing-box v${version}"
    fi

    "$SINGBOX_BIN" version >/dev/null 2>&1 || { echo -e "${RED}[错误]${PLAIN} sing-box 二进制无法运行。"; return 1; }
    ensure_service_user

    mkdir -p "$CONF_DIR"
    chown root:vps-tool "$CONF_DIR"
    chmod 0750 "$CONF_DIR"

    if [[ -e "$SERVICE_FILE" ]] && ! is_owned "$SERVICE_FILE"; then
        echo -e "${RED}[错误]${PLAIN} ${SERVICE_FILE} 已存在但不是本工具创建的，拒绝覆盖。"
        return 1
    fi
    backup_file_once "$SERVICE_FILE" protocol_service_unit
    cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=VPS-Tool sing-box service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vps-tool
Group=vps-tool
ExecStart=${SINGBOX_BIN} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadOnlyPaths=/etc/vps-tool/sing-box

[Install]
WantedBy=multi-user.target
EOF2
chmod 0644 "$SERVICE_FILE"
mark_owned "$SERVICE_FILE"

after_service_install=1
systemctl daemon-reload
systemctl enable "$SERVICE_UNIT" >/dev/null
}

get_sys_ip() {
    local ip4 ip6
    ip4=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)
    [[ -n "$ip4" ]] && { echo "$ip4"; return 0; }
    ip6=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 4 --max-time 8 https://api6.ipify.org 2>/dev/null || true)
    [[ -n "$ip6" ]] && { echo "[$ip6]"; return 0; }
    return 1
}

get_random_protocol_port() {
    random_free_port "$1"
}

validate_user_port() {
    local port="$1"
    validate_port "$port"
}

get_best_sni() {
    local candidates=(gateway.icloud.com itunes.apple.com addons.mozilla.org swdist.apple.com www.microsoft.com dl.google.com images.unsplash.com)
    local tmp domain rtt ms best=""
    tmp=$(make_temp_dir sni)
    for domain in "${candidates[@]}"; do
        (
            rtt=$(curl -o /dev/null -sS -w '%{time_connect}' --connect-timeout 2 --max-time 4 "https://${domain}" 2>/dev/null || true)
            [[ -n "$rtt" && "$rtt" != "0.000000" ]] || exit 0
            ms=$(awk -v v="$rtt" 'BEGIN {printf "%d", v*1000}')
            if (( ms > 0 )); then
                printf '%s %s\n' "$ms" "$domain" >> "${tmp}/results"
            fi
            exit 0
        ) &
    done
    wait
    if [[ -s "${tmp}/results" ]]; then best=$(sort -n "${tmp}/results" | head -n1 | awk '{print $2}'); fi
    rm -rf "$tmp"
    echo "${best:-addons.mozilla.org}"
}

validate_singbox_config() {
    resolve_singbox || return 1
    "$SINGBOX_BIN" check -c "$CONF_FILE"
}

ensure_conf_permissions() {
    mkdir -p "$CONF_DIR"
    chown root:vps-tool "$CONF_DIR"
    chmod 0750 "$CONF_DIR"
    [[ -f "$CONF_FILE" ]] && { chown root:vps-tool "$CONF_FILE"; chmod 0640 "$CONF_FILE"; }
    [[ -f "$NODE_INFO_FILE" ]] && { chown root:root "$NODE_INFO_FILE"; chmod 0600 "$NODE_INFO_FILE"; }
}

service_was_running() {
    systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null
}

restart_service_and_verify() {
    systemctl daemon-reload
    if ! systemctl restart "$SERVICE_UNIT"; then
        return 1
    fi
    sleep 1
    systemctl is-active --quiet "$SERVICE_UNIT"
}

write_node_info() {
    local content="$1"
    umask 077
    printf '%s\n' "$content" > "$NODE_INFO_FILE"
    chown root:root "$NODE_INFO_FILE"
    chmod 0600 "$NODE_INFO_FILE"
}

firewall_note() {
    local port="$1" proto="$2"
    local backend
    backend=$(firewall_backend)
    if [[ "$backend" == "none" ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 未检测到活动主机防火墙；请检查云安全组/边界防火墙。"
    else
        firewall_allow "$port" "$proto" || echo -e "${YELLOW}[提示]${PLAIN} 防火墙放行规则添加失败，请手工检查。"
    fi
}

deploy_vless_reality() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}              [VLESS + Reality]                    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port sni uuid key_pair private_key public_key short_id server_ip
    default_port=$(get_random_protocol_port tcp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 TCP 端口。"; return 1; }
    read -rp "端口 [回车使用 ${default_port}，范围 1024-65535]: " input_port
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" tcp && { echo -e "${RED}[错误]${PLAIN} TCP 端口已被占用。"; return 1; }

    install_singbox || return 1
    ensure_conf_permissions
    backup_file_once "$CONF_FILE" protocol_config
    backup_file_once "$NODE_INFO_FILE" protocol_node_info

    sni=$(get_best_sni)
    uuid=$("$SINGBOX_BIN" generate uuid)
    key_pair=$("$SINGBOX_BIN" generate reality-keypair)
    private_key=$(awk '/PrivateKey/ {print $2; exit}' <<< "$key_pair")
    public_key=$(awk '/PublicKey/ {print $2; exit}' <<< "$key_pair")
    short_id=$("$SINGBOX_BIN" generate rand --hex 8)
    [[ -n "$uuid" && -n "$private_key" && -n "$public_key" && -n "$short_id" ]] || { echo -e "${RED}[错误]${PLAIN} Reality 密钥生成失败。"; return 1; }

    server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then
        read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip
    fi
    [[ -n "$server_ip" ]] || return 1

    umask 077
    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{log:{level:"warn",timestamp:true},inbounds:[{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private_key,short_id:[$short_id]}}}],outbounds:[{type:"direct",tag:"direct"}]}' > "$CONF_FILE"
    ensure_conf_permissions

    validate_singbox_config || { restore_file_backup "$CONF_FILE" protocol_config || true; return 1; }
    if ! restart_service_and_verify; then
        restore_file_backup "$CONF_FILE" protocol_config || rm -f "$CONF_FILE"
        systemctl restart "$SERVICE_UNIT" >/dev/null 2>&1 || true
        echo -e "${RED}[错误]${PLAIN} sing-box 启动失败，已恢复原配置。"
        return 1
    fi
    firewall_note "$port" tcp

    local vless_link
    vless_link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VPS-Tool-Reality"
    write_node_info "===================== 节点连接信息 =====================
协议方案: VLESS + Vision + Reality
服务器地址: ${server_ip}
连接端口: ${port}
用户 ID (UUID): ${uuid}
流控: xtls-rprx-vision
SNI: ${sni}
PublicKey: ${public_key}
ShortId: ${short_id}

【一键导入分享链接】:
${vless_link}
========================================================"
    log_action "[可撤销] VLESS-Reality 端口=${port} SNI=${sni}"
    clear
    cat "$NODE_INFO_FILE"
    echo -e "\n${GREEN}[成功]${PLAIN} 部署完成。敏感节点信息已限制为 root 可读。"
}

deploy_hysteria2() {
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                [Hysteria 2]                       ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port password cert_file key_file server_ip sni="bing.com"
    default_port=$(get_random_protocol_port udp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 UDP 端口。"; return 1; }
    read -rp "UDP 端口 [回车使用 ${default_port}，范围 1024-65535]: " input_port
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" udp && { echo -e "${RED}[错误]${PLAIN} UDP 端口已被占用。"; return 1; }

    install_singbox || return 1
    ensure_conf_permissions
    backup_file_once "$CONF_FILE" protocol_config
    backup_file_once "$NODE_INFO_FILE" protocol_node_info

    password=$("$SINGBOX_BIN" generate rand --hex 16)
    cert_file="${CONF_DIR}/hy2_cert.pem"
    key_file="${CONF_DIR}/hy2_key.pem"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni}" >/dev/null 2>&1
    chmod 0640 "$key_file"
    chmod 0644 "$cert_file"
    chown root:vps-tool "$key_file" "$cert_file"

    server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip; fi
    [[ -n "$server_ip" ]] || return 1

    umask 077
    jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        --arg cert "$cert_file" \
        --arg key "$key_file" \
        '{log:{level:"warn",timestamp:true},inbounds:[{type:"hysteria2",tag:"hy2-in",listen:"::",listen_port:$port,users:[{password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}]}' > "$CONF_FILE"
    ensure_conf_permissions
    validate_singbox_config || { restore_file_backup "$CONF_FILE" protocol_config || true; return 1; }

    if ! restart_service_and_verify; then
        restore_file_backup "$CONF_FILE" protocol_config || rm -f "$CONF_FILE"
        rm -f "$cert_file" "$key_file"
        systemctl restart "$SERVICE_UNIT" >/dev/null 2>&1 || true
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 启动失败，已恢复原配置。"
        return 1
    fi
    firewall_note "$port" udp

    local hy2_link
    hy2_link="hysteria2://${password}@${server_ip}:${port}/?insecure=1&sni=${sni}#VPS-Tool-Hysteria2"
    write_node_info "===================== 节点连接信息 =====================
协议方案: Hysteria 2
服务器地址: ${server_ip}
UDP 端口: ${port}
连接密码: ${password}
SNI: ${sni}
说明: 使用本工具生成的自签名证书，因此客户端链接包含 insecure=1。

【一键导入分享链接】:
${hy2_link}
========================================================"
    log_action "[可撤销] Hysteria2 UDP=${port}"
    clear
    cat "$NODE_INFO_FILE"
    echo -e "\n${GREEN}[成功]${PLAIN} 部署完成。"
}

uninstall_protocol_environment() {
    echo -e "${BLUE}[协议清理]${PLAIN} 仅清理 VPS-Tool 自己的协议环境。"
    if systemctl is-enabled --quiet "$SERVICE_UNIT" 2>/dev/null; then systemctl disable "$SERVICE_UNIT" >/dev/null 2>&1 || true; fi
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    if is_owned "$SERVICE_FILE"; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    firewall_remove_owned_rules

    restore_file_backup "$CONF_FILE" protocol_config || true
    restore_file_backup "$NODE_INFO_FILE" protocol_node_info || true
    restore_file_backup "$SERVICE_FILE" protocol_service_unit || true

    for file in "$CONF_DIR/hy2_cert.pem" "$CONF_DIR/hy2_key.pem"; do
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
    done

    if is_owned "${VPS_TOOL_ROOT}/bin/sing-box"; then
        rm -f "${VPS_TOOL_ROOT}/bin/sing-box"
        unmark_owned "${VPS_TOOL_ROOT}/bin/sing-box"
    fi
    remove_owned_service_user
    rmdir "$CONF_DIR" 2>/dev/null || true
    log_action "[已撤销] 清理本工具创建的 sing-box 服务、配置和凭据"
}

protocol_menu() {
    while true; do
        clear
        local status_text
        systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null && status_text="${GREEN}运行中${PLAIN}" || status_text="${RED}未运行/未配置${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              [模块 2] 网络协议配置                ${PLAIN}"
        echo -e "服务：${status_text}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo "  1. VLESS + Reality"
        echo "  2. Hysteria 2"
        echo "  3. 查看节点信息"
        echo "  4. 清理本工具创建的协议环境"
        echo "  0. 返回"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-4]: " choice
        case "$choice" in
            1) deploy_vless_reality; read -rp "按回车继续..." ;;
            2) deploy_hysteria2; read -rp "按回车继续..." ;;
            3) [[ -f "$NODE_INFO_FILE" ]] && cat "$NODE_INFO_FILE" || echo "暂无节点信息"; read -rp "按回车继续..." ;;
            4) uninstall_protocol_environment; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    protocol_menu
fi
