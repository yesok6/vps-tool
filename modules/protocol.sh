#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

CONF_DIR="/etc/vps-tool/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
NODE_INFO_FILE="${CONF_DIR}/node_info.txt"
PROTOCOL_NODE_INFO_DIR="${CONF_DIR}"
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
        echo -e "${GREEN}[环境]${PLAIN} 检测到现有 sing-box，将复用当前程序：${SINGBOX_BIN}"
    else
        local version arch asset_url asset checksum tmp
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

        echo -e "${BLUE}[环境]${PLAIN} 下载 sing-box v${version} 并校验 SHA-256..."
        if ! download_https "$asset_url" "${tmp}/${asset}"; then
            rm -rf "$tmp"
            return 1
        fi
        if ! fetch_checksums_file "$version" "${tmp}/checksums.txt"; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 无法取得官方校验文件，拒绝安装未经校验的二进制。"
            return 1
        fi
        checksum=$(grep -F -- "$asset" "${tmp}/checksums.txt" | awk '{print $1}' | head -n1)
        if [[ ! "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]]; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 校验文件中找不到 ${asset} 的 SHA-256。"
            return 1
        fi
        if ! echo "${checksum}  ${tmp}/${asset}" | sha256sum -c - >/dev/null; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} sing-box SHA-256 校验失败，已拒绝安装。"
            return 1
        fi

        if ! mkdir -p "${VPS_TOOL_ROOT}/bin"; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 无法创建本地二进制目录。"
            return 1
        fi
        if ! tar -xzf "${tmp}/${asset}" -C "$tmp"; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} sing-box 压缩包解压失败。"
            return 1
        fi
        local extracted
        extracted=$(find "$tmp" -type f -name sing-box -perm -u=x | head -n1)
        if [[ -z "$extracted" ]]; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 压缩包中没有找到 sing-box。"
            return 1
        fi
        if ! install -m 0755 "$extracted" "${VPS_TOOL_ROOT}/bin/sing-box"; then
            rm -rf "$tmp"
            return 1
        fi
        mark_owned "${VPS_TOOL_ROOT}/bin/sing-box"
        SINGBOX_BIN="${VPS_TOOL_ROOT}/bin/sing-box"
        rm -rf "$tmp"
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

protocol_fragment_file() {
    local name="$1"
    case "$name" in
        vless) printf '%s/vless.json' "$CONF_DIR" ;;
        hy2) printf '%s/hy2.json' "$CONF_DIR" ;;
        tuic) printf '%s/tuic.json' "$CONF_DIR" ;;
        *) return 1 ;;
    esac
}

protocol_node_info_file() {
    local name="$1"
    case "$name" in
        vless) printf '%s/node_info_vless.txt' "$PROTOCOL_NODE_INFO_DIR" ;;
        hy2) printf '%s/node_info_hy2.txt' "$PROTOCOL_NODE_INFO_DIR" ;;
        tuic) printf '%s/node_info_tuic.txt' "$PROTOCOL_NODE_INFO_DIR" ;;
        *) return 1 ;;
    esac
}

protocol_transport() {
    case "$1" in
        vless) printf 'tcp' ;;
        hy2|tuic) printf 'udp' ;;
        *) return 1 ;;
    esac
}

protocol_port_state_key() {
    printf 'protocol_%s_port' "$1"
}

protocol_fragment_names() {
    printf '%s\n' vless hy2 tuic
}

write_protocol_fragment() {
    local name="$1" json="$2" file tmp
    file=$(protocol_fragment_file "$name") || return 1
    mkdir -p "$CONF_DIR"
    tmp=$(mktemp "${CONF_DIR}/.${name}.json.XXXXXX")
    if ! printf '%s\n' "$json" | jq -e 'type == "object" and (.type | type == "string") and (.tag | type == "string")' >/dev/null; then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} ${name} 协议片段不是合法的 inbound JSON，拒绝写入。"
        return 1
    fi
    printf '%s\n' "$json" > "$tmp"
    chmod 0640 "$tmp"
    chown root:vps-tool "$tmp"
    mv -f "$tmp" "$file"
    mark_owned "$file"
}

regenerate_singbox_config() {
    local files=() name file tmp
    for name in $(protocol_fragment_names); do
        file=$(protocol_fragment_file "$name") || return 1
        [[ -f "$file" ]] || continue
        files+=("$file")
    done

    if (( ${#files[@]} == 0 )); then
        if systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null; then
            systemctl stop "$SERVICE_UNIT" || return 1
        fi
        if systemctl is-enabled --quiet "$SERVICE_UNIT" 2>/dev/null; then
            systemctl disable "$SERVICE_UNIT" >/dev/null || return 1
        fi
        if [[ -e "$CONF_FILE" ]]; then
            rm -f "$CONF_FILE"
        fi
        return 0
    fi

    for file in "${files[@]}"; do
        jq -e 'type == "object" and (.type | type == "string") and (.tag | type == "string")' "$file" >/dev/null || {
            echo -e "${RED}[错误]${PLAIN} 协议片段 JSON 非法：${file}；原 config.json 保持不变。"
            return 1
        }
    done

    tmp=$(mktemp "${CONF_DIR}/.config.json.XXXXXX")
    if ! jq -s '
        {
            log: {level: "warn", timestamp: true},
            inbounds: .,
            outbounds: [{type: "direct", tag: "direct"}]
        }
        | if ([.inbounds[].tag] | length) == ([.inbounds[].tag] | unique | length) then . else error("duplicate inbound tag") end
    ' "${files[@]}" > "$tmp"; then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} 合并协议片段失败，原 config.json 保持不变。"
        return 1
    fi

    if ! jq -e '.inbounds | type == "array" and length > 0' "$tmp" >/dev/null; then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} 合并后的 sing-box 配置缺少 inbound，原 config.json 保持不变。"
        return 1
    fi
    chown root:vps-tool "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$CONF_FILE"
}

remove_protocol_fragment() {
    local name="$1" file rollback_dir
    file=$(protocol_fragment_file "$name") || return 1
    [[ -f "$file" ]] || return 1
    rollback_dir=$(make_temp_dir "protocol-${name}-fragment-remove")
    cp -a "$file" "${rollback_dir}/fragment"
    rm -f "$file"
    unmark_owned "$file"
    if ! regenerate_singbox_config; then
        cp -a "${rollback_dir}/fragment" "$file"
        mark_owned "$file"
        regenerate_singbox_config >/dev/null 2>&1 || true
        rm -rf "$rollback_dir"
        return 1
    fi
    rm -rf "$rollback_dir"
}

restore_protocol_fragment_transaction() {
    local name="$1" rollback_dir="$2" had_fragment="$3" file
    file=$(protocol_fragment_file "$name") || return 1
    if [[ "$had_fragment" == "1" ]]; then
        cp -a "${rollback_dir}/fragment" "$file"
        mark_owned "$file"
    else
        rm -f "$file"
        unmark_owned "$file"
    fi
    regenerate_singbox_config
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
    local name path
    for name in $(protocol_fragment_names); do
        path=$(protocol_fragment_file "$name") || continue
        [[ -f "$path" ]] && { chown root:vps-tool "$path"; chmod 0640 "$path"; }
        path=$(protocol_node_info_file "$name") || continue
        [[ -f "$path" ]] && { chown root:root "$path"; chmod 0600 "$path"; }
    done
    # Hysteria 2 / TUIC 证书和私钥由生成步骤单独设置权限；这里不覆盖其专用权限。
    return 0
}

prepare_protocol_state() {
    ensure_conf_permissions
    backup_file_once "$CONF_FILE" protocol_config
    backup_file_once "$NODE_INFO_FILE" protocol_node_info
}

write_protocol_node_info() {
    local name="$1" content="$2" file
    file=$(protocol_node_info_file "$name") || return 1
    umask 077
    printf '%s\n' "$content" > "$file"
    chown root:root "$file"
    chmod 0600 "$file"
    mark_owned "$file"
}

protocol_listener_is_up() {
    local name="$1" port transport
    # 优先从 config.json 取权威端口；取不到再退回 state 记录
    if [[ -f "$CONF_FILE" ]]; then
        port=$(jq -r --arg tag "${name}-in" '.inbounds[] | select(.tag == $tag) | .listen_port' "$CONF_FILE" 2>/dev/null | head -n1)
    fi
    [[ -n "${port:-}" ]] || port=$(state_get "$(protocol_port_state_key "$name")" 2>/dev/null || true)
    [[ -n "${port:-}" ]] || return 1
    transport=$(protocol_transport "$name") || return 1
    command_exists ss || return 1
    ss -H -lntup 2>/dev/null | awk -v port="$port" -v proto="$transport" '
        $0 ~ proto {
            for (i = 1; i <= NF; i++) {
                if ($i ~ (":" port "$")) { found = 1 }
            }
        }
        END { exit found ? 0 : 1 }
    '
}

protocol_status_text() {
    local name="$1"
    if ! state_exists "protocol_${name}"; then
        printf '未部署'
    elif protocol_listener_is_up "$name"; then
        printf '运行中'
    elif systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null; then
        printf '已部署/未检测到监听'
    else
        printf '已部署/服务未运行'
    fi
}

remove_protocol_resources() {
    local name="$1" cert_file key_file node_file port transport
    node_file=$(protocol_node_info_file "$name") || return 1
    port=$(state_get "$(protocol_port_state_key "$name")" 2>/dev/null || true)
    transport=$(protocol_transport "$name") || return 1

    case "$name" in
        hy2) cert_file="${CONF_DIR}/hy2_cert.pem"; key_file="${CONF_DIR}/hy2_key.pem" ;;
        tuic) cert_file="${CONF_DIR}/tuic_cert.pem"; key_file="${CONF_DIR}/tuic_key.pem" ;;
        vless) cert_file=""; key_file="" ;;
        *) return 1 ;;
    esac

    if [[ -n "$port" ]] && ! firewall_remove_owned_rules "$port" "$transport"; then
        echo -e "${YELLOW}[警告]${PLAIN} ${name} 的 ${port}/${transport} 防火墙规则未能删除，已保留记录以便后续重试。"
    fi
    if [[ -n "$cert_file" && -f "$cert_file" ]] && is_owned "$cert_file"; then
        rm -f "$cert_file"
        unmark_owned "$cert_file"
    fi
    if [[ -n "$key_file" && -f "$key_file" ]] && is_owned "$key_file"; then
        rm -f "$key_file"
        unmark_owned "$key_file"
    fi
    if is_owned "$node_file"; then
        rm -f "$node_file"
        unmark_owned "$node_file"
    fi
    state_unset "protocol_${name}"
    state_unset "$(protocol_port_state_key "$name")"
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
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}              [VLESS + Reality]                    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port sni uuid key_pair private_key public_key short_id server_ip
    local pipeline_mode="${1:-}"
    local fragment rollback_dir had_fragment=0
    default_port=$(get_random_protocol_port tcp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 TCP 端口。"; return 1; }
    if [[ "$pipeline_mode" == "pipeline" ]]; then
        port="$default_port"
        echo -e "${BLUE}[流水线]${PLAIN} 自动选择空闲 TCP 端口：${port}（无需手动输入）"
    else
        read -rp "端口 [回车使用 ${default_port}，范围 1024-65535]: " input_port
        port="${input_port:-$default_port}"
    fi
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" tcp && { echo -e "${RED}[错误]${PLAIN} TCP 端口已被占用。"; return 1; }
    state_exists protocol_vless && { echo -e "${YELLOW}[提示]${PLAIN} VLESS + Reality 已经部署。若需更换端口、SNI 或密钥，请先选择“5. 移除指定协议”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }

    install_singbox || return 1
    prepare_protocol_state
    fragment=$(protocol_fragment_file vless)
    rollback_dir=$(make_temp_dir protocol-vless-rollback)
    if [[ -f "$fragment" ]]; then cp -a "$fragment" "${rollback_dir}/fragment"; had_fragment=1; fi

    sni=$(get_best_sni)
    uuid=$(${SINGBOX_BIN} generate uuid)
    key_pair=$(${SINGBOX_BIN} generate reality-keypair)
    private_key=$(awk '/PrivateKey/ {print $2; exit}' <<< "$key_pair")
    public_key=$(awk '/PublicKey/ {print $2; exit}' <<< "$key_pair")
    short_id=$(${SINGBOX_BIN} generate rand --hex 8)
    [[ -n "$uuid" && -n "$private_key" && -n "$public_key" && -n "$short_id" ]] || { rm -rf "$rollback_dir"; echo -e "${RED}[错误]${PLAIN} Reality 密钥生成失败。"; return 1; }

    server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then
        read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip
    fi
    [[ -n "$server_ip" ]] || { rm -rf "$rollback_dir"; return 1; }

    local fragment_json
    fragment_json=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private_key,short_id:[$short_id]}}}')

    if ! write_protocol_fragment vless "$fragment_json" || ! regenerate_singbox_config || ! validate_singbox_config; then
        restore_protocol_fragment_transaction vless "$rollback_dir" "$had_fragment" >/dev/null
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} VLESS 协议部署失败，已仅回滚本次协议片段。";
        return 1
    fi
    if ! restart_service_and_verify; then
        restore_protocol_fragment_transaction vless "$rollback_dir" "$had_fragment" >/dev/null
        validate_singbox_config >/dev/null 2>&1 || true
        systemctl restart "$SERVICE_UNIT" >/dev/null 2>&1 || true
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} sing-box 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" tcp
    state_set protocol_vless 1
    state_set protocol_vless_port "$port"
    local vless_link
    vless_link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VPS-Tool-Reality"
    if ! write_protocol_node_info vless "===================== 节点连接信息 =====================
协议方案: VLESS + Vision + Reality
运行状态: $(protocol_status_text vless)
服务器地址: ${server_ip}
连接端口: ${port}
用户 ID (UUID): ${uuid}
流控: xtls-rprx-vision
SNI: ${sni}
PublicKey: ${public_key}
ShortId: ${short_id}

【一键导入分享链接】:
${vless_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} VLESS 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] VLESS-Reality 端口=${port} SNI=${sni}"
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    cat "$(protocol_node_info_file vless)"
    echo -e "\n${GREEN}[成功]${PLAIN} VLESS + Reality 部署完成。"
}

deploy_hysteria2() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                [Hysteria 2]                       ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port password cert_file key_file server_ip sni="bing.com"
    local fragment rollback_dir had_fragment=0 fragment_json
    default_port=$(get_random_protocol_port udp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 UDP 端口。"; return 1; }
    read -rp "UDP 端口 [回车使用 ${default_port}，范围 1024-65535]: " input_port
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" udp && { echo -e "${RED}[错误]${PLAIN} UDP 端口已被占用。"; return 1; }
    state_exists protocol_hy2 && { echo -e "${YELLOW}[提示]${PLAIN} Hysteria 2 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除指定协议”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }

    install_singbox || return 1
    prepare_protocol_state
    fragment=$(protocol_fragment_file hy2)
    rollback_dir=$(make_temp_dir protocol-hy2-rollback)
    if [[ -f "$fragment" ]]; then cp -a "$fragment" "${rollback_dir}/fragment"; had_fragment=1; fi

    password=$(${SINGBOX_BIN} generate rand --hex 16)
    cert_file="${CONF_DIR}/hy2_cert.pem"
    key_file="${CONF_DIR}/hy2_key.pem"
    if [[ -e "$cert_file" || -e "$key_file" ]] && { ! is_owned "$cert_file" || ! is_owned "$key_file"; }; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} 检测到非本工具创建的 Hysteria 2 证书/私钥，拒绝覆盖。"
        return 1
    fi
    if is_owned "$cert_file" || is_owned "$key_file"; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
    fi
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni}" >/dev/null 2>&1; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 TLS 证书生成失败。"
        return 1
    fi
    chmod 0640 "$key_file"
    chmod 0644 "$cert_file"
    chown root:vps-tool "$key_file" "$cert_file"
    mark_owned "$cert_file"
    mark_owned "$key_file"

    server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip; fi
    if [[ -z "$server_ip" ]]; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${YELLOW}[取消]${PLAIN} 未提供服务器地址，Hysteria 2 部署未继续。"
        return 1
    fi

    fragment_json=$(jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        --arg cert "$cert_file" \
        --arg key "$key_file" \
        '{type:"hysteria2",tag:"hy2-in",listen:"::",listen_port:$port,users:[{password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')

    if ! write_protocol_fragment hy2 "$fragment_json" || ! regenerate_singbox_config || ! validate_singbox_config; then
        restore_protocol_fragment_transaction hy2 "$rollback_dir" "$had_fragment" >/dev/null
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 部署失败，已仅回滚本次协议片段及本次生成证书。"
        return 1
    fi

    if ! restart_service_and_verify; then
        restore_protocol_fragment_transaction hy2 "$rollback_dir" "$had_fragment" >/dev/null
        if [[ "$had_fragment" == "1" ]]; then
            cp -a "${rollback_dir}/fragment" "$fragment" 2>/dev/null || true
        fi
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        systemctl restart "$SERVICE_UNIT" >/dev/null 2>&1 || true
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" udp
    state_set protocol_hy2 1
    state_set protocol_hy2_port "$port"
    local hy2_link
    hy2_link="hysteria2://${password}@${server_ip}:${port}/?insecure=1&sni=${sni}#VPS-Tool-Hysteria2"
    if ! write_protocol_node_info hy2 "===================== 节点连接信息 =====================
协议方案: Hysteria 2
运行状态: $(protocol_status_text hy2)
服务器地址: ${server_ip}
UDP 端口: ${port}
连接密码: ${password}
SNI: ${sni}
说明: 使用本工具生成的自签名证书，因此客户端链接包含 insecure=1。

【一键导入分享链接】:
${hy2_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} Hysteria 2 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] Hysteria2 UDP=${port}"
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    cat "$(protocol_node_info_file hy2)"
    echo -e "\n${GREEN}[成功]${PLAIN} Hysteria 2 部署完成。"
}

deploy_tuic_v5() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                 [TUIC v5]                         ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${BLUE}[说明]${PLAIN} 面向游戏/实时 UDP 场景，使用原生 UDP 中继；0-RTT 默认关闭以避免重放风险。"

    local default_port input_port port password uuid cert_file key_file server_ip sni="bing.com"
    local fragment rollback_dir had_fragment=0 fragment_json
    default_port=$(get_random_protocol_port udp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 UDP 端口。"; return 1; }
    read -rp "UDP 端口 [回车使用 ${default_port}，范围 1024-65535]: " input_port
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" udp && { echo -e "${RED}[错误]${PLAIN} UDP 端口已被占用。"; return 1; }
    state_exists protocol_tuic && { echo -e "${YELLOW}[提示]${PLAIN} TUIC v5 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除指定协议”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }

    install_singbox || return 1
    prepare_protocol_state
    fragment=$(protocol_fragment_file tuic)
    rollback_dir=$(make_temp_dir protocol-tuic-rollback)
    if [[ -f "$fragment" ]]; then cp -a "$fragment" "${rollback_dir}/fragment"; had_fragment=1; fi

    uuid=$(${SINGBOX_BIN} generate uuid)
    password=$(${SINGBOX_BIN} generate rand --hex 16)
    cert_file="${CONF_DIR}/tuic_cert.pem"
    key_file="${CONF_DIR}/tuic_key.pem"
    if [[ -e "$cert_file" || -e "$key_file" ]] && { ! is_owned "$cert_file" || ! is_owned "$key_file"; }; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} 检测到非本工具创建的 TUIC TLS 证书/私钥，拒绝覆盖。"
        return 1
    fi
    if is_owned "$cert_file" || is_owned "$key_file"; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
    fi
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni}" >/dev/null 2>&1; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} TUIC TLS 证书生成失败。"
        return 1
    fi
    chmod 0640 "$key_file"
    chmod 0644 "$cert_file"
    chown root:vps-tool "$key_file" "$cert_file"
    mark_owned "$cert_file"
    mark_owned "$key_file"

    [[ -n "$uuid" && -n "$password" ]] || {
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} TUIC 凭据生成失败。"
        return 1
    }

    server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip; fi
    if [[ -z "$server_ip" ]]; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${YELLOW}[取消]${PLAIN} 未提供服务器地址，TUIC 部署未继续。"
        return 1
    fi

    fragment_json=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg password "$password" \
        --arg cert "$cert_file" \
        --arg key "$key_file" \
        '{type:"tuic",tag:"tuic-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$password}],congestion_control:"bbr",auth_timeout:"3s",zero_rtt_handshake:false,heartbeat:"10s",tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}}')

    if ! write_protocol_fragment tuic "$fragment_json" || ! regenerate_singbox_config || ! validate_singbox_config; then
        restore_protocol_fragment_transaction tuic "$rollback_dir" "$had_fragment" >/dev/null
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} TUIC v5 部署失败，已仅回滚本次协议片段及本次生成证书。"
        return 1
    fi
    if ! restart_service_and_verify; then
        restore_protocol_fragment_transaction tuic "$rollback_dir" "$had_fragment" >/dev/null
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        systemctl restart "$SERVICE_UNIT" >/dev/null 2>&1 || true
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} sing-box 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" udp
    state_set protocol_tuic 1
    state_set protocol_tuic_port "$port"
    local tuic_link
    tuic_link="tuic://${uuid}:${password}@${server_ip}:${port}/?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=1&sni=${sni}#VPS-Tool-TUICv5"
    if ! write_protocol_node_info tuic "===================== 节点连接信息 =====================
协议方案: TUIC v5
运行状态: $(protocol_status_text tuic)
服务器地址: ${server_ip}
UDP 端口: ${port}
用户 ID (UUID): ${uuid}
连接密码: ${password}
拥塞控制: BBR
UDP 中继: native（原生 UDP）
0-RTT: 已关闭（避免重放风险）
ALPN: h3
SNI: ${sni}
说明: 使用本工具生成的自签名证书，因此客户端链接包含 insecure=1。

【一键导入分享链接】:
${tuic_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} TUIC 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] TUICv5 UDP=${port}"
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    cat "$(protocol_node_info_file tuic)"
    echo -e "\n${GREEN}[成功]${PLAIN} TUIC v5 部署完成。"
}

remove_protocol() {
    local name="$1" fragment rollback_dir had_fragment=0
    case "$name" in vless|hy2|tuic) ;; *) echo -e "${RED}[错误]${PLAIN} 未知协议。"; return 1 ;; esac
    state_exists "protocol_${name}" || { echo -e "${YELLOW}[提示]${PLAIN} ${name} 当前未部署。"; return 1; }
    resolve_singbox || { echo -e "${RED}[错误]${PLAIN} 未找到可用的 sing-box，无法安全移除协议。"; return 1; }
    prepare_protocol_state

    fragment=$(protocol_fragment_file "$name")
    [[ -f "$fragment" ]] || { echo -e "${RED}[错误]${PLAIN} ${name} 状态存在但协议片段不存在，拒绝自动删除。"; return 1; }
    rollback_dir=$(make_temp_dir "protocol-${name}-remove-rollback")
    cp -a "$fragment" "${rollback_dir}/fragment"
    had_fragment=1

    rm -f "$fragment"
    unmark_owned "$fragment"

    if ! regenerate_singbox_config; then
        restore_protocol_fragment_transaction "$name" "$rollback_dir" "$had_fragment" >/dev/null
        rm -rf "$rollback_dir"
        return 1
    fi

    if [[ -f "$CONF_FILE" ]]; then
        if ! validate_singbox_config; then
            restore_protocol_fragment_transaction "$name" "$rollback_dir" "$had_fragment" >/dev/null
            rm -rf "$rollback_dir"
            return 1
        fi
        if ! restart_service_and_verify; then
            restore_protocol_fragment_transaction "$name" "$rollback_dir" "$had_fragment" >/dev/null
            validate_singbox_config >/dev/null 2>&1 || true
            systemctl restart "$SERVICE_UNIT" >/dev/null 2>&1 || true
            rm -rf "$rollback_dir"
            echo -e "${RED}[错误]${PLAIN} 移除 ${name} 后服务未能按新配置启动，已恢复该协议。"
            return 1
        fi
    fi
    rm -rf "$rollback_dir"
    remove_protocol_resources "$name"
    echo -e "${GREEN}[成功]${PLAIN} 已移除 ${name}，其他协议不受影响。"
}

show_protocol_node_info() {
    local name file status
    local shown=0
    for name in $(protocol_fragment_names); do
        if state_exists "protocol_${name}"; then
            file=$(protocol_node_info_file "$name")
            status=$(protocol_status_text "$name")
            echo -e "${CYAN}================ ${name}：${status} ================${PLAIN}"
            if [[ -f "$file" ]]; then
                cat "$file"
            else
                echo -e "${YELLOW}[提示]${PLAIN} 节点信息文件不存在。"
            fi
            echo
            shown=1
        fi
    done
    (( shown == 1 )) || echo "暂无已部署协议。"
}

remove_protocol_menu() {
    local choices=() name idx choice
    for name in $(protocol_fragment_names); do
        state_exists "protocol_${name}" && choices+=("$name")
    done
    if (( ${#choices[@]} == 0 )); then
        echo "暂无已部署协议。"
        return 1
    fi
    echo -e "${CYAN}当前已部署协议：${PLAIN}"
    for idx in "${!choices[@]}"; do
        name="${choices[$idx]}"
        echo "  $((idx + 1)). ${name}（$(protocol_status_text "$name")）"
    done
    echo "  0. 返回"
    read -rp "请选择要移除的协议 [0-${#choices[@]}]: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 1; }
    (( choice == 0 )) && return 0
    (( choice >= 1 && choice <= ${#choices[@]} )) || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 1; }
    remove_protocol "${choices[$((choice - 1))]}"
}

uninstall_protocol_environment() {
    echo -e "${BLUE}[协议清理]${PLAIN} 仅清理 VPS-Tool 自己的协议环境。"
    if systemctl is-enabled --quiet "$SERVICE_UNIT" 2>/dev/null; then systemctl disable "$SERVICE_UNIT" >/dev/null 2>&1 || true; fi
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true

    firewall_remove_owned_rules || true

    local name file remove_legacy_node_info
    if [[ -f "$NODE_INFO_FILE" ]]; then
        if is_owned "$NODE_INFO_FILE"; then
            rm -f "$NODE_INFO_FILE"
            unmark_owned "$NODE_INFO_FILE"
        else
            echo -e "${YELLOW}[提示]${PLAIN} 检测到旧版节点信息文件 ${NODE_INFO_FILE}，其中可能含有明文节点凭据；round21 已改为按协议分别保存。"
            read -rp "是否删除这个旧版节点信息文件？[y/N]: " remove_legacy_node_info
            if [[ "$remove_legacy_node_info" =~ ^[Yy]$ ]]; then
                rm -f "$NODE_INFO_FILE"
                echo -e "${GREEN}[完成]${PLAIN} 已删除旧版节点信息文件。"
            else
                echo -e "${YELLOW}[保留]${PLAIN} 未删除旧版节点信息文件；新的协议节点信息不使用该文件。"
            fi
        fi
    fi
    for name in $(protocol_fragment_names); do
        file=$(protocol_fragment_file "$name") || continue
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
        file=$(protocol_node_info_file "$name") || continue
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
        state_unset "protocol_${name}"
        state_unset "$(protocol_port_state_key "$name")"
    done

    if is_owned "$SERVICE_FILE"; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    restore_file_backup "$CONF_FILE" protocol_config || true
    restore_file_backup "$SERVICE_FILE" protocol_service_unit || true

    for file in \
        "$CONF_DIR/hy2_cert.pem" "$CONF_DIR/hy2_key.pem" \
        "$CONF_DIR/tuic_cert.pem" "$CONF_DIR/tuic_key.pem"; do
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
    done

    if is_owned "${VPS_TOOL_ROOT}/bin/sing-box"; then
        rm -f "${VPS_TOOL_ROOT}/bin/sing-box"
        unmark_owned "${VPS_TOOL_ROOT}/bin/sing-box"
    fi
    remove_owned_service_user
    rmdir "$CONF_DIR" 2>/dev/null || true
    log_action "[已撤销] 清理本工具创建的 sing-box 服务、协议片段、配置和凭据"
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
        echo "  3. TUIC v5（游戏/实时 UDP）"
        echo "  4. 查看节点信息"
        echo "  5. 移除指定协议"
        echo "  6. 清理本工具创建的协议环境"
        echo "  0. 返回"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-6]: " choice
        case "$choice" in
            1) deploy_vless_reality || true; read -rp "按回车继续..." ;;
            2) deploy_hysteria2 || true; read -rp "按回车继续..." ;;
            3) deploy_tuic_v5 || true; read -rp "按回车继续..." ;;
            4) show_protocol_node_info; read -rp "按回车继续..." ;;
            5) remove_protocol_menu || true; read -rp "按回车继续..." ;;
            6) uninstall_protocol_environment || true; read -rp "按回车继续..." ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --pipeline-reality) deploy_vless_reality pipeline ;;
        *) protocol_menu ;;
    esac
fi
