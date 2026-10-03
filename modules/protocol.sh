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
PROTOCOL_CATALOG_FILE="${VPS_TOOL_ROOT}/protocol_catalog.json"
PROTOCOL_CATALOG_URL="${VPS_TOOL_PROTOCOL_CATALOG_URL:-https://raw.githubusercontent.com/yesok6/vps-tool/main/protocol_catalog.json}"

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

github_release_api_json() {
    local endpoint="$1"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/SagerNet/sing-box/${endpoint}"
}

latest_singbox_version() {
    local arch releases_json version
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) return 1 ;;
    esac

    # [修复 Bug] 增加网页 Redirect 兜底方案，防止无授权的 Github API 触发 60次/小时 速率限制导致大面积部署崩溃
    releases_json=$(github_release_api_json 'releases?per_page=10' 2>/dev/null || true)
    if [[ -n "$releases_json" ]]; then
        version=$(jq -er --arg arch "$arch" '
            .[]
            | select((.draft // false) == false and (.prerelease // false) == false)
            | .tag_name as $tag
            | select($tag != null and ($tag | startswith("v")))
            | select(any(.assets[]?; .name == ("sing-box-" + ($tag | sub("^v"; "")) + "-linux-" + $arch + ".tar.gz")))
            | ($tag | sub("^v"; ""))
        ' <<<"$releases_json" 2>/dev/null | sed -n '1p' || true)
        if [[ -n "$version" ]]; then echo "$version"; return 0; fi
    fi
    
    version=$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+.*' | sed 's/^v//' || true)
    if [[ -n "$version" ]]; then echo "$version"; return 0; fi
    return 1
}

fetch_release_asset_digest() {
    local version="$1" asset="$2" release_json checksum
    release_json=$(github_release_api_json "releases/tags/v${version}" 2>/dev/null || true)
    [[ -n "$release_json" ]] || return 1
    checksum=$(jq -r --arg name "$asset" '
        .assets[]?
        | select(.name == $name)
        | (.digest // empty)
    ' <<<"$release_json" | sed -n '1p' )
    checksum="${checksum#sha256:}"
    [[ "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$checksum"
}

fetch_checksums_file() {
    local version="$1" out="$2" name url asset
    asset="${SINGBOX_CHECKSUM_ASSET:-sing-box-${version}-linux-amd64.tar.gz}"
    for name in \
        sha256sums.txt \
        sha256sums \
        SHA256SUMS \
        checksums.txt \
        checksums.sha256 \
        "${asset}.sha256" \
        "${asset}.sha256.txt"; do
        url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${name}"
        rm -f "$out"
        if curl --fail --silent --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 30 -o "$out" "$url"; then
            [[ -s "$out" ]] && return 0
        fi
    done
    return 1
}

extract_singbox_checksum() {
    local file="$1" asset="$2"
    awk -v asset="$asset" '
        function valid_hash(s) {
            return length(s) == 64 && s !~ /[^0-9A-Fa-f]/
        }
        {
            hash=$1
            name=$2
            sub(/^\*/, "", name)
            if (valid_hash(hash) && name == asset) {
                print hash
                exit
            }
            prefix="SHA256 (" asset ") = "
            if (index($0, prefix) == 1) {
                hash=substr($0, length(prefix) + 1)
                if (valid_hash(hash)) {
                    print hash
                    exit
                }
            }
        }
    ' "$file"
}

resolve_singbox_checksum() {
    local version="$1" asset="$2" checksum_file="$3" checksum
    local SINGBOX_CHECKSUM_ASSET="$asset"

    if [[ "${VPS_TOOL_SKIP_SINGBOX_VERIFY:-0}" == "1" ]]; then
        echo -e "${YELLOW}[警告]${PLAIN} VPS_TOOL_SKIP_SINGBOX_VERIFY=1：已跳过 sing-box SHA-256 校验，仅适用于明确完成人工核验的应急场景。" >&2
        log_action "[警告] 本次跳过了 sing-box SHA-256 校验（VPS_TOOL_SKIP_SINGBOX_VERIFY=1）"
        return 0
    fi

    if checksum=$(fetch_release_asset_digest "$version" "$asset"); then
        printf '%s\n' "$checksum"
        return 0
    fi

    if fetch_checksums_file "$version" "$checksum_file"; then
        checksum=$(extract_singbox_checksum "$checksum_file" "$asset")
        if [[ "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]]; then
            printf '%s\n' "$checksum"
            return 0
        fi
    fi

    echo -e "${RED}[错误]${PLAIN} 上游 v${version} 未提供可用校验值（已尝试 GitHub Release API 的 digest 与 7 种校验文件名），拒绝安装未经校验的 sing-box。" >&2
    echo -e "${YELLOW}[提示]${PLAIN} 可到 https://github.com/SagerNet/sing-box/releases/tag/v${version} 人工核验对应 ${asset} 的 SHA-256。" >&2
    echo -e "${YELLOW}[提示]${PLAIN} 如确认需要应急跳过，可显式设置 VPS_TOOL_SKIP_SINGBOX_VERIFY=1；默认不会跳过校验。" >&2
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
        if checksum=$(resolve_singbox_checksum "$version" "$asset" "${tmp}/checksums.txt"); then
            if [[ -n "$checksum" ]]; then
                if ! echo "${checksum}  ${tmp}/${asset}" | sha256sum -c - >/dev/null; then
                    rm -rf "$tmp"
                    echo -e "${RED}[错误]${PLAIN} sing-box SHA-256 校验失败，已拒绝安装。"
                    return 1
                fi
            else
                echo -e "${YELLOW}[警告]${PLAIN} 本次未执行 sing-box SHA-256 校验。"
            fi
        else
            rm -rf "$tmp"
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
    local service_hardening="${VPS_TOOL_SERVICE_HARDENING:-on}"
    case "${service_hardening,,}" in
        off|0|false|no)
            cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=VPS-Tool sing-box service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=vps-tool
Group=vps-tool
ExecStart=${SINGBOX_BIN} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
            ;;
        *)
            # [修复 Bug] 补齐 WorkingDirectory 和 ReadWritePaths，
            # 解决由于 ProtectSystem=strict 导致的 cache.db 数据库创建失败与进程闪退。
            cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=VPS-Tool sing-box service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=vps-tool
Group=vps-tool
WorkingDirectory=/etc/vps-tool/sing-box
ReadWritePaths=/etc/vps-tool/sing-box
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
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF2
            ;;
    esac
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
    if [[ -n "$best" ]]; then
        echo "$best"
    else
        echo -e "${YELLOW}[提示]${PLAIN} 所有候选 SNI 均探测失败，已回退默认值 addons.mozilla.org" >&2
        log_action "[提示] 所有候选 SNI 均探测失败，已回退默认值 addons.mozilla.org"
        echo "addons.mozilla.org"
    fi
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

    remove_port_hopping "$name" || true
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

show_singbox_start_failure() {
    echo -e "${RED}[错误]${PLAIN} sing-box 服务启动失败，下面是最近 20 条真实日志："
    journalctl -u "$SERVICE_UNIT" -n 20 --no-pager -l 2>/dev/null | sed 's/^/    /' || true
    log_action "[错误] ${SERVICE_UNIT} 启动失败；请执行 journalctl -u ${SERVICE_UNIT} -n 50 --no-pager -l 查看详情"
}

restart_service_and_verify() {
    systemctl daemon-reload
    if ! systemctl restart "$SERVICE_UNIT"; then
        show_singbox_start_failure
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        return 1
    fi

    local attempt
    for ((attempt = 1; attempt <= 20; attempt++)); do
        if systemctl is-active --quiet "$SERVICE_UNIT"; then
            return 0
        fi
        if systemctl is-failed --quiet "$SERVICE_UNIT"; then
            show_singbox_start_failure
            systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
            systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
            return 1
        fi
        sleep 0.5
    done

    show_singbox_start_failure
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    return 1
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


protocol_hop_state_key() {
    printf '%s_hop_ports' "$1"
}

protocol_hop_backend_state_key() {
    printf '%s_hop_backend' "$1"
}

protocol_hop_listen_state_key() {
    printf '%s_hop_listen_port' "$1"
}

validate_hop_range() {
    local range="$1" start end span
    [[ "$range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    (( start >= 1024 && end <= 65535 && start < end )) || return 1
    span=$((end-start))
    (( span <= 200 ))
}

hop_range_conflicts() {
    local start="$1" end="$2" other_name other_port other_range other_start other_end occupied_ports
    for other_name in $(protocol_fragment_names); do
        [[ -f "$(protocol_fragment_file "$other_name")" ]] || continue
        other_port=$(state_get "$(protocol_port_state_key "$other_name")" 2>/dev/null || true)
        if [[ "$other_port" =~ ^[0-9]+$ ]] && (( other_port >= start && other_port <= end )); then
            return 0
        fi
        other_range=$(state_get "$(protocol_hop_state_key "$other_name")" 2>/dev/null || true)
        if [[ "$other_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            other_start="${BASH_REMATCH[1]}"
            other_end="${BASH_REMATCH[2]}"
            if (( start <= other_end && end >= other_start )); then
                return 0
            fi
        fi
    done

    if command_exists ss; then
        occupied_ports=$(ss -H -lun 2>/dev/null | awk -v start="$start" -v end="$end" '
            {
                for (i = 1; i <= NF; i++) {
                    field=$i
                    if (field ~ /:[0-9]+$/) {
                        port=field
                        sub(/^.*:/, "", port)
                        if (port ~ /^[0-9]+$/ && port >= start && port <= end) {
                            print port
                        }
                        break
                    }
                }
            }
        ')
        [[ -z "$occupied_ports" ]] || return 0
    else
        for ((port=start; port<=end; port++)); do
            port_in_use "$port" udp && return 0
        done
    fi
    return 1
}

prompt_port_hopping() {
    local choice range start end blank_attempts=0
    PORT_HOP_RANGE=""
    PORT_HOP_ENABLED=0
    [[ "${1:-0}" == "1" ]] || return 0
    echo -e "${YELLOW}[说明]${PLAIN} 启用后，本机防火墙会为该范围每个 UDP 端口各加一条放行规则；关闭时会逐条收回。"
    read -rp "是否启用 UDP 端口跳跃（可缓解晚高峰 UDP 限速）？[Y/n]: " choice
    [[ "$choice" =~ ^[Nn]$ ]] && return 0
    while true; do
        read -rp "输入端口范围（例如 20000-20100，跨度 ≤ 200）：" range
        if [[ -z "$range" ]]; then
            ((blank_attempts += 1))
            echo -e "${YELLOW}[提示]${PLAIN} 必须输入端口范围。"
            if (( blank_attempts >= 3 )); then
                echo -e "${YELLOW}[提示]${PLAIN} 连续 3 次未输入端口范围，已取消端口跳跃并继续部署。"
                return 0
            fi
            continue
        fi
        if ! validate_hop_range "$range"; then
            echo -e "${RED}[错误]${PLAIN} 范围必须为 1024-65535、起 < 止、跨度 ≤ 200。"
            continue
        fi
        start="${range%-*}"; end="${range#*-}"
        echo -e "${YELLOW}[提醒]${PLAIN} 云平台安全组需放行整段 UDP ${start}-${end}，本工具只能管理本机防火墙。"
        if hop_range_conflicts "$start" "$end"; then
            echo -e "${RED}[错误]${PLAIN} 端口范围与现有监听/已部署协议存在冲突，请换一段范围。"
            continue
        fi
        PORT_HOP_RANGE="$range"
        PORT_HOP_ENABLED=1
        return 0
    done
}

setup_port_hopping() {
    # [修复 Bug] 重写底层的映射防火墙逻辑。彻底废弃原有的 iptables/nft 暴力写入循环（会导致 firewalld 覆盖冲突和 Reload 风暴）
    # 改为采用防火墙原生指令，一句话直接挂载 Forward 并批量放行。
    local name="$1" range="$2" listen_port="$3" backend file start end p
    [[ -n "$range" ]] || return 0
    start="${range%-*}"; end="${range#*-}"

    state_set "$(protocol_hop_state_key "$name")" "$range"
    state_set "$(protocol_hop_listen_state_key "$name")" "$listen_port"

    if [[ "$(firewall_backend)" == "ufw" ]]; then
        ufw allow "${start}:${end}/udp" >/dev/null 2>&1 || true
        state_set "$(protocol_hop_backend_state_key "$name")" ufw
        log_action "[可撤销] ${name} 启用端口跳跃 ${range} -> ${listen_port}/ufw"
        return 0
    elif [[ "$(firewall_backend)" == "firewalld" ]]; then
        firewall-cmd --permanent --add-forward-port=port=${start}-${end}:proto=udp:toport=${listen_port} >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${start}-${end}/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        state_set "$(protocol_hop_backend_state_key "$name")" firewalld
        log_action "[可撤销] ${name} 启用端口跳跃 ${range} -> ${listen_port}/firewalld"
        return 0
    else
        for ((p=start; p<=end; p++)); do firewall_allow "$p" udp >/dev/null 2>&1 || true; done
        state_set "$(protocol_hop_backend_state_key "$name")" none
        log_action "[可撤销] ${name} 启用端口跳跃 ${range} -> ${listen_port}/none"
        return 0
    fi
}

remove_port_hopping() {
    # [修复 Bug] 配套上方重构逻辑的新版清理函数，极速卸载。
    local name="$1" range backend listen_port file start end p failed=0
    range=$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || true)
    [[ -n "$range" ]] || return 0
    backend=$(state_get "$(protocol_hop_backend_state_key "$name")" 2>/dev/null || true)
    listen_port=$(state_get "$(protocol_hop_listen_state_key "$name")" 2>/dev/null || true)
    if ! validate_hop_range "$range"; then return 1; fi
    start="${range%-*}"; end="${range#*-}"

    case "$backend" in
        ufw)
            ufw delete allow "${start}:${end}/udp" >/dev/null 2>&1 || true
            ;;
        firewalld)
            firewall-cmd --permanent --remove-forward-port=port=${start}-${end}:proto=udp:toport=${listen_port} >/dev/null 2>&1 || true
            firewall-cmd --permanent --remove-port=${start}-${end}/udp >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        *)
            for ((p=start; p<=end; p++)); do firewall_remove_owned_rules "$p" udp >/dev/null 2>&1 || true; done
            ;;
    esac

    state_unset "$(protocol_hop_state_key "$name")"
    state_unset "$(protocol_hop_backend_state_key "$name")"
    state_unset "$(protocol_hop_listen_state_key "$name")"
    log_action "[已撤销] ${name} 端口跳跃 ${range}"
    return 0
}

check_protocol_resources() {
    local target_protocols=("$@") protocol_count=0 name mem_mb root_mb swap_mb cpu_count
    local mem_pass mem_warn root_pass root_warn blocked=0 warn=0 confirm action buf_warn=0
    for name in $(protocol_fragment_names); do
        state_exists "protocol_${name}" && ((protocol_count+=1))
    done
    for name in "${target_protocols[@]}"; do
        if ! state_exists "protocol_${name}"; then
            ((protocol_count+=1))
        fi
    done
    (( protocol_count < 1 )) && protocol_count=1
    mem_mb=$(get_mem_available_mb)
    root_mb=$(get_root_free_mb)
    swap_mb=$(current_swap_mb)
    cpu_count=$(nproc 2>/dev/null || echo 1)

    if (( protocol_count == 1 )); then
        mem_pass=128; mem_warn=96
        root_pass=512; root_warn=300
    elif (( protocol_count == 2 )); then
        mem_pass=192; mem_warn=128
        root_pass=800; root_warn=500
    else
        mem_pass=256; mem_warn=192
        root_pass=800; root_warn=500
    fi

    echo -e "${CYAN}[资源预检]${PLAIN} 可用内存 ${mem_mb} MiB / 根分区 ${root_mb} MiB / Swap ${swap_mb} MiB / CPU ${cpu_count} / 协议数 ${protocol_count}"

    if (( mem_mb < mem_warn )); then
        if (( swap_mb >= 512 )); then
            echo -e "${YELLOW}[警告]${PLAIN} 可用内存低于当前协议数的拦截阈值，但已有 Swap ≥ 512 MiB；Swap 只是缓冲，速度远低于真实内存。"
            warn=1
        else
            blocked=1
        fi
    elif (( mem_mb < mem_pass )); then
        warn=1
        echo -e "${YELLOW}[警告]${PLAIN} 可用内存 ${mem_mb} MiB 处于警告区，协议数越多越容易出现 OOM。"
    fi
    if (( root_mb < root_warn )); then
        blocked=1
    elif (( root_mb < root_pass )); then
        warn=1
        echo -e "${YELLOW}[警告]${PLAIN} 根分区可用空间 ${root_mb} MiB 处于警告区。"
    fi

    local tcp_wmem_max wmem_default threshold
    tcp_wmem_max=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $NF}' || echo 0)
    wmem_default=$(sysctl -n net.core.wmem_default 2>/dev/null || echo 0)
    threshold=$((mem_mb * 1024 / 8))
    if [[ "$tcp_wmem_max" =~ ^[0-9]+$ ]] && (( tcp_wmem_max >= threshold )); then buf_warn=1; fi
    if [[ "$wmem_default" =~ ^[0-9]+$ ]] && (( wmem_default >= threshold )); then buf_warn=1; fi
    if (( buf_warn )); then
        echo -e "${YELLOW}[警告]${PLAIN} 当前内核缓冲区上限对小内存机器偏大，可能在高并发时触发 OOM，建议先执行模块 3 的低内存适配（或手动降低）。"
    fi

    if (( blocked )); then
        if [[ "${VPS_TOOL_FORCE_DEPLOY:-0}" == "1" ]]; then
            echo -e "${YELLOW}[强制继续]${PLAIN} 已按用户要求强制继续，当前资源不足可能导致 OOM 或磁盘耗尽。"
            return 0
        fi
        echo -e "${RED}[拦截]${PLAIN} 当前资源低于安全部署阈值。"
        echo "  1. 增加 Swap：可调用现有 Swap 管理功能；Swap 只作缓冲。"
        echo "  2. 释放磁盘：du -xh / --max-depth=1 | sort -h | tail"
        echo "  3. 明确设置 VPS_TOOL_FORCE_DEPLOY=1 可强制继续（风险自负）。"
        if [[ "${VPS_TOOL_PIPELINE:-0}" == "1" ]]; then
            echo -e "${RED}[流水线]${PLAIN} 资源处于拦截区，按既有语义直接中止，不等待输入。"
            return 1
        fi
        if ! IFS= read -r -p "现在尝试增加 Swap？[y/N]: " action; then
            action=""
        fi
        if [[ "$action" =~ ^[Yy]$ ]]; then
            local recommended
            recommended=$(recommend_managed_swap_mb)
            if (( recommended >= 256 )); then
                ensure_managed_swap "$recommended" || return 1
                mem_mb=$(get_mem_available_mb)
                swap_mb=$(current_swap_mb)
                if (( mem_mb < mem_warn && swap_mb < 512 )); then return 1; fi
                if (( root_mb < root_warn )); then return 1; fi
                echo -e "${GREEN}[继续]${PLAIN} Swap 调整后允许继续。"
                return 0
            fi
        fi
        return 1
    fi

    if (( warn )); then
        if [[ "${VPS_TOOL_PIPELINE:-0}" == "1" ]]; then
            echo -e "${YELLOW}[流水线]${PLAIN} 资源处于警告区，按流水线语义继续，不等待输入。"
            return 0
        fi
        if ! IFS= read -r -p "资源处于警告区，仍要继续部署？[y/N]: " confirm; then
            confirm=""
        fi
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi
    echo -e "${GREEN}[通过]${PLAIN} 资源预检通过。"
    return 0
}

node_info_value() {
    local file="$1" key="$2"
    awk -v k="$key" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$file"
}

node_info_share_link() {
    local file="$1"
    awk '/^【一键导入分享链接】:/{getline; print; exit}' "$file"
}

yaml_quote() {
    jq -Rn --arg v "$1" '$v'
}

install_qrencode_dependency() {
    local install_output install_rc=0 choice
    if command_exists qrencode; then
        local qr_path qr_version
        qr_path=$(command -v qrencode)
        qr_version=$(qrencode --version 2>&1 | head -n1 || true)
        if [[ -n "$qr_version" ]]; then
            echo -e "${GREEN}[已安装]${PLAIN} qrencode 已安装：${qr_version}（${qr_path}）"
        else
            echo -e "${GREEN}[已安装]${PLAIN} qrencode 已安装：${qr_path}"
        fi
        return 0
    fi

    if [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || [[ ! -t 1 ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 当前为非交互环境，已跳过二维码依赖安装。"
        return 0
    fi

    echo -e "${YELLOW}[提示]${PLAIN} 显示二维码需要 qrencode，当前未安装。"
    read -rp "是否现在安装？（约几百 KB，仅安装这一个包）[Y/n]: " choice
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 已跳过安装。"
        return 0
    fi

    if command_exists apt-get; then
        install_output=$(DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode 2>&1) || install_rc=$?
    elif command_exists dnf; then
        install_output=$(dnf install -y qrencode 2>&1) || install_rc=$?
    elif command_exists yum; then
        install_output=$(yum install -y qrencode 2>&1) || install_rc=$?
    else
        install_rc=127
        install_output="未找到 apt-get、dnf 或 yum。"
    fi

    if (( install_rc != 0 )) || ! command_exists qrencode; then
        echo -e "${RED}[错误]${PLAIN} qrencode 安装失败。"
        [[ -n "$install_output" ]] && echo "$install_output" | tail -n 8
        if command_exists apt-get; then
            echo "手动安装命令：apt install -y qrencode"
        elif command_exists dnf; then
            echo "手动安装命令：dnf install -y qrencode"
        elif command_exists yum; then
            echo "手动安装命令：yum install -y qrencode"
        else
            echo "手动安装命令：请使用当前发行版的软件包管理器安装 qrencode。"
        fi
        return 0
    fi
    echo -e "${GREEN}[成功]${PLAIN} qrencode 安装完成。"
}

display_protocol_qr() {
    local name="$1" file link
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] && return 0
    [[ -t 1 ]] || return 0
    if ! command_exists qrencode; then
        echo -e "${YELLOW}[提示]${PLAIN} 显示二维码需要 qrencode，当前未安装；请进入“其他与诊断 → 二维码”并执行第 1 项安装依赖。"
        return 0
    fi
    file=$(protocol_node_info_file "$name") || return 1
    [[ -f "$file" ]] || return 1
    link=$(node_info_share_link "$file")
    [[ -n "$link" ]] || { echo -e "${YELLOW}[提示]${PLAIN} ${name} 未找到可生成二维码的分享链接。"; return 0; }
    echo -e "${CYAN}[${name}] 节点二维码：${PLAIN}"
    printf '%s\n' "$link" | qrencode -t ANSIUTF8
}

qr_menu() {
    local choice
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}                    二维码                         ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        if command_exists qrencode; then
            echo -e "  当前状态：${GREEN}qrencode 已安装${PLAIN}"
        else
            echo -e "  当前状态：${YELLOW}qrencode 未安装${PLAIN}"
        fi
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${GREEN}1. 安装 / 检查二维码依赖（qrencode）${PLAIN}"
        echo -e "  ${GREEN}2. 显示节点二维码${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${RED}0. 返回${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-2]: " choice
        case "$choice" in
            1) install_qrencode_dependency; read -rp "按回车继续..." ;;
            2)
                if ! command_exists qrencode; then
                    echo -e "${YELLOW}[提示]${PLAIN} 当前未安装 qrencode，请先执行第 1 项安装依赖。"
                else
                    show_protocol_qr_menu || true
                fi
                read -rp "按回车继续..."
                ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

show_protocol_qr_menu() {
    local choices=() name choice idx
    for name in $(protocol_fragment_names); do
        state_exists "protocol_${name}" && choices+=("$name")
    done
    (( ${#choices[@]} )) || { echo "暂无已部署协议。"; return 1; }
    echo "请选择要显示二维码的协议："
    for idx in "${!choices[@]}"; do echo "  $((idx+1)). ${choices[$idx]}"; done
    echo "  0. 返回"
    read -rp "请选择: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice == 0 )) && return 0
    (( choice >= 1 && choice <= ${#choices[@]} )) || return 1
    display_protocol_qr "${choices[$((choice-1))]}"
}

generate_clash_yaml() {
    local file tmp name node_file server port uuid password sni public_key short_id range
    local count=0
    local -a proxies=()
    local -a names=()
    for name in $(protocol_fragment_names); do
        state_exists "protocol_${name}" && names+=("$name")
    done
    (( ${#names[@]} )) || { echo -e "${YELLOW}[提示]${PLAIN} 暂无已部署协议，无法生成 Clash 配置。"; return 1; }
    command_exists jq || { echo -e "${RED}[错误]${PLAIN} 缺少 jq，无法安全生成 Clash YAML。"; return 1; }

    tmp=$(mktemp "${CONF_DIR}/.clash.yaml.XXXXXX")
    {
        echo "# VPS-Tool 生成的可粘贴 Clash/Mihomo 配置片段"
        echo "proxies:"
    } > "$tmp"

    for name in "${names[@]}"; do
        node_file=$(protocol_node_info_file "$name")
        [[ -f "$node_file" ]] || { echo -e "${YELLOW}[跳过]${PLAIN} ${name} 节点信息缺失。"; continue; }
        server=$(node_info_value "$node_file" '服务器地址')
        port=$(node_info_value "$node_file" '连接端口')
        [[ -n "$port" ]] || port=$(node_info_value "$node_file" 'UDP 端口')
        sni=$(node_info_value "$node_file" 'SNI')
        case "$name" in
            vless)
                uuid=$(node_info_value "$node_file" '用户 ID (UUID)')
                public_key=$(node_info_value "$node_file" 'PublicKey')
                short_id=$(node_info_value "$node_file" 'ShortId')
                vision_flow=$(node_info_value "$node_file" '流控')
                [[ "$vision_flow" == "已关闭 Vision" ]] && vision_flow=""
                if [[ -z "$server" || -z "$port" || -z "$uuid" || -z "$sni" || -z "$public_key" || -z "$short_id" ]]; then
                    echo -e "${YELLOW}[跳过]${PLAIN} VLESS 缺少必要字段，未输出残缺 YAML。"
                    continue
                fi
                {
                    echo "  - name: VPS-Tool-Reality"
                    echo "    type: vless"
                    echo "    server: $(yaml_quote "$server")"
                    echo "    port: ${port}"
                    echo "    uuid: $(yaml_quote "$uuid")"
                    echo "    network: tcp"
                    echo "    tls: true"
                    echo "    udp: true"
                    [[ -n "$vision_flow" ]] && echo "    flow: $(yaml_quote "$vision_flow")"
                    echo "    servername: $(yaml_quote "$sni")"
                    echo "    client-fingerprint: chrome"
                    echo "    reality-opts:"
                    echo "      public-key: $(yaml_quote "$public_key")"
                    echo "      short-id: $(yaml_quote "$short_id")"
                } >> "$tmp"
                proxies+=(VPS-Tool-Reality)
                ((count+=1))
                ;;
            hy2)
                password=$(node_info_value "$node_file" '连接密码')
                if [[ -z "$server" || -z "$port" || -z "$password" || -z "$sni" ]]; then
                    echo -e "${YELLOW}[跳过]${PLAIN} Hysteria2 缺少必要字段，未输出残缺 YAML。"
                    continue
                fi
                {
                    echo "  - name: VPS-Tool-Hysteria2"
                    echo "    type: hysteria2"
                    echo "    server: $(yaml_quote "$server")"
                    echo "    port: ${port}"
                    echo "    password: $(yaml_quote "$password")"
                    echo "    sni: $(yaml_quote "$sni")"
                    echo "    alpn: [h3]"
                    echo "    skip-cert-verify: true"
                    range=$(state_get "$(protocol_hop_state_key hy2)" 2>/dev/null || true)
                    [[ -n "$range" ]] && echo "    ports: $(yaml_quote "$range")"
                } >> "$tmp"
                proxies+=(VPS-Tool-Hysteria2)
                ((count+=1))
                ;;
            tuic)
                uuid=$(node_info_value "$node_file" '用户 ID (UUID)')
                password=$(node_info_value "$node_file" '连接密码')
                if [[ -z "$server" || -z "$port" || -z "$uuid" || -z "$password" || -z "$sni" ]]; then
                    echo -e "${YELLOW}[跳过]${PLAIN} TUIC 缺少必要字段，未输出残缺 YAML。"
                    continue
                fi
                {
                    echo "  - name: VPS-Tool-TUICv5"
                    echo "    type: tuic"
                    echo "    server: $(yaml_quote "$server")"
                    echo "    port: ${port}"
                    echo "    uuid: $(yaml_quote "$uuid")"
                    echo "    password: $(yaml_quote "$password")"
                    echo "    congestion-controller: bbr"
                    echo "    udp-relay-mode: native"
                    echo "    alpn: [h3]"
                    echo "    sni: $(yaml_quote "$sni")"
                    echo "    skip-cert-verify: true"
                    range=$(state_get "$(protocol_hop_state_key tuic)" 2>/dev/null || true)
                    [[ -n "$range" ]] && echo "    ports: $(yaml_quote "$range")"
                } >> "$tmp"
                proxies+=(VPS-Tool-TUICv5)
                ((count+=1))
                ;;
        esac
    done

    if (( count == 0 )); then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} 没有任何协议拥有生成 Clash 配置所需的完整字段。"
        return 1
    fi

    {
        echo
        echo "proxy-groups:"
        echo "  - name: VPS-Tool-Auto"
        echo "    type: select"
        echo "    proxies:"
        for name in "${proxies[@]}"; do echo "      - ${name}"; done
        echo
        echo "rules:"
        echo "  - GEOIP,CN,DIRECT"
        echo "  - MATCH,VPS-Tool-Auto"
    } >> "$tmp"

    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "${CONF_DIR}/clash.yaml"
    mark_owned "${CONF_DIR}/clash.yaml"
    echo -e "${GREEN}[完成]${PLAIN} Clash/Mihomo 配置已生成：${CONF_DIR}/clash.yaml"
    cat "${CONF_DIR}/clash.yaml"
}

show_clash_yaml() {
    if [[ ! -f "${CONF_DIR}/clash.yaml" ]]; then
        generate_clash_yaml || return 1
        return 0
    fi
    cat "${CONF_DIR}/clash.yaml"
}

protocol_diagnose() {
    local name file tag port proto status backend
    echo -e "${CYAN}================ 协议诊断（只读） ================${PLAIN}"
    if resolve_singbox; then
        echo "[sing-box version]"
        "$SINGBOX_BIN" version 2>&1 || true
    else
        echo -e "${YELLOW}[提示]${PLAIN} 未检测到 sing-box。"
    fi
    echo "[sing-box check]"
    if [[ -f "$CONF_FILE" ]] && resolve_singbox; then
        "$SINGBOX_BIN" check -c "$CONF_FILE" 2>&1 || true
    else
        echo "未找到 ${CONF_FILE}"
    fi
    echo "[inbounds]"
    if [[ -f "$CONF_FILE" ]] && command_exists jq; then
        while IFS=$'\t' read -r tag name port; do
            [[ -n "$tag" ]] || continue
            # [修复 Bug] 修改了错误的匹配变量，让面板不再把正常监听的协议错误上报为“未监听”。
            proto=$(case "$tag" in vless-in) echo vless;; hy2-in) echo hy2;; tuic-in) echo tuic;; *) echo unknown;; esac)
            status="未监听"
            if [[ "$proto" != unknown ]] && protocol_listener_is_up "$proto"; then status="已监听"; fi
            echo "  tag=${tag} type=${name} port=${port} -> ${status}"
        done < <(jq -r '.inbounds[]? | [.tag,.type,(.listen_port|tostring)] | @tsv' "$CONF_FILE" 2>/dev/null)
    else
        echo "无法读取 config.json"
    fi
    echo "[firewall]"
    backend=$(firewall_backend)
    for name in vless hy2 tuic; do
        state_exists "protocol_${name}" || continue
        port=$(state_get "$(protocol_port_state_key "$name")" 2>/dev/null || true)
        proto=$(protocol_transport "$name") || continue
        if [[ "$backend" != none ]]; then
            if firewall_rule_exists "$backend" "$port" "$proto" >/dev/null 2>&1; then status="已放行"; else status="未检测到本机放行"; fi
        else
            status="未检测到活动主机防火墙"
        fi
        echo "  ${name}: ${port}/${proto} -> ${status}"
    done
    echo "[云安全组]"
    echo "  请确认云平台安全组至少放行协议对应 TCP/UDP 端口；UDP 协议需放行 UDP。"
    if [[ -f "$CONF_FILE" ]] && command_exists jq; then
        while IFS=$'\t' read -r tag type port; do
            [[ -n "$tag" ]] || continue
            if ! protocol_listener_is_up "$(case "$type" in vless) echo vless;; hysteria2) echo hy2;; tuic) echo tuic;; esac)"; then
                echo -e "${YELLOW}[下一步]${PLAIN} ${tag}:${port} 未监听：systemctl status ${SERVICE_UNIT}；journalctl -u ${SERVICE_UNIT} -n 50 --no-pager -l"
            fi
        done < <(jq -r '.inbounds[]? | [.tag,.type,(.listen_port|tostring)] | @tsv' "$CONF_FILE" 2>/dev/null)
    fi
}

deploy_vless_reality() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}              [VLESS + Reality]                    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port sni uuid key_pair private_key public_key short_id server_ip vision_flow
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
    state_exists protocol_vless && { echo -e "${YELLOW}[提示]${PLAIN} VLESS + Reality 已经部署。若需更换端口、SNI 或密钥，请先选择“5. 移除协议 / 清理全部”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }
    check_protocol_resources vless || return 1
    vision_flow="xtls-rprx-vision"
    if [[ "$pipeline_mode" != "pipeline" && -z "${VPS_TOOL_PIPELINE:-}" ]]; then
        read -rp "启用 Vision 流控？[Y/n]: " vision_choice
        [[ "$vision_choice" =~ ^[Nn]$ ]] && vision_flow=""
    fi

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
        --arg flow "$vision_flow" \
        '{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid} + (if $flow != "" then {flow:$flow} else {} end)],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private_key,short_id:[$short_id]}}}')

    if ! write_protocol_fragment vless "$fragment_json" || ! regenerate_singbox_config || ! validate_singbox_config; then
        restore_protocol_fragment_transaction vless "$rollback_dir" "$had_fragment" >/dev/null
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} VLESS 协议部署失败，已仅回滚本次协议片段。";
        return 1
    fi
    if ! restart_service_and_verify; then
        restore_protocol_fragment_transaction vless "$rollback_dir" "$had_fragment" >/dev/null
        validate_singbox_config >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        if [[ -f "$CONF_FILE" ]]; then
            systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 回滚后的旧协议服务未能重新启动，请根据上方日志排查。"
        fi
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} sing-box 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" tcp
    state_set protocol_vless 1
    state_set protocol_vless_port "$port"
    local vless_link
    vless_link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp"
    [[ -n "$vision_flow" ]] && vless_link+="&flow=${vision_flow}"
    vless_link+="#VPS-Tool-Reality"
    if ! write_protocol_node_info vless "===================== 节点连接信息 =====================
协议方案: VLESS + Vision + Reality
运行状态: $(protocol_status_text vless)
服务器地址: ${server_ip}
连接端口: ${port}
用户 ID (UUID): ${uuid}
流控: ${vision_flow:-已关闭 Vision}
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
    display_protocol_qr vless
    echo -e "\n${GREEN}[成功]${PLAIN} VLESS + Reality 部署完成。"
}

deploy_hysteria2() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                [Hysteria 2]                       ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port password cert_file key_file server_ip sni="bing.com" hop_range=""
    local fragment rollback_dir had_fragment=0 fragment_json
    default_port=$(get_random_protocol_port udp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 UDP 端口。"; return 1; }
    read -rp "UDP 端口 [回车使用 ${default_port}，范围 1024-65535]: " input_port
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" udp && { echo -e "${RED}[错误]${PLAIN} UDP 端口已被占用。"; return 1; }
    state_exists protocol_hy2 && { echo -e "${YELLOW}[提示]${PLAIN} Hysteria 2 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除协议 / 清理全部”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }
    if [[ -z "${VPS_TOOL_PIPELINE:-}" ]]; then prompt_port_hopping 1; hop_range="${PORT_HOP_RANGE:-}"; else hop_range=""; fi
    check_protocol_resources hy2 || return 1

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
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        if [[ -f "$CONF_FILE" ]]; then
            systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 回滚后的旧协议服务未能重新启动，请根据上方日志排查。"
        fi
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    if [[ -n "$hop_range" ]]; then
        if ! setup_port_hopping hy2 "$hop_range" "$port"; then
            remove_port_hopping hy2 || true
            restore_protocol_fragment_transaction hy2 "$rollback_dir" "$had_fragment" >/dev/null
            systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
            systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
            [[ -f "$CONF_FILE" ]] && systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || true
            rm -rf "$rollback_dir"
            echo -e "${RED}[错误]${PLAIN} Hysteria 2 端口跳跃设置失败，已回滚本次协议。"
            return 1
        fi
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" udp
    state_set protocol_hy2 1
    state_set protocol_hy2_port "$port"
    local hy2_link
    hy2_link="hysteria2://${password}@${server_ip}:${port}/?insecure=1&sni=${sni}"
    [[ -n "$hop_range" ]] && hy2_link+="&mport=${hop_range}"
    hy2_link+="#VPS-Tool-Hysteria2"
    if ! write_protocol_node_info hy2 "===================== 节点连接信息 =====================
协议方案: Hysteria 2
运行状态: $(protocol_status_text hy2)
服务器地址: ${server_ip}
UDP 端口: ${port}
连接密码: ${password}
SNI: ${sni}
端口跳跃: ${hop_range:-未启用}
说明: 使用本工具生成的自签名证书，因此客户端链接包含 insecure=1。

【一键导入分享链接】:
${hy2_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} Hysteria 2 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] Hysteria2 UDP=${port}"
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    cat "$(protocol_node_info_file hy2)"
    display_protocol_qr hy2
    echo -e "\n${GREEN}[成功]${PLAIN} Hysteria 2 部署完成。"
}

deploy_tuic_v5() {
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                 [TUIC v5]                         ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${BLUE}[说明]${PLAIN} 面向游戏/实时 UDP 场景，使用原生 UDP 中继；0-RTT 默认关闭以避免重放风险。"

    local default_port input_port port password uuid cert_file key_file server_ip sni="bing.com" hop_range=""
    local fragment rollback_dir had_fragment=0 fragment_json
    default_port=$(get_random_protocol_port udp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 UDP 端口。"; return 1; }
    read -rp "UDP 端口 [回车使用 ${default_port}，范围 1024-65535]: " input_port
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" udp && { echo -e "${RED}[错误]${PLAIN} UDP 端口已被占用。"; return 1; }
    state_exists protocol_tuic && { echo -e "${YELLOW}[提示]${PLAIN} TUIC v5 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除协议 / 清理全部”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }
    if [[ -z "${VPS_TOOL_PIPELINE:-}" ]]; then prompt_port_hopping 1; hop_range="${PORT_HOP_RANGE:-}"; else hop_range=""; fi
    check_protocol_resources tuic || return 1

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
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        if [[ -f "$CONF_FILE" ]]; then
            systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 回滚后的旧协议服务未能重新启动，请根据上方日志排查。"
        fi
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} sing-box 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    if [[ -n "$hop_range" ]]; then
        if ! setup_port_hopping tuic "$hop_range" "$port"; then
            remove_port_hopping tuic || true
            restore_protocol_fragment_transaction tuic "$rollback_dir" "$had_fragment" >/dev/null
            systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
            systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
            [[ -f "$CONF_FILE" ]] && systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || true
            rm -rf "$rollback_dir"
            echo -e "${RED}[错误]${PLAIN} TUIC 端口跳跃设置失败，已回滚本次协议。"
            return 1
        fi
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" udp
    state_set protocol_tuic 1
    state_set protocol_tuic_port "$port"
    local tuic_link
    tuic_link="tuic://${uuid}:${password}@${server_ip}:${port}/?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1"
    [[ -n "$hop_range" ]] && tuic_link+="&mport=${hop_range}"
    tuic_link+="#VPS-Tool-TUICv5"
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
端口跳跃: ${hop_range:-未启用}
说明: 使用本工具生成的自签名证书，因此客户端链接包含 allow_insecure=1。

【一键导入分享链接】:
${tuic_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} TUIC 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] TUICv5 UDP=${port}"
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] || clear
    cat "$(protocol_node_info_file tuic)"
    display_protocol_qr tuic
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
            systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
            systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
            if [[ -f "$CONF_FILE" ]]; then
                systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 恢复后的协议服务未能重新启动，请根据上方日志排查。"
            fi
            rm -rf "$rollback_dir"
            echo -e "${RED}[错误]${PLAIN} 移除 ${name} 后服务未能按新配置启动，已恢复该协议。"
            return 1
        fi
    fi
    rm -rf "$rollback_dir"
    remove_protocol_resources "$name"
    if [[ -f "${CONF_DIR}/clash.yaml" ]]; then
        if state_exists protocol_vless || state_exists protocol_hy2 || state_exists protocol_tuic; then
            generate_clash_yaml >/dev/null 2>&1 || echo -e "${YELLOW}[提示]${PLAIN} Clash 配置已失效，请重新生成。"
        else
            if is_owned "${CONF_DIR}/clash.yaml"; then rm -f "${CONF_DIR}/clash.yaml"; unmark_owned "${CONF_DIR}/clash.yaml"; fi
        fi
    fi
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

show_protocol_node_info_menu() {
    show_protocol_node_info
    [[ -n "${VPS_TOOL_PIPELINE:-}" ]] && return 0
    if [[ -t 0 ]]; then
        local choice
        if IFS= read -r -p "输入 y 重新显示节点二维码，直接回车返回：[y/N]: " choice; then
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                show_protocol_qr_menu
            fi
        fi
    fi
}

protocol_catalog_is_valid() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    jq -e '(.schema_version | type == "number") and (.tool_version | type == "string") and (.protocols | type == "array") and all(.protocols[]; (.id | type == "string") and (.name | type == "string") and (.adapter_version | type == "number") and (.status | type == "string") and (.implemented | type == "boolean"))' "$file" >/dev/null 2>&1
}

protocol_adapter_version_local() {
    local id="$1" version=""
    if protocol_catalog_is_valid "$PROTOCOL_CATALOG_FILE"; then
        version=$(jq -r --arg id "$id" '.protocols[] | select(.id == $id and .implemented == true) | (.adapter_version | tostring)' "$PROTOCOL_CATALOG_FILE" | head -n1)
        [[ -n "$version" && "$version" != "null" ]] && { echo "$version"; return 0; }
    fi
    case "$id" in
        vless-reality) echo 1 ;;
        hysteria2) echo 1 ;;
        tuic-v5) echo 2 ;;
        *) return 1 ;;
    esac
}

protocol_local_id_exists() {
    local id="$1"
    if protocol_catalog_is_valid "$PROTOCOL_CATALOG_FILE"; then
        jq -e --arg id "$id" '.protocols[] | select(.id == $id and .implemented == true)' "$PROTOCOL_CATALOG_FILE" >/dev/null 2>&1
        return $?
    fi
    case "$id" in
        vless-reality|hysteria2|tuic-v5) return 0 ;;
        *) return 1 ;;
    esac
}

singbox_current_version() {
    if ! resolve_singbox; then
        return 1
    fi
    local output version
    output=$("$SINGBOX_BIN" version 2>&1) || return 2
    version=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?' <<<"$output" | head -n1 || true)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        printf '%s\n' "$version"
        return 0
    fi
    return 2
}

protocol_version_gt() {
    # [修复 Bug] 补齐第 4 组预发版本（如 -rc.1）比对算法，解决模块 2 更新检查从预览版无法更新的假阳性拦截问题。
    local a="$1" b="$2" a1 a2 a3 a4 b1 b2 b3 b4
    [[ "$a" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    a1="${BASH_REMATCH[1]}"; a2="${BASH_REMATCH[2]}"; a3="${BASH_REMATCH[3]}"; a4="${BASH_REMATCH[4]}"
    [[ "$b" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    b1="${BASH_REMATCH[1]}"; b2="${BASH_REMATCH[2]}"; b3="${BASH_REMATCH[3]}"; b4="${BASH_REMATCH[4]}"
    ((10#$a1 > 10#$b1)) && return 0
    ((10#$a1 < 10#$b1)) && return 1
    ((10#$a2 > 10#$b2)) && return 0
    ((10#$a2 < 10#$b2)) && return 1
    ((10#$a3 > 10#$b3)) && return 0
    ((10#$a3 < 10#$b3)) && return 1
    [[ -z "$a4" && -n "$b4" ]] && return 0
    [[ -n "$a4" && -z "$b4" ]] && return 1
    [[ "$a4" > "$b4" ]] && return 0
    return 1
}

protocol_update_check() {
    local tmp remote_tool local_tool singbox_local singbox_latest
    local new_protocols=() adapter_updates=() remote_id remote_name remote_ver local_ver
    local has_update=0 singbox_update=0

    command_exists curl || { echo -e "${RED}[错误]${PLAIN} 未找到 curl，无法检查协议更新。"; return 1; }
    command_exists jq || { echo -e "${RED}[错误]${PLAIN} 未找到 jq，无法安全解析协议更新清单。"; return 1; }

    tmp=$(make_temp_dir protocol-catalog)
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 15 --retry 2 -o "${tmp}/remote.json" "$PROTOCOL_CATALOG_URL"; then
        rm -rf "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法取得远端协议更新清单。"
        return 1
    fi

    if ! protocol_catalog_is_valid "${tmp}/remote.json"; then
        rm -rf "$tmp"
        echo -e "${RED}[错误]${PLAIN} 远端协议更新清单格式无效，已拒绝使用。"
        return 1
    fi

    local_tool="$(cat "${VPS_TOOL_ROOT}/VERSION" 2>/dev/null || true)"
    [[ -n "$local_tool" ]] || local_tool="unknown"
    remote_tool=$(jq -r '.tool_version' "${tmp}/remote.json")

    echo -e "${CYAN}[协议更新检查]${PLAIN} 当前工具：v${local_tool}，远端清单：v${remote_tool}"
    local catalog_time
    catalog_time=$(jq -r '.updated_at // empty' "${tmp}/remote.json")
    [[ -n "$catalog_time" ]] && echo -e "${BLUE}[清单更新时间]${PLAIN} ${catalog_time}"

    while IFS=$'\t' read -r remote_id remote_name remote_ver; do
        [[ -n "$remote_id" ]] || continue
        if ! protocol_local_id_exists "$remote_id"; then
            new_protocols+=("${remote_name}|${remote_id}|v${remote_ver}")
            has_update=1
            continue
        fi
        local_ver=$(protocol_adapter_version_local "$remote_id" 2>/dev/null || true)
        if [[ "$local_ver" =~ ^[0-9]+$ && "$remote_ver" =~ ^[0-9]+$ ]] && (( remote_ver > local_ver )); then
            adapter_updates+=("${remote_name}|${remote_id}|v${local_ver}|v${remote_ver}")
            has_update=1
        fi
    done < <(jq -r '.protocols[] | select(.status != "disabled") | [.id,.name,(.adapter_version | tostring)] | @tsv' "${tmp}/remote.json")

    if [[ "$local_tool" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] && [[ "$remote_tool" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        if protocol_version_gt "$remote_tool" "$local_tool"; then
            echo -e "${YELLOW}[更新可用]${PLAIN} VPS-Tool 可更新：v${local_tool} → v${remote_tool}"
            has_update=1
        fi
    fi

    if singbox_local=$(singbox_current_version 2>/dev/null); then
        if singbox_latest=$(latest_singbox_version 2>/dev/null); then
            echo -e "${BLUE}[sing-box]${PLAIN} 当前：v${singbox_local}，最新稳定：v${singbox_latest}"
            if [[ "$singbox_local" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] && [[ "$singbox_latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] && protocol_version_gt "$singbox_latest" "$singbox_local"; then
                echo -e "${YELLOW}[更新可用]${PLAIN} sing-box 有新稳定版：v${singbox_local} → v${singbox_latest}"
                singbox_update=1
                has_update=1
            fi
        else
            echo -e "${YELLOW}[提示]${PLAIN} 暂时无法取得 sing-box 最新稳定版本，本次跳过内核更新检查。"
        fi
    else
        if resolve_singbox; then
            echo -e "${YELLOW}[提示]${PLAIN} 已检测到 sing-box，但无法解析版本号；请手动执行 \`$SINGBOX_BIN version\` 查看。"
        else
            echo -e "${YELLOW}[提示]${PLAIN} 未检测到可执行的 sing-box，跳过内核更新检查。"
        fi
    fi

    echo
    if ((${#new_protocols[@]} > 0)); then
        echo -e "${YELLOW}发现新协议/协议实现：${PLAIN}"
        local item item_name item_id item_ver
        for item in "${new_protocols[@]}"; do
            IFS='|' read -r item_name item_id item_ver <<< "$item"
            echo "  ★ ${item_name}（${item_id}，适配 ${item_ver}）"
        done
    fi
    if ((${#adapter_updates[@]} > 0)); then
        echo -e "${YELLOW}发现现有协议适配更新：${PLAIN}"
        local update_name update_id update_old update_new
        for item in "${adapter_updates[@]}"; do
            IFS='|' read -r update_name update_id update_old update_new <<< "$item"
            echo "  ↑ ${update_name}：${update_old} → ${update_new}"
        done
    fi

    if (( has_update == 0 )); then
        echo -e "${GREEN}[完成]${PLAIN} 当前协议适配与工具版本均未发现更新。"
        rm -rf "$tmp"
        return 0
    fi

    if ! protocol_version_gt "$remote_tool" "$local_tool" && ((${#new_protocols[@]} > 0 || ${#adapter_updates[@]} > 0)) && (( singbox_update == 0 )); then
        echo -e "${YELLOW}[提示]${PLAIN} 远端协议清单已经变化，但工具版本号尚未提升；为避免覆盖同版本本地文件，本次只报告更新，不强制同步。"
        rm -rf "$tmp"
        return 0
    fi

    if (( singbox_update == 1 )) && ! protocol_version_gt "$remote_tool" "$local_tool" && ((${#new_protocols[@]} == 0 && ${#adapter_updates[@]} == 0)); then
        echo -e "${YELLOW}[提示]${PLAIN} 检测到 sing-box 新版本。当前第 7 项先负责提示，尚未自动替换正在运行的 sing-box。"
        echo -e "${BLUE}[建议]${PLAIN} 请先确认新版本与当前配置兼容，再单独执行内核升级。"
        log_action "[协议更新检查] 检测到 sing-box 新版本：v${singbox_local} -> v${singbox_latest}"
        rm -rf "$tmp"
        return 0
    fi

    echo
    echo -e "${CYAN}[说明]${PLAIN} 更新只会调用 VPS-Tool 自己的安全同步流程，不会执行远端清单中的任意代码或 URL。"
    read -rp "是否立即更新 VPS-Tool 以获取最新协议适配？[y/N]: " confirm_update
    if [[ ! "$confirm_update" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}[取消]${PLAIN} 本次未更新。"
        rm -rf "$tmp"
        return 0
    fi

    if [[ -x "${VPS_TOOL_ROOT}/install.sh" ]]; then
        echo -e "${BLUE}[更新]${PLAIN} 正在通过现有安全更新流程同步最新版..."
        if bash "${VPS_TOOL_ROOT}/install.sh" --update-return; then
            echo -e "${GREEN}[成功]${PLAIN} 更新完成。请重新运行 ${CYAN}vps${PLAIN} 载入新版本模块。"
            log_action "[协议更新] 用户在模块 2 中确认更新，已同步最新工具包"
        else
            echo -e "${RED}[错误]${PLAIN} 更新失败。"
            rm -rf "$tmp"
            return 1
        fi
    else
        echo -e "${RED}[错误]${PLAIN} 找不到本地 VPS-Tool 更新入口：${VPS_TOOL_ROOT}/install.sh"
        rm -rf "$tmp"
        return 1
    fi

    rm -rf "$tmp"
}

disable_protocol_hopping_menu() {
    local choices=() name idx choice
    for name in $(protocol_fragment_names); do
        [[ -n "$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || true)" ]] && choices+=("$name")
    done
    if (( ${#choices[@]} == 0 )); then
        echo -e "${YELLOW}[提示]${PLAIN} 当前没有启用端口跳跃。"
        return 0
    fi
    echo -e "${CYAN}当前启用端口跳跃：${PLAIN}"
    for idx in "${!choices[@]}"; do
        name="${choices[$idx]}"
        echo "  $((idx + 1)). ${name}（$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || echo 未知)）"
    done
    echo "  0. 返回"
    if ! IFS= read -r -p "请选择要关闭的协议 [0-${#choices[@]}]: " choice; then return 1; fi
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 1; }
    (( choice == 0 )) && return 0
    (( choice >= 1 && choice <= ${#choices[@]} )) || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 1; }
    name="${choices[$((choice - 1))]}"
    echo -e "${BLUE}[处理]${PLAIN} 正在撤销 ${name} 的端口跳跃并恢复单端口监听……"
    if ! remove_port_hopping "$name"; then
        echo -e "${RED}[错误]${PLAIN} 端口跳跃撤销没有完全成功；状态记录被保留，请修复后重新执行。"
        return 1
    fi
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    if [[ -f "$CONF_FILE" ]]; then
        if ! validate_singbox_config; then
            echo -e "${RED}[错误]${PLAIN} 当前协议配置校验失败，未自动重启服务。"
            return 1
        fi
        if ! restart_service_and_verify; then
            echo -e "${RED}[错误]${PLAIN} 关闭端口跳跃后服务未能恢复，请查看上方 sing-box 日志。"
            return 1
        fi
    fi
    echo -e "${GREEN}[完成]${PLAIN} ${name} 已关闭端口跳跃并恢复单端口模式。"
}

remove_protocol_menu() {
    remove_or_clean_menu
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
        remove_port_hopping "$name" || true
        file=$(protocol_fragment_file "$name") || continue
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
        file=$(protocol_node_info_file "$name") || continue
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
        state_unset "protocol_${name}"
        state_unset "$(protocol_port_state_key "$name")"
    done
    if is_owned "${CONF_DIR}/clash.yaml"; then rm -f "${CONF_DIR}/clash.yaml"; unmark_owned "${CONF_DIR}/clash.yaml"; fi

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


remove_or_clean_menu() {
    local names=(vless hy2 tuic) name idx choice max
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}        移除协议 / 清理全部                       ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "  ${GREEN}1. 清理全部协议与协议环境（移除本工具创建的所有协议）${PLAIN}"
    echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
    for idx in "${!names[@]}"; do
        name="${names[$idx]}"
        echo -e "  ${GREEN}$((idx + 2)). ${name}（$(protocol_status_text "$name")）${PLAIN}"
    done
    max=$(( ${#names[@]} + 1 ))
    echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
    echo -e "  ${RED}0. 返回${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    read -rp "请选择 [0-${max}]: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 0; }
    (( choice == 0 )) && return 0
    if (( choice == 1 )); then
        uninstall_protocol_environment || true
        return 0
    fi
    if (( choice >= 2 && choice <= max )); then
        name="${names[$((choice - 2))]}"
        if ! state_exists "protocol_${name}"; then
            echo -e "${YELLOW}[提示]${PLAIN} 该协议当前未部署。"
            return 0
        fi
        remove_protocol "$name" || true
        return 0
    fi
    echo -e "${RED}[错误]${PLAIN} 无效选项。"
}

other_and_diagnose_menu() {
    local choice
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              其他与诊断                         ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  ${YELLOW}1. 二维码（显示 / 安装依赖）${PLAIN}"
        echo -e "  ${YELLOW}2. 生成 / 查看 Clash / Mihomo 配置${PLAIN}"
        echo -e "  ${YELLOW}3. 协议诊断（只读）${PLAIN}"
        echo -e "  ${YELLOW}4. 关闭端口跳跃并恢复单端口${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${RED}0. 返回${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-4]: " choice
        case "$choice" in
            1) qr_menu ;;
            2) show_clash_yaml || true; read -rp "按回车继续..." ;;
            3) protocol_diagnose || true; read -rp "按回车继续..." ;;
            4) disable_protocol_hopping_menu || true; read -rp "按回车继续..." ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

protocol_menu() {
    while true; do
        clear
        local status_text choice
        systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null && status_text="${GREEN}运行中${PLAIN}" || status_text="${RED}未运行/未配置${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              [模块 2] 网络协议配置                ${PLAIN}"
        echo -e "服务：${status_text}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  ${GREEN}1. VLESS + Reality${PLAIN}"
        echo -e "  ${GREEN}2. Hysteria 2（支持端口跳跃）${PLAIN}"
        echo -e "  ${GREEN}3. TUIC v5（游戏/实时 UDP）${PLAIN}"
        echo -e "  ${GREEN}4. 查看节点信息${PLAIN}"
        echo -e "  ${GREEN}5. 移除协议 / 清理全部${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${YELLOW}6. 检查协议更新 / 新协议${PLAIN}"
        echo -e "  ${YELLOW}7. 其他与诊断${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${RED}0. 退出${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-7]: " choice
        case "$choice" in
            1) deploy_vless_reality || true; read -rp "按回车继续..." ;;
            2) deploy_hysteria2 || true; read -rp "按回车继续..." ;;
            3) deploy_tuic_v5 || true; read -rp "按回车继续..." ;;
            4) show_protocol_node_info_menu; read -rp "按回车继续..." ;;
            5) remove_or_clean_menu; read -rp "按回车继续..." ;;
            6) protocol_update_check || true; read -rp "按回车继续..." ;;
            7) other_and_diagnose_menu ;;
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
