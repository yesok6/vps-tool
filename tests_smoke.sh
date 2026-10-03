#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ ${EUID} -eq 0 ]] || { echo "smoke tests: please run as root" >&2; exit 1; }

TEST_STATE_ROOT=$(mktemp -d /tmp/vps-tool-smoke.XXXXXX)
trap 'rm -rf "$TEST_STATE_ROOT"' EXIT
export VPS_TOOL_ROOT="$TEST_STATE_ROOT/root"
export VPS_TOOL_ETC="$TEST_STATE_ROOT/etc"
export VPS_TOOL_STATE="$TEST_STATE_ROOT/state"
export VPS_TOOL_BACKUPS="$TEST_STATE_ROOT/backups"
export VPS_TOOL_LOG="$TEST_STATE_ROOT/install.log"
source "$ROOT/lib/common.sh"

for f in "$ROOT/install.sh" "$ROOT/lib/common.sh" "$ROOT/modules/"*.sh; do
    bash -n "$f"
done

# 1. apps.sh 不应 source 其它业务模块，避免跨模块隐式依赖。
! grep -Eq '^source .*modules/(security|optimize|protocol)\.sh' "$ROOT/modules/apps.sh"

# 2. confirm_safety_prompt 由 lib/common.sh 提供。
grep -q '^confirm_safety_prompt()' "$ROOT/lib/common.sh"
grep -q 'confirm_safety_prompt' "$ROOT/modules/optimize.sh"

# 3. ip_test.sh 必须捕获第三方脚本真实退出码，不能使用 if ! ...; then rc=$?。
! grep -q 'if ! ( cd .*&& bash ' "$ROOT/modules/ip_test.sh"
grep -q 'if ( cd .*&& bash ' "$ROOT/modules/ip_test.sh"

# 4. sysctl 载入采用 sysctl -p。
! grep -R -- '--load' "$ROOT/modules" >/dev/null
grep -R -q 'sysctl -p' "$ROOT/modules/optimize.sh"

# 5. 关键回滚提示应保留中文原有命名语义。
grep -q 'BBR 暴躁/疯批模式' "$ROOT/modules/optimize.sh"
grep -q '一键全自动综合装配流水线' "$ROOT/modules/apps.sh"
grep -q '系统清理与还原审计' "$ROOT/install.sh"

# 6. Hysteria2 证书/私钥必须记录为本工具创建的资源，以便精确清理。
grep -q 'mark_owned "$cert_file"' "$ROOT/modules/protocol.sh"
grep -q 'mark_owned "$key_file"' "$ROOT/modules/protocol.sh"
# 6b. TUIC v5 必须使用原生 UDP、关闭 0-RTT，并记录证书/私钥所有权。
grep -q '^deploy_tuic_v5()' "$ROOT/modules/protocol.sh"
grep -q 'udp_relay_mode=native' "$ROOT/modules/protocol.sh"
grep -q 'zero_rtt_handshake:false' "$ROOT/modules/protocol.sh"
grep -q 'congestion_control:"bbr"' "$ROOT/modules/protocol.sh"
grep -q 'tuic_cert.pem' "$ROOT/modules/protocol.sh"
grep -q 'tuic_key.pem' "$ROOT/modules/protocol.sh"

# 7. install_singbox 不应使用 EXIT trap 依赖函数局部临时目录。
! awk '/install_singbox\(\)/,/^}/ { if ($0 ~ /trap .*EXIT/) found=1 } END { exit found ? 0 : 1 }' "$ROOT/modules/protocol.sh"

# 8. BBRv3 Max 使用 jq 解析 GitHub JSON，并由 apt 负责本地 deb 依赖解析。
grep -q 'jq -r --arg arch' "$ROOT/modules/optimize.sh"
grep -qF 'apt-get install -y "${tmp}"/*.deb' "$ROOT/modules/optimize.sh"
! grep -q 'dpkg -i' "$ROOT/modules/optimize.sh"

# 9. 在线版本检查支持开关，并校验版本号格式。
grep -q 'VPS_TOOL_VERSION_CHECK' "$ROOT/install.sh"
grep -q 'remote.*=~' "$ROOT/install.sh"

# 10. 流水线协议部署必须跳过端口交互式输入。
grep -q -- '--pipeline-reality) deploy_vless_reality pipeline' "$ROOT/modules/protocol.sh"
grep -q '无需手动输入' "$ROOT/modules/protocol.sh"
# 10b. 模块二菜单必须暴露 TUIC v5。
grep -q '3\. TUIC v5' "$ROOT/modules/protocol.sh"
grep -q 'deploy_tuic_v5 || true' "$ROOT/modules/protocol.sh"

# 11. 防火墙回滚统一走 firewall_remove_owned_rules，兼容单条与全部清理。
grep -q '^firewall_remove_owned_rule()' "$ROOT/lib/common.sh"
grep -q '^firewall_remove_owned_rules()' "$ROOT/lib/common.sh"
grep -qF 'firewall_remove_owned_rules "$new_port" tcp' "$ROOT/modules/security.sh"

action_guard_count=$(grep -cF 'firewall_remove_owned_rules "$new_port" tcp || true' "$ROOT/modules/security.sh")
[[ "$action_guard_count" -ge 2 ]]

# 12. security.sh 的 SSH 失败路径必须清理临时 action_dir。
grep -q 'rm -rf "$action_dir"' "$ROOT/modules/security.sh"

# 13. 小型死代码/实现回归检查。
! grep -q 'after_service_install' "$ROOT/modules/protocol.sh"
! grep -q 'checksum_file' "$ROOT/modules/protocol.sh"
grep -q 'local confirm' "$ROOT/lib/common.sh"
grep -q '^extract_singbox_checksum()' "$ROOT/modules/protocol.sh"
grep -q 'github_release_api_json' "$ROOT/modules/protocol.sh"
! grep -q 'for name in sha256sums.txt sha256sums SHA256SUMS checksums.txt' "$ROOT/modules/protocol.sh"

# 14. 关键回滚路径不能因 set -e 意外中断。
grep -qF 'restore_runtime_values || true' "$ROOT/modules/optimize.sh"
! grep -qF '[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot' "$ROOT/modules/optimize.sh"
grep -qF 'if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then' "$ROOT/modules/optimize.sh"

# 15. 流水线环境变量必须按命令隔离，不能污染 apps.sh 调用方。
! grep -q '^    export VPS_TOOL_PIPELINE=1$' "$ROOT/modules/apps.sh"
grep -qF 'VPS_TOOL_PIPELINE=1 bash "${SCRIPT_DIR}/optimize.sh" --pipeline-network' "$ROOT/modules/apps.sh"
grep -qF 'VPS_TOOL_PIPELINE=1 bash "${SCRIPT_DIR}/protocol.sh" --pipeline-reality' "$ROOT/modules/apps.sh"

# 16. 运行时参数恢复失败时必须保留备份记录，不能静默删除。
grep -qF '原始记录已保留' "$ROOT/lib/common.sh"
! grep -qF 'cat "${dir}/${id}.value" > "$path" 2>/dev/null || true' "$ROOT/lib/common.sh"

# 17. 运行时断言：烟雾测试的状态必须写入临时目录，不能污染真实 /etc/vps-tool。
smoke_runtime_key="smoke_runtime_marker"
smoke_runtime_path=$(state_key_file "$smoke_runtime_key")
state_set "$smoke_runtime_key" "1"
[[ -f "$smoke_runtime_path" ]]
[[ "$smoke_runtime_path" == "$TEST_STATE_ROOT/state/${smoke_runtime_key}" ]]
[[ ! -e "/etc/vps-tool/${smoke_runtime_key}" ]]
state_unset "$smoke_runtime_key"

# 18. confirm_safety_prompt 取消必须返回失败状态。
if printf 'n\n' | bash -c 'set -Eeuo pipefail; source "$1"; confirm_safety_prompt "测试操作" "测试风险说明"' _ "$ROOT/lib/common.sh"; then
    echo 'confirm_safety_prompt cancellation unexpectedly returned success' >&2
    exit 1
fi

# 19a. 模块菜单取消必须停留在当前模块，不能因 set -e 直接退出模块子进程。
# 19b. 四个交互模块的菜单调用必须吞掉“用户取消/操作失败”的非零返回，避免 set -e 退出整个模块。
grep -qF '1) change_ssh_port || true;' "$ROOT/modules/security.sh"
grep -qF '2) remove_old_ssh_port || true;' "$ROOT/modules/security.sh"
grep -qF '4) cancel_ssh_port_migration || true;' "$ROOT/modules/security.sh"
grep -qF '1) apply_production_tune || true;' "$ROOT/modules/optimize.sh"
grep -qF '1) deploy_vless_reality || true;' "$ROOT/modules/protocol.sh"
grep -qF '1) run_test_ipquality || true;' "$ROOT/modules/ip_test.sh"

# security_menu：第 1 项取消后，必须还能读取下一次菜单选择 0。
printf '1\n\n0\n' | bash -c '
    set -Eeuo pipefail
    source "$1"
    clear(){ :; }
    check_os(){ OS_PRETTY=test ARCH=test return 0; }
    retry_pending_ssh_firewall_cleanup(){ return 0; }
    get_current_ssh_port(){ echo 22; }
    sys_full_upgrade(){ return 1; }
    security_menu >/dev/null 2>&1
' _ "$ROOT/modules/security.sh"
# optimize_menu：取消第 1 项后仍能返回菜单并选择 0。
printf '1\n\n0\n' | bash -c '
    set -Eeuo pipefail
    source "$1"
    clear(){ :; }
    show_dashboard(){ :; }
    apply_production_tune(){ return 1; }
    optimize_menu >/dev/null 2>&1
' _ "$ROOT/modules/optimize.sh"
# protocol_menu：取消部署后仍能返回菜单并选择 0。
printf '1\n\n0\n' | bash -c '
    set -Eeuo pipefail
    source "$1"
    clear(){ :; }
    systemctl(){ return 0; }
    deploy_vless_reality(){ return 1; }
    protocol_menu >/dev/null 2>&1
' _ "$ROOT/modules/protocol.sh"
# ip_test_menu：第三方测试取消后仍能返回菜单并选择 0。
printf '1\n\n0\n' | bash -c '
    set -Eeuo pipefail
    source "$1"
    clear(){ :; }
    run_test_ipquality(){ return 1; }
    ip_test_menu >/dev/null 2>&1
' _ "$ROOT/modules/ip_test.sh"

# 20. 增项 1：多协议片段化/共存/单协议移除/损坏片段不得覆盖旧 config。
grep -q '^write_protocol_fragment()' "$ROOT/modules/protocol.sh"
grep -q '^regenerate_singbox_config()' "$ROOT/modules/protocol.sh"
grep -q '^remove_protocol_fragment()' "$ROOT/modules/protocol.sh"
grep -q 'node_info_vless.txt' "$ROOT/modules/protocol.sh"
grep -q 'node_info_hy2.txt' "$ROOT/modules/protocol.sh"
grep -q 'node_info_tuic.txt' "$ROOT/modules/protocol.sh"
grep -q 'state_set protocol_vless' "$ROOT/modules/protocol.sh"
grep -q 'state_set protocol_hy2' "$ROOT/modules/protocol.sh"
grep -q 'state_set protocol_tuic' "$ROOT/modules/protocol.sh"
grep -q 'remove_protocol_menu' "$ROOT/modules/protocol.sh"
(
    proto_test_root=$(mktemp -d /tmp/vps-tool-protocol-smoke.XXXXXX)
    trap 'rm -rf "$proto_test_root"' EXIT
    export VPS_TOOL_ROOT="$proto_test_root/root"
    export VPS_TOOL_ETC="$proto_test_root/etc"
    export VPS_TOOL_STATE="$proto_test_root/state"
    export VPS_TOOL_BACKUPS="$proto_test_root/backups"
    export VPS_TOOL_LOG="$proto_test_root/install.log"
    mkdir -p "$VPS_TOOL_ROOT" "$VPS_TOOL_ETC" "$VPS_TOOL_STATE" "$VPS_TOOL_BACKUPS"
    source "$ROOT/modules/protocol.sh"
    CONF_DIR="$proto_test_root/sing-box"
    CONF_FILE="$CONF_DIR/config.json"
    NODE_INFO_FILE="$CONF_DIR/node_info.txt"
    SERVICE_FILE="$proto_test_root/vps-tool-sing-box.service"
    mkdir -p "$CONF_DIR"
    chown(){ :; }
    systemctl(){ case "$1" in is-active|is-enabled) return 1 ;; stop|disable|daemon-reload) return 0 ;; *) return 0 ;; esac; }

    vless_fragment='{"type":"vless","tag":"vless-in","listen":"::","listen_port":10001,"users":[],"tls":{"enabled":true}}'
    hy2_fragment='{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":10002,"users":[],"tls":{"enabled":true}}'
    write_protocol_fragment vless "$vless_fragment"
    is_owned "$CONF_DIR/vless.json"
    regenerate_singbox_config
    write_protocol_fragment hy2 "$hy2_fragment"
    regenerate_singbox_config
    [[ $(jq '[.inbounds[].tag] | length' "$CONF_FILE") -eq 2 ]]
    jq -e '([.inbounds[].tag] | sort) == ["hy2-in","vless-in"]' "$CONF_FILE" >/dev/null
    remove_protocol_fragment hy2
    jq -e '([.inbounds[].tag] | . == ["vless-in"])' "$CONF_FILE" >/dev/null
    [[ -f "$CONF_DIR/vless.json" ]]
    [[ ! -f "$CONF_DIR/hy2.json" ]]

    cp "$CONF_FILE" "$proto_test_root/config-good.json"
    printf '%s\n' '{bad-json' > "$CONF_DIR/vless.json"
    if regenerate_singbox_config >/dev/null 2>&1; then
        echo 'corrupt protocol fragment unexpectedly returned success' >&2
        exit 1
    fi
    cmp -s "$CONF_FILE" "$proto_test_root/config-good.json"
)

# 20b. 本测试脚本本身不允许留下真实 VPS 工具状态目录。
[[ ! -e /etc/vps-tool/smoke-test-marker ]]


# 21. 系统升级用户取消必须返回失败状态，避免流水线误判为成功。
if printf 'n\n' | bash -c 'set -Eeuo pipefail; source "$1"; check_os(){ PKG_MANAGER=apt; SSH_SERVICE=ssh; return 0; }; sys_full_upgrade' _ "$ROOT/lib/common.sh"; then
    echo 'sys_full_upgrade cancellation unexpectedly returned success' >&2
    exit 1
fi

# 22. 防火墙记录删除失败时不能提前删除状态记录。
grep -qF '保留记录以便后续重试' "$ROOT/lib/common.sh"

# 23. 第三方诊断取消不应伪装成成功。
grep -qF '[取消]${PLAIN} 未执行第三方脚本。' "$ROOT/modules/ip_test.sh"
grep -qF 'return 1' "$ROOT/modules/ip_test.sh"


# 24. round22 补丁：版本号提升到 2.4.0；协议监听优先取 config.json，且不依赖 ss 固定字段号。
grep -q '^CURRENT_VERSION="2.9.3"$' "$ROOT/install.sh"

# Round26: v2rayN TUIC share-link compatibility.
grep -q 'tuic_link="tuic://.*sni=\${sni}&allow_insecure=1' "$ROOT/modules/protocol.sh"
grep -q 'tuic_link+="#VPS-Tool-TUICv5"' "$ROOT/modules/protocol.sh"
grep -q 'congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=\${sni}&allow_insecure=1' "$ROOT/modules/protocol.sh"
if grep -q 'tuic_link="tuic://.*&insecure=1&sni=' "$ROOT/modules/protocol.sh"; then
    echo "legacy TUIC insecure=1 link format must not be generated" >&2
    exit 1
fi
grep -qF 'port=$(jq -r --arg tag "${name}-in"' "$ROOT/modules/protocol.sh"
grep -qF 'for (i = 1; i <= NF; i++)' "$ROOT/modules/protocol.sh"
! grep -qF '$5 ~ p' "$ROOT/modules/protocol.sh"
# 同一协议重复部署仍要求先移除：本轮采用补丁 3 的方案 B，避免扩大证书/密钥回滚范围。
grep -q 'VLESS + Reality 已经部署。若需更换端口、SNI 或密钥，请先选择“5. 移除协议 / 清理全部”' "$ROOT/modules/protocol.sh"
grep -q 'Hysteria 2 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除协议 / 清理全部”' "$ROOT/modules/protocol.sh"
grep -q 'TUIC v5 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除协议 / 清理全部”' "$ROOT/modules/protocol.sh"
# 旧版 node_info.txt 不再由卸载流程恢复。
! grep -qF 'restore_file_backup "$NODE_INFO_FILE" protocol_node_info' "$ROOT/modules/protocol.sh"
grep -qF '检测到旧版节点信息文件' "$ROOT/modules/protocol.sh"

# 24a. protocol_listener_is_up：配置端口优先于 state，且能识别 TCP/UDP 本地监听地址。
(
    listener_test_root=$(mktemp -d /tmp/vps-tool-listener-smoke.XXXXXX)
    trap 'rm -rf "$listener_test_root"' EXIT
    export VPS_TOOL_ROOT="$listener_test_root/root"
    export VPS_TOOL_ETC="$listener_test_root/etc"
    export VPS_TOOL_STATE="$listener_test_root/state"
    export VPS_TOOL_BACKUPS="$listener_test_root/backups"
    export VPS_TOOL_LOG="$listener_test_root/install.log"
    mkdir -p "$VPS_TOOL_ROOT" "$VPS_TOOL_ETC" "$VPS_TOOL_STATE" "$VPS_TOOL_BACKUPS"
    source "$ROOT/modules/protocol.sh"
    CONF_DIR="$listener_test_root/sing-box"
    CONF_FILE="$CONF_DIR/config.json"
    mkdir -p "$CONF_DIR"
    printf '%s\n' '{"inbounds":[{"type":"vless","tag":"vless-in","listen_port":12345}]}' > "$CONF_FILE"
    state_set protocol_vless_port 54321
    listener_bin="$listener_test_root/bin"
    mkdir -p "$listener_bin"
    cat > "$listener_bin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'tcp LISTEN 0 128 0.0.0.0:12345 0.0.0.0:* users:(("sing-box",pid=1,fd=3))'
EOF
    chmod +x "$listener_bin/ss"
    PATH="$listener_bin:$PATH"
    export PATH
    protocol_listener_is_up vless
)

# 25. 已安装的本地 install.sh 启动时不得静默 sync_bundle；更新应通过选项 8。
grep -qF 'current_script_path=$(readlink -f -- "${BASH_SOURCE[0]}")' "$ROOT/install.sh"
grep -qF 'local_install_path=$(readlink -f -- "${LOCAL_ROOT}/install.sh")' "$ROOT/install.sh"
grep -qF '    # 首次通过网络脚本启动时同步完整本地工具包；已安装版本启动时不再静默更新。' "$ROOT/install.sh"

# 26. 顶层防火墙单条删除 helper 应按后端参数校验并返回失败，而不是异常成功。
if firewall_remove_owned_rule invalid_backend 65535 tcp; then
    echo 'firewall_remove_owned_rule unexpectedly accepted an invalid backend' >&2
    exit 1
fi

# 27. 路径规范化应让同一实际文件的不同符号链接解析到相同目标。
path_link="$TEST_STATE_ROOT/install-link.sh"
ln -s "$ROOT/install.sh" "$path_link"
normalized_link=$(readlink -f -- "$path_link")
normalized_root=$(readlink -f -- "$ROOT/install.sh")
[[ "$normalized_link" == "$normalized_root" ]]


# 28. SSH 端口迁移只保留“保留旧端口 / 手动删除旧端口 / 回退”三种操作。
grep -qF '1) change_ssh_port || true;' "$ROOT/modules/security.sh"
grep -qF '2) remove_old_ssh_port || true;' "$ROOT/modules/security.sh"
grep -qF '4) cancel_ssh_port_migration || true;' "$ROOT/modules/security.sh"
! grep -qF 'change_ssh_port 2' "$ROOT/modules/security.sh"
! grep -qF 'wait_for_new_ssh_session' "$ROOT/modules/security.sh"
! grep -qF '新端口真实登录后自动删除旧端口' "$ROOT/modules/security.sh"

# 28. 当前会话端口识别必须来自 SSH_CONNECTION。
SSH_CONNECTION='198.51.100.20 54321 192.0.2.10 34567' bash -c 'source "$1"; [[ "$(current_ssh_session_port)" == "34567" ]]; current_ssh_session_uses_port 34567' _ "$ROOT/modules/security.sh"

# 29. SSH 双端口配置必须保留原有其它全局 Port，并保留 Match 块。
ssh_cfg="$TEST_STATE_ROOT/sshd_config.test"
cat > "$ssh_cfg" <<'EOF'
Port 22
Port 2200
PermitRootLogin yes

Match User test
    Port 2201
EOF
bash -c 'source "$1"; SSHD_CONFIG="$2"; set_sshd_ports_global 22 34567; grep -qx "Port 22" "$SSHD_CONFIG"; grep -qx "Port 34567" "$SSHD_CONFIG"; grep -qx "Port 2200" "$SSHD_CONFIG"; grep -q "^Match User test$" "$SSHD_CONFIG"; grep -q "^    Port 2201$" "$SSHD_CONFIG"' _ "$ROOT/modules/security.sh" "$ssh_cfg"

# 30. SSH Port 指令的空格/等号两种写法都必须被规范化，避免留下脏的 Port= 配置。
ssh_cfg_eq="$TEST_STATE_ROOT/sshd_config.port-equals.test"
cat > "$ssh_cfg_eq" <<'EOF'
Port=22
Port = 2200
PermitRootLogin yes

Match User test
    Port=2201
EOF
bash -c 'source "$1"; SSHD_CONFIG="$2"; set_sshd_ports_global 22 34567; grep -qx "Port 22" "$SSHD_CONFIG"; grep -qx "Port 34567" "$SSHD_CONFIG"; grep -qx "Port 2200" "$SSHD_CONFIG"; ! grep -qE "^[[:space:]]*Port[[:space:]]*=" "$SSHD_CONFIG"; grep -q "^Match User test$" "$SSHD_CONFIG"; grep -q "^    Port=2201$" "$SSHD_CONFIG"' _ "$ROOT/modules/security.sh" "$ssh_cfg_eq"

# 31. SSH 迁移必须提供安全回退菜单项，且不再保留自动删除旧端口的实现。
grep -q '放弃本次迁移并恢复原 SSH 端口' "$ROOT/modules/security.sh"
grep -q '^cancel_ssh_port_migration()' "$ROOT/modules/security.sh"
! grep -qF 'cancel_ssh_port_migration 1' "$ROOT/modules/security.sh"

# 35. 防火墙重复进入时应先展示当前状态；已启用后不应再次询问“立即启用”。
grep -q '^firewall_show_allowed()' "$ROOT/modules/security.sh"
grep -q 'UFW 已启用。' "$ROOT/modules/security.sh"
grep -q 'firewalld 已运行。' "$ROOT/modules/security.sh"
grep -q '基线规则已补充并立即生效' "$ROOT/modules/security.sh"
! grep -q '以后再次进入本选项将只展示当前状态' "$ROOT/modules/security.sh"

# 36. README 必须包含迁移回退与防火墙状态式流程说明。
grep -q '模块 1 → 3 → 4 放弃迁移并恢复原端口' "$ROOT/README.md"
grep -q '只展示当前已放行的端口' "$ROOT/README.md"

# 37. SSH endpoint 解析需覆盖 IPv4、标准方括号 IPv6 与极端未加方括号 IPv6。
[[ "$(bash -c 'source "$1"; ssh_endpoint_host "198.51.100.20:34567"' _ "$ROOT/modules/security.sh")" == "198.51.100.20" ]]
[[ "$(bash -c 'source "$1"; ssh_endpoint_host "[2001:db8::20]:34567"' _ "$ROOT/modules/security.sh")" == "2001:db8::20" ]]
[[ "$(bash -c 'source "$1"; ssh_endpoint_host "2001:db8::20:34567"' _ "$ROOT/modules/security.sh")" == "2001:db8::20" ]]

# 38. firewalld 已通过 http service 放行时，80/tcp 应被视为已具备基线。
firewall_stub_dir="$TEST_STATE_ROOT/firewall-stub"
mkdir -p "$firewall_stub_dir"
cat > "$firewall_stub_dir/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--query-port=80/tcp*) exit 1 ;;
  *--query-service=http*) exit 0 ;;
  *--query-service=https*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$firewall_stub_dir/firewall-cmd"
PATH="$firewall_stub_dir:$PATH" bash -c 'source "$1"; firewall_rule_exists firewalld 80 tcp' _ "$ROOT/modules/security.sh"

# 39. 回退时若防火墙清理失败，迁移 state 必须继续保留，避免用户失去后续重试入口。
grep -q 'if ! firewall_remove_owned_rules' < <(awk '/cancel_ssh_port_migration\(\)/,/^}/' "$ROOT/modules/security.sh")

# 40. firewall_allow 在 firewalld 已存在 http service 时不得重复创建 80/tcp 端口规则或留下工具记录。
firewall_stub_dir2="$TEST_STATE_ROOT/firewall-allow-stub"
mkdir -p "$firewall_stub_dir2"
cat > "$firewall_stub_dir2/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--state*) printf 'running\n'; exit 0 ;;
  *--query-port=80/tcp*) exit 1 ;;
  *--query-service=http*) exit 0 ;;
  *--permanent*--add-port=*) echo "unexpected add-port" >&2; exit 99 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$firewall_stub_dir2/firewall-cmd"
PATH="$firewall_stub_dir2:$PATH" bash -c 'source "$1"; VPS_TOOL_STATE="$2"; mkdir -p "$VPS_TOOL_STATE/firewall"; firewall_allow 80 tcp; ! compgen -G "$VPS_TOOL_STATE/firewall/*.rule" >/dev/null' _ "$ROOT/lib/common.sh" "$TEST_STATE_ROOT/firewall-state"



# 41. 防火墙端口管理必须支持 SSH 22 等特权端口，同时协议端口校验仍保持高端口范围。
if ! validate_port_any 22 || ! validate_port_any 65535 || validate_port_any 0 || validate_port_any 65536; then
    echo 'validate_port_any boundary test failed' >&2
    exit 1
fi
# firewall_allow / firewall_remove_owned_rules 不应再拒绝 22/tcp。
grep -q 'validate_port_any' < <(grep -A8 '^firewall_allow()' "$ROOT/lib/common.sh")
grep -q 'validate_port_any' < <(grep -A12 '^firewall_remove_owned_rules()' "$ROOT/lib/common.sh")

# 42. 系统升级前必须显示资源检查，并使用分级资源阈值。
grep -q '^check_upgrade_resources()' "$ROOT/lib/common.sh"
grep -q 'mem_mb >= 256' "$ROOT/lib/common.sh"
grep -q 'mem_mb >= 128' "$ROOT/lib/common.sh"
grep -q 'disk_mb < 1024' "$ROOT/lib/common.sh"
grep -q 'recommend_managed_swap_mb' "$ROOT/lib/common.sh"
grep -q '^recommend_managed_swap_mb()' "$ROOT/lib/common.sh"
grep -q '^ensure_managed_swap_1g()' "$ROOT/lib/common.sh"

# 43. 主菜单版本检查必须使用缓存，避免每次打开都等待网络。
grep -q 'remote_version.cache' "$ROOT/install.sh"
grep -q 'VPS_TOOL_VERSION_CACHE_TTL' "$ROOT/install.sh"

# 44. 防火墙必须提供查看/新增/禁用端口三个入口。
grep -q '^firewall_port_manager_menu()' "$ROOT/modules/security.sh"
grep -q 'firewall_manage_add' "$ROOT/modules/security.sh"
grep -q 'firewall_manage_disable' "$ROOT/modules/security.sh"
grep -q 'firewall_show_open_ports' "$ROOT/modules/security.sh"

# 45. SSH 旧端口删除后必须进入防火墙清理闭环；失败时保留待清理状态。
grep -q 'ssh_migration_firewall_cleanup_pending' "$ROOT/modules/security.sh"
grep -q 'firewall_close_port_rule' "$ROOT/modules/security.sh"
grep -qF 'validate_port_any "$old_port" || { state_unset ssh_migration_firewall_cleanup_pending; return 0; }' "$ROOT/modules/security.sh"

# 46. 防火墙服务端口比较必须按端口列表精确判断，避免原来的字符串比较永远为真。
grep -q 'service_port_list' "$ROOT/modules/security.sh"
grep -Fq 'if ((${#service_port_list[@]} != 1)) || [[ "${service_port_list[0]:-}" != "${rule}" ]]; then' "$ROOT/modules/security.sh"
# 46a. 单端口 service 的运行时禁用应继续走 service 删除路径；不能被错误的字符串空格比较拦截。
service_test_dir="$TEST_STATE_ROOT/service-disable-stub"
mkdir -p "$service_test_dir"
cat > "$service_test_dir/ufw" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"app info websvc"*) printf 'Profile: websvc\n80/tcp\n'; exit 0 ;;
  *"delete allow websvc"*) printf '%s\n' "$*" > "${SERVICE_DELETE_LOG:?}"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$service_test_dir/ufw"
SERVICE_DELETE_LOG="$TEST_STATE_ROOT/service-delete.log" PATH="$service_test_dir:$PATH" bash -c '
  source "$1"
  firewall_open_port_entries() { printf "80/tcp|UFW 服务:websvc\n"; }
  firewall_backend() { echo ufw; }
  get_current_ssh_port() { echo 22; }
  confirm_safety_prompt() { return 0; }
  firewall_rule_exists() { return 1; }
  firewall_manage_disable ufw <<< "1" >/dev/null
' _ "$ROOT/modules/security.sh"
grep -qF 'delete allow websvc' "$TEST_STATE_ROOT/service-delete.log"
# firewall_open_port_entries 的临时目录必须有自动清理兜底。
grep -Fq "trap 'rm -rf -- \"\$tmp\"' RETURN" "$ROOT/modules/security.sh"

# 47. Swap 推荐大小按磁盘余量动态计算：1.25/1.5/1.75/2.0 GiB 分别最多推荐 256/512/768/1024 MiB。
for spec in "1280 256" "1536 512" "1792 768" "2048 1024" "1100 0"; do
  set -- $spec
  got=$(DISK_MB="$1" bash -c '
    source "$1"
    get_root_free_mb() { echo "$DISK_MB"; }
    current_swap_mb() { echo 0; }
    recommend_managed_swap_mb
  ' _ "$ROOT/lib/common.sh")
  [[ "$got" == "$2" ]] || { echo "unexpected swap recommendation: disk=$1 got=$got want=$2" >&2; exit 1; }
done

# 48. 低内存 + 1.5 GiB 磁盘时推荐 512 MiB Swap，并保留至少 1 GiB 磁盘。
bash -c '
  source "$1"
  get_mem_available_mb() { echo 200; }
  get_root_free_mb() { echo 1536; }
  current_swap_mb() { echo 0; }
  confirm_safety_prompt() { return 0; }
  ensure_managed_swap() { return 0; }
  check_upgrade_resources
' _ "$ROOT/lib/common.sh"

# 49. Fail2Ban SSH 防爆破：实际生成 jail 配置，验证端口、阈值、封禁时长与当前来源 IP 忽略项。
f2b_test_dir="$TEST_STATE_ROOT/fail2ban"
mkdir -p "$f2b_test_dir/bin"
cat > "$f2b_test_dir/bin/fail2ban-client" <<'F2BCLIENT'
#!/usr/bin/env bash
case "${1:-}" in
  -t) exit 0 ;;
  reload) exit 0 ;;
  status) exit 0 ;;
  set) exit 0 ;;
  stop) exit 0 ;;
  *) exit 0 ;;
esac
F2BCLIENT
cat > "$f2b_test_dir/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
exit 0
SYSTEMCTL
chmod +x "$f2b_test_dir/bin/fail2ban-client" "$f2b_test_dir/bin/systemctl"
VPS_TOOL_STATE="$f2b_test_dir/state-enable" FAIL2BAN_CONFIG="$f2b_test_dir/vps-tool-sshd.local" \
PATH="$f2b_test_dir/bin:$PATH" \
bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  check_os() { PKG_MANAGER=apt; OS_PRETTY="test"; return 0; }
  firewall_backend() { echo none; }
  fail2ban_detect_log_config() { printf "%s\\n" "backend = systemd" "journalmatch = _COMM=sshd + _COMM=sshd-session"; }
  fail2ban_detect_banaction() { :; }
  get_current_ssh_ports() { printf "22\\n2222\\n"; }
  ssh_current_source_ip() { echo 203.0.113.10; }
  confirm_safety_prompt() { return 0; }
  fail2ban_enable_ssh_protection
  grep -q "port = 22,2222" "$FAIL2BAN_CONFIG"
  grep -q "findtime = 10m" "$FAIL2BAN_CONFIG"
  grep -q "maxretry = 5" "$FAIL2BAN_CONFIG"
  grep -q "bantime = 1d" "$FAIL2BAN_CONFIG"
  grep -q "203.0.113.10" "$FAIL2BAN_CONFIG"
' _ "$ROOT"

# 50. SSH 成功登录 IP：重复 IP 合并，并按最近一次成功登录时间倒序。
ssh_login_test_dir="$TEST_STATE_ROOT/ssh-login"
mkdir -p "$ssh_login_test_dir/bin"
cat > "$ssh_login_test_dir/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
cat <<'LOG'
2026-10-03T09:00:00+0800 host sshd[1]: Accepted publickey for root from 198.51.100.10 port 50001 ssh2
2026-10-03T09:10:00+0800 host sshd[2]: Accepted password for root from 203.0.113.7 port 50002 ssh2
2026-10-03T09:20:00+0800 host sshd[3]: Accepted publickey for root from 198.51.100.10 port 50003 ssh2
LOG
EOF
chmod +x "$ssh_login_test_dir/bin/journalctl"
login_raw=$(PATH="$ssh_login_test_dir/bin:$PATH" bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  ssh_success_login_entries
' _ "$ROOT")
login_view=$(printf '%s\n' "$login_raw" | awk -F'|' '{ip=$2; if (!(ip in latest) || $1 > latest[ip]) latest[ip]=$1; count[ip]++} END {for (ip in latest) print latest[ip] "|" ip "|" count[ip]}' | sort -t'|' -k1,1r)
awk 'NR==1 {exit ($0 ~ /198\.51\.100\.10/ ? 0 : 1)}' <<< "$login_view"
awk 'NR==2 {found=($0 ~ /203\.0\.113\.7/)} END {exit (found ? 0 : 1)}' <<< "$login_view"
awk 'NR==1 {found=($0 ~ /\|2$/)} END {exit (found ? 0 : 1)}' <<< "$login_view"

# 51. Fail2Ban 状态页：中文三段摘要、当前保护端口、近 5 分钟去重封禁日志。
f2b_status_dir="$TEST_STATE_ROOT/fail2ban-status"
mkdir -p "$f2b_status_dir/bin"
cat > "$f2b_status_dir/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    if [[ "${2:-}" == "vps-tool-sshd" ]]; then
      cat <<'OUT'
Status for the jail: vps-tool-sshd
|- Currently failed: 0
|- Total failed: 12
|- Currently banned: 2
|- Total banned: 4
`- Banned IP list: 198.51.100.8 203.0.113.9
OUT
      exit 0
    fi
    exit 1
    ;;
  -t|reload|set|stop) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$f2b_status_dir/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
cat <<'LOG'
2026-10-03T09:56:00+0800 host fail2ban[1]: NOTICE [vps-tool-sshd] Ban 198.51.100.8
2026-10-03T09:57:00+0800 host fail2ban[2]: NOTICE [vps-tool-sshd] Ban 198.51.100.8
2026-10-03T09:58:00+0800 host fail2ban[3]: NOTICE [vps-tool-sshd] Ban 203.0.113.9
LOG
EOF
chmod +x "$f2b_status_dir/bin/fail2ban-client" "$f2b_status_dir/bin/journalctl"
status_view=$(TERM=xterm VPS_TOOL_STATE="$f2b_status_dir/state" FAIL2BAN_CONFIG="$f2b_status_dir/vps-tool-sshd.local" PATH="$f2b_status_dir/bin:$PATH" bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  get_current_ssh_ports() { printf "22\n2222\n"; }
  fail2ban_sync_ssh_protection() { :; }
  fail2ban_show_ssh_status
' _ "$ROOT" <<< '0' || true)
grep -q '当前保护端口.*22,2222/tcp' <<< "$status_view"
grep -q '1\..*查看当前封禁 IP 总数' <<< "$status_view"
grep -q '2\..*查看近 5 分钟新封禁 IP' <<< "$status_view"
grep -q '3\..*查看当前封禁 IP 详细' <<< "$status_view"

recent_view=$(TERM=xterm VPS_TOOL_STATE="$f2b_status_dir/state" FAIL2BAN_CONFIG="$f2b_status_dir/vps-tool-sshd.local" PATH="$f2b_status_dir/bin:$PATH" bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  get_current_ssh_ports() { printf "22\n2222\n"; }
  fail2ban_sync_ssh_protection() { :; }
  fail2ban_show_ssh_status
' _ "$ROOT" <<< $'2
' || true)
grep -q '近 5 分钟新封禁 IP' <<< "$recent_view"
grep -q '198.51.100.8' <<< "$recent_view"
grep -q '203.0.113.9' <<< "$recent_view"

detail_view=$(TERM=xterm VPS_TOOL_STATE="$f2b_status_dir/state" FAIL2BAN_CONFIG="$f2b_status_dir/vps-tool-sshd.local" PATH="$f2b_status_dir/bin:$PATH" bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  get_current_ssh_ports() { printf "22\n2222\n"; }
  fail2ban_sync_ssh_protection() { :; }
  fail2ban_show_ssh_status
' _ "$ROOT" <<< $'3
' || true)
grep -q '当前封禁 IP 详细' <<< "$detail_view"
grep -q '198.51.100.8' <<< "$detail_view"
grep -q '203.0.113.9' <<< "$detail_view"

# 49a. Fail2Ban 已启用时，SSH 端口变化必须自动同步；迁移期间保护双端口。
f2b_sync_dir="$f2b_test_dir/sync"
mkdir -p "$f2b_sync_dir"
printf '%s\n' 'port = 22' > "$f2b_sync_dir/vps-tool-sshd.local"
VPS_TOOL_STATE="$f2b_sync_dir/state" FAIL2BAN_CONFIG="$f2b_sync_dir/vps-tool-sshd.local" \
PATH="$f2b_test_dir/bin:$PATH" \
bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  firewall_backend() { echo none; }
  get_current_ssh_ports() { printf "2222\n"; }
  fail2ban_detect_log_config() { printf "%s\n" "backend = systemd" "journalmatch = _COMM=sshd + _COMM=sshd-session"; }
  fail2ban_detect_banaction() { :; }
  mark_owned(){ :; }
  is_owned(){ return 0; }
  fail2ban_sync_ssh_protection
  grep -q "port = 2222" "$FAIL2BAN_CONFIG"
' _ "$ROOT"

# 49b. SSH 迁移状态存在时，F2 通过真实 sshd 端口集合自动覆盖旧/新两个端口。
f2b_migration_dir="$f2b_test_dir/migration"
mkdir -p "$f2b_migration_dir"
printf '%s\n' 'port = 22' > "$f2b_migration_dir/vps-tool-sshd.local"
VPS_TOOL_STATE="$f2b_migration_dir/state" FAIL2BAN_CONFIG="$f2b_migration_dir/vps-tool-sshd.local" \
PATH="$f2b_test_dir/bin:$PATH" \
bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  firewall_backend() { echo none; }
  get_current_ssh_ports() { printf "22\n2222\n"; }
  fail2ban_detect_log_config() { printf "%s\n" "backend = systemd" "journalmatch = _COMM=sshd + _COMM=sshd-session"; }
  fail2ban_detect_banaction() { :; }
  mark_owned(){ :; }
  is_owned(){ return 0; }
  fail2ban_sync_ssh_protection
  grep -q "port = 22,2222" "$FAIL2BAN_CONFIG"
' _ "$ROOT"

# 49a. Fail2Ban 停用必须只删除本工具创建的 jail 配置，不卸载 Fail2Ban 软件包。
VPS_TOOL_STATE="$f2b_test_dir/state-enable" FAIL2BAN_CONFIG="$f2b_test_dir/vps-tool-sshd.local" \
PATH="$f2b_test_dir/bin:$PATH" \
bash -c '
  source "$1/lib/common.sh"
  source "$1/modules/security.sh"
  is_owned() { return 0; }
  confirm_safety_prompt() { return 0; }
  fail2ban_disable_ssh_protection
  [[ ! -e "$FAIL2BAN_CONFIG" ]]
' _ "$ROOT"

# 49. get_current_ssh_port 探测失败必须返回非零，绝不静默回退 22。
ssh_probe_stub="$TEST_STATE_ROOT/ssh-probe-stub"
mkdir -p "$ssh_probe_stub"
cat > "$ssh_probe_stub/sshd" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$ssh_probe_stub/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ssh_probe_stub/sshd" "$ssh_probe_stub/ss"
if PATH="$ssh_probe_stub:$PATH" bash -c 'source "$1"; get_current_ssh_port >/dev/null 2>&1' _ "$ROOT/modules/security.sh"; then
    echo 'get_current_ssh_port unexpectedly returned success' >&2
    exit 1
fi

# 50. 多 SSH 端口同时存在时，防火墙禁用入口必须保护所有实际 SSH 端口。
if PATH="$service_test_dir:$PATH" bash -c '
  source "$1"
  firewall_open_port_entries() { printf "22/tcp|UFW 端口\n2222/tcp|UFW 端口\n"; }
  get_current_ssh_ports() { printf "22\n2222\n"; }
  firewall_rule_exists() { return 0; }
  firewall_backend() { echo ufw; }
  firewall_manage_disable ufw <<< "1" >/tmp/vps-firewall-disable-test.out 2>&1
' _ "$ROOT/modules/security.sh"; then
    echo 'firewall_manage_disable unexpectedly allowed current SSH port' >&2
    exit 1
fi
! grep -q "已停止防火墙放行" /tmp/vps-firewall-disable-test.out

# 51. 旧 SSH 端口清理前必须先确认新端口已经被本机防火墙放行；未放行时不得调用删除动作。
ssh_cleanup_stub="$TEST_STATE_ROOT/ssh-cleanup-stub"
mkdir -p "$ssh_cleanup_stub"
marker_old="$TEST_STATE_ROOT/old-firewall-delete.marker"
marker_fallback="$TEST_STATE_ROOT/old-firewall-close.marker"
MARKER_OLD="$marker_old" MARKER_FALLBACK="$marker_fallback" BACKUP_ROOT="$TEST_STATE_ROOT/backups" FAIL2BAN_TEST_CONFIG="$TEST_STATE_ROOT/no-fail2ban" \
bash -c '
  source "$1"
  state_get(){ case "$1" in ssh_migration_old_port) echo 22;; ssh_migration_new_port) echo 2222;; *) return 1;; esac; }
  state_set(){ :; }
  state_unset(){ :; }
  current_ssh_session_uses_port(){ return 0; }
  sshd_has_port(){ return 0; }
  ssh_port_listening(){ return 0; }
  validate_sshd_config(){ return 0; }
  restart_or_reload_ssh(){ return 0; }
  make_temp_dir(){ mktemp -d; }
  backup_current_ssh_files(){ return 0; }
  remove_sshd_port_global(){ return 0; }
  restore_action_ssh_files(){ return 0; }
  confirm_safety_prompt(){ return 0; }
  firewall_backend(){ echo ufw; }
  firewall_rule_exists(){ [[ "$2" == "2222" ]] && return 1; return 0; }
  firewall_port_has_service_rule(){ return 1; }
  firewall_remove_owned_rules(){ printf x > "$MARKER_OLD"; return 0; }
  port_in_use(){ return 1; }
  firewall_close_port_rule(){ printf x > "$MARKER_FALLBACK"; return 0; }
  FAIL2BAN_CONFIG="$FAIL2BAN_TEST_CONFIG"
  VPS_TOOL_BACKUPS="$BACKUP_ROOT"
  remove_old_ssh_port || true
' _ "$ROOT/modules/security.sh" >/dev/null 2>&1
[[ ! -e "$marker_old" && ! -e "$marker_fallback" ]]

# 51a. 防火墙探测不到 SSH 端口时必须中止，不得启用防火墙。
if bash -c '
  source "$1"
  check_os(){ PKG_MANAGER=apt; return 0; }
  get_current_ssh_ports(){ return 1; }
  firewall_backend(){ echo none; }
  setup_firewall
' _ "$ROOT/modules/security.sh" >/dev/null 2>&1; then
    echo 'setup_firewall unexpectedly continued without SSH port detection' >&2
    exit 1
fi

# 51b. 防火墙基线必须覆盖所有实际 SSH 端口以及当前 SSH 会话端口。
firewall_rules_seen="$TEST_STATE_ROOT/firewall-rules-seen.txt"
: > "$firewall_rules_seen"
printf 'y\n' | RULE_LOG="$firewall_rules_seen" bash -c '
  source "$1"
  check_os(){ PKG_MANAGER=apt; return 0; }
  get_current_ssh_ports(){ printf "22\n2222\n"; }
  current_ssh_session_port(){ echo 2222; }
  firewall_backend(){ echo ufw; }
  firewall_show_open_ports(){ :; }
  firewall_rule_exists(){ return 1; }
  firewall_allow(){ printf "%s/%s\n" "$1" "$2" >> "$RULE_LOG"; return 0; }
  setup_firewall
' _ "$ROOT/modules/security.sh" >/dev/null 2>&1
for expected in 22/tcp 2222/tcp 80/tcp 443/tcp; do grep -qx "$expected" "$firewall_rules_seen"; done

# 51c. UFW 单端口规则允许精确删除；重复同端口规则必须拒绝删除。
ufw_delete_single="$TEST_STATE_ROOT/ufw-delete-single.log"
mkdir -p "$TEST_STATE_ROOT/ufw-single"
cat > "$TEST_STATE_ROOT/ufw-single/ufw" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "status numbered") printf '[ 1] 2222/tcp                 ALLOW IN    Anywhere\n'; exit 0 ;;
  "delete allow 2222/tcp") printf 'deleted\n' > "${DELETE_LOG:?}"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TEST_STATE_ROOT/ufw-single/ufw"
DELETE_LOG="$ufw_delete_single" PATH="$TEST_STATE_ROOT/ufw-single:$PATH" bash -c '
  source "$1"
  firewall_port_has_service_rule(){ return 1; }
  firewall_remove_owned_rule ufw 2222 tcp
' _ "$ROOT/lib/common.sh"
grep -q '^deleted$' "$ufw_delete_single"

mkdir -p "$TEST_STATE_ROOT/ufw-dup"
cat > "$TEST_STATE_ROOT/ufw-dup/ufw" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "status numbered") printf '[ 1] 2222/tcp                 ALLOW IN    Anywhere\n[ 2] 2222/tcp                 ALLOW IN    198.51.100.0/24\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TEST_STATE_ROOT/ufw-dup/ufw"
PATH="$TEST_STATE_ROOT/ufw-dup:$PATH" bash -c '
  source "$1"
  firewall_port_has_service_rule(){ return 1; }
  if firewall_remove_owned_rule ufw 2222 tcp; then exit 1; fi
' _ "$ROOT/lib/common.sh"

# 52. GAI IPv4 优先规则对空白数量不敏感，已有等价规则不重复添加。
gai_test="$TEST_STATE_ROOT/gai.conf"
printf 'precedence ::ffff:0:0/96 100\n' > "$gai_test"
Gai_added=$(
  bash -c 'source "$1"; GAI_CONF="$2"; backup_file_once(){ :; }; state_set(){ printf "%s=%s\\n" "$1" "$2"; }; apply_gai_ipv4_priority' _ "$ROOT/modules/optimize.sh" "$gai_test"
)
grep -q 'gai_added_by_tool=0' <<< "$Gai_added"
[[ "$(grep -cE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100[[:space:]]*$' "$gai_test")" -eq 1 ]]

# 53. random_free_port 对 port_in_use 的非法协议状态必须视为失败，不能把未检查端口当成空闲。
if bash -c 'source "$1"; port_in_use(){ return 2; }; random_free_port tcp' _ "$ROOT/lib/common.sh" >/dev/null 2>&1; then
    echo 'random_free_port unexpectedly accepted failed port probe' >&2
    exit 1
fi

# 54. 版本比较必须只在远端主.次.补更高时判定为更新；后缀忽略比较。
version_fn="$TEST_STATE_ROOT/version_gt.sh"
awk '''/^version_gt\(\) \{/{found=1} found{print; if ($0 == "}") exit}''' "$ROOT/install.sh" > "$version_fn"
bash -c 'source "$1"; version_gt 2.1.0 2.0.0' _ "$version_fn"
! bash -c 'source "$1"; version_gt 2.0.0 2.1.0' _ "$version_fn"

# 55. apt 安全升级文案必须明确说明 Debian/Ubuntu 实际执行全量 upgrade。
grep -q 'Debian/Ubuntu 为全量升级' "$ROOT/lib/common.sh"
grep -q 'openssh-server/内核' "$ROOT/lib/common.sh"

echo 'smoke tests: OK' 


# 56. 增项 10：sing-box 校验使用 Release API digest 主路径，校验文件兜底，双路径失败拒绝，以及显式跳过开关。
(
    source "$ROOT/modules/protocol.sh"
    fake_digest="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    fake_fallback="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    fake_curl() {
        local out="" url=""
        while (($#)); do
            case "$1" in
                -o) out="$2"; shift 2 ;;
                http*) url="$1"; shift ;;
                *) shift ;;
            esac
        done
        if [[ "$url" == *"/releases/tags/v1.14.2" ]]; then
            printf '{"tag_name":"v1.14.2","assets":[{"name":"sing-box-1.14.2-linux-amd64.tar.gz","digest":"sha256:%s"}]}' "$fake_digest"
            return 0
        fi
        if [[ "$url" == *"/releases?per_page=10" ]]; then
            printf '%s' '[
              {"tag_name":"v9.9.9","draft":false,"prerelease":false,"assets":[{"name":"sing-box-9.9.9-linux-arm64.tar.gz"}]},
              {"tag_name":"v1.14.1","draft":false,"prerelease":false,"assets":[{"name":"sing-box-1.14.1-linux-amd64.tar.gz"}]},
              {"tag_name":"v1.14.0-rc.1","draft":false,"prerelease":true,"assets":[{"name":"sing-box-1.14.0-rc.1-linux-amd64.tar.gz"}]}
            ]'
            return 0
        fi
        if [[ "$url" == *"/checksums.sha256" ]]; then
            [[ -n "$out" ]] || return 22
            printf 'SHA256 (sing-box-1.14.2-linux-amd64.tar.gz) = %s\n' "$fake_fallback" > "$out"
            return 0
        fi
        return 22
    }
    curl() { fake_curl "$@"; }

    got=$(fetch_release_asset_digest 1.14.2 sing-box-1.14.2-linux-amd64.tar.gz)
    [[ "$got" == "$fake_digest" ]]

    [[ "$(latest_singbox_version)" == "1.14.1" ]]

    fallback_json='{"tag_name":"v1.14.2","assets":[{"name":"sing-box-1.14.2-linux-amd64.tar.gz","digest":null}]}'
    fake_curl() {
        local out="" url=""
        while (($#)); do
            case "$1" in
                -o) out="$2"; shift 2 ;;
                http*) url="$1"; shift ;;
                *) shift ;;
            esac
        done
        if [[ "$url" == *"/releases/tags/v1.14.2" ]]; then
            printf '%s' "$fallback_json"
            return 0
        fi
        if [[ "$url" == *"/checksums.sha256" ]]; then
            printf 'SHA256 (sing-box-1.14.2-linux-amd64.tar.gz) = %s\n' "$fake_fallback" > "$out"
            return 0
        fi
        return 22
    }
    curl() { fake_curl "$@"; }
    tmp_checksum=$(mktemp)
    got=$(resolve_singbox_checksum 1.14.2 sing-box-1.14.2-linux-amd64.tar.gz "$tmp_checksum")
    [[ "$got" == "$fake_fallback" ]]
    rm -f "$tmp_checksum"

    fake_curl() {
        local out="" url=""
        while (($#)); do
            case "$1" in
                -o) out="$2"; shift 2 ;;
                http*) url="$1"; shift ;;
                *) shift ;;
            esac
        done
        if [[ "$url" == *"/releases/tags/v1.14.2" ]]; then
            printf '%s' "$fallback_json"
            return 0
        fi
        return 22
    }
    curl() { fake_curl "$@"; }
    tmp_checksum=$(mktemp)
    if error_text=$(resolve_singbox_checksum 1.14.2 sing-box-1.14.2-linux-amd64.tar.gz "$tmp_checksum" 2>&1); then
        echo "resolve_singbox_checksum unexpectedly succeeded without a digest" >&2
        exit 1
    fi
    grep -q '未提供可用校验值' <<<"$error_text"
    rm -f "$tmp_checksum"

    export VPS_TOOL_SKIP_SINGBOX_VERIFY=1
    tmp_checksum=$(mktemp)
    if ! warning_text=$(resolve_singbox_checksum 1.14.2 sing-box-1.14.2-linux-amd64.tar.gz "$tmp_checksum" 2>&1); then
        echo "skip verification unexpectedly failed" >&2
        exit 1
    fi
    grep -q 'VPS_TOOL_SKIP_SINGBOX_VERIFY=1' <<<"$warning_text"
    rm -f "$tmp_checksum"
    unset VPS_TOOL_SKIP_SINGBOX_VERIFY
)


# 57. Round25：sing-box systemd 加固必须允许 AF_NETLINK，并限制失败重试。
grep -q '^RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK$' "$ROOT/modules/protocol.sh"
grep -q '^StartLimitIntervalSec=300$' "$ROOT/modules/protocol.sh"
grep -q '^StartLimitBurst=5$' "$ROOT/modules/protocol.sh"
grep -q 'VPS_TOOL_SERVICE_HARDENING' "$ROOT/modules/protocol.sh"

# 58. Round25：/etc/vps-tool 必须可穿越，但 state/backups 保持 0700。
grep -q '^chmod 711 "${VPS_TOOL_ETC}"' "$ROOT/lib/common.sh"
grep -q '^chmod 700 "${VPS_TOOL_STATE}" "${VPS_TOOL_BACKUPS}"' "$ROOT/lib/common.sh"
grep -q '^chmod 711 "$LOG_DIR" || true$' "$ROOT/install.sh"
! grep -q '^chmod 700 "${VPS_TOOL_ETC}"' "$ROOT/lib/common.sh"

# 59. Round25：同步包不得重新安装明显过旧的 security.sh。
grep -q 'firewall_port_has_service_rule' "$ROOT/modules/security.sh"

# 60. Round25：真实启动失败必须输出 journalctl 排障命令。
grep -q 'journalctl -u "\$SERVICE_UNIT" -n 20 --no-pager -l' "$ROOT/modules/protocol.sh"
grep -q 'journalctl -u \${SERVICE_UNIT} -n 50 --no-pager -l' "$ROOT/modules/protocol.sh"

# 61. Round25：启动验证不能再只 sleep 1 秒。
! grep -q '^    sleep 1$' "$ROOT/modules/protocol.sh"
grep -q 'attempt = 1; attempt <= 20' "$ROOT/modules/protocol.sh"
grep -q 'sleep 0.5' "$ROOT/modules/protocol.sh"

# 62. Round25：失败回滚必须 stop/reset-failed，不能立即 restart 进入循环。
grep -q 'systemctl stop "\$SERVICE_UNIT"' "$ROOT/modules/protocol.sh"
grep -q 'systemctl reset-failed "\$SERVICE_UNIT"' "$ROOT/modules/protocol.sh"
! grep -q 'systemctl restart "\$SERVICE_UNIT" >/dev/null 2>&1 || true' "$ROOT/modules/protocol.sh"

# 63. Round27：模块 2 增加协议/新协议更新检查，清单必须是结构化数据且不执行其中任何代码。
grep -q '^protocol_update_check()' "$ROOT/modules/protocol.sh"
grep -q '检查协议更新 / 新协议' "$ROOT/modules/protocol.sh"
grep -q 'protocol_catalog.json' "$ROOT/modules/protocol.sh"
grep -q -- '--update-return' "$ROOT/modules/protocol.sh"
grep -q -- '--update-return' "$ROOT/install.sh"
grep -q 'download_one "protocol_catalog.json"' "$ROOT/install.sh"
grep -q 'install -m 644 "${temp}/protocol_catalog.json"' "$ROOT/install.sh"

jq -e '(.schema_version | type == "number") and (.tool_version | type == "string") and (.protocols | type == "array") and all(.protocols[]; (.id | type == "string") and (.name | type == "string") and (.adapter_version | type == "number") and (.status | type == "string") and (.implemented | type == "boolean"))' "$ROOT/protocol_catalog.json" >/dev/null
[[ "$(jq -r '.tool_version' "$ROOT/protocol_catalog.json")" == "2.9.3" ]]
[[ "$(jq -r '.protocols | length' "$ROOT/protocol_catalog.json")" -eq 3 ]]
[[ "$(jq -r '.protocols[] | select(.id == "tuic-v5") | .adapter_version' "$ROOT/protocol_catalog.json")" == "2" ]]

# 63a. 远端只返回清单数据时，能发现新协议；坏 JSON 必须拒绝。
update_check_capture="$TEST_STATE_ROOT/protocol-update-check.txt"
VPS_TOOL_ROOT="$TEST_STATE_ROOT/protocol-root" bash -c '
  source "$1/modules/protocol.sh"
  mkdir -p "$VPS_TOOL_ROOT"
  printf "2.9.3\n" > "$VPS_TOOL_ROOT/VERSION"
  curl() {
    local out=""
    while (($#)); do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cat > "$out" <<"JSON"
{"schema_version":1,"tool_version":"2.9.3","updated_at":"2026-10-03","protocols":[{"id":"vless-reality","name":"VLESS + Reality","status":"stable","implemented":true,"adapter_version":1},{"id":"hysteria2","name":"Hysteria 2","status":"stable","implemented":true,"adapter_version":1},{"id":"tuic-v5","name":"TUIC v5","status":"stable","implemented":true,"adapter_version":2},{"id":"new-protocol","name":"New Protocol","status":"stable","implemented":true,"adapter_version":1}]}
JSON
  }
  protocol_update_check
' _ "$ROOT" > "$update_check_capture" 2>&1
grep -q '发现新协议/协议实现' "$update_check_capture"
grep -q 'New Protocol' "$update_check_capture"
grep -q '本次只报告更新，不强制同步' "$update_check_capture"

VPS_TOOL_ROOT="$TEST_STATE_ROOT/protocol-root-bad" bash -c '
  source "$1/modules/protocol.sh"
  mkdir -p "$VPS_TOOL_ROOT"
  curl() {
    local out=""
    while (($#)); do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf "not-json" > "$out"
  }
  if protocol_update_check; then exit 1; fi
' _ "$ROOT" >/dev/null 2>&1

# 63b. 更新路径必须复用现有 install.sh --update-return，不接受协议清单提供的任意下载 URL。
! grep -Eq 'curl.*PROTOCOL_CATALOG_URL.*\$|curl.*remote.*url' "$ROOT/modules/protocol.sh"
grep -q 'bash "${VPS_TOOL_ROOT}/install.sh" --update-return' "$ROOT/modules/protocol.sh"

echo 'round27 protocol update checks: OK'

# 63d. Round28：模块 2 的协议更新检查同时检测本机 sing-box 与最新稳定版。
grep -q '^singbox_current_version()' "$ROOT/modules/protocol.sh"
grep -q 'sing-box 有新稳定版' "$ROOT/modules/protocol.sh"

singbox_update_capture="$TEST_STATE_ROOT/singbox-update-check.txt"
VPS_TOOL_ROOT="$TEST_STATE_ROOT/protocol-root-singbox" bash -c '
  source "$1/modules/protocol.sh"
  mkdir -p "$VPS_TOOL_ROOT"
  printf "2.9.3\n" > "$VPS_TOOL_ROOT/VERSION"
  fake="$VPS_TOOL_ROOT/fake-sing-box"
  cat > "$fake" <<"EOF"
#!/usr/bin/env bash
echo "sing-box version 1.14.2"
EOF
  chmod +x "$fake"
  resolve_singbox() { SINGBOX_BIN="$fake"; return 0; }
  latest_singbox_version() { echo "1.15.0"; }
  curl() {
    local out=""
    while (($#)); do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cat > "$out" <<"JSON"
{"schema_version":1,"tool_version":"2.9.3","updated_at":"2026-10-03","protocols":[{"id":"vless-reality","name":"VLESS + Reality","status":"stable","implemented":true,"adapter_version":1},{"id":"hysteria2","name":"Hysteria 2","status":"stable","implemented":true,"adapter_version":1},{"id":"tuic-v5","name":"TUIC v5","status":"stable","implemented":true,"adapter_version":2}]}
JSON
  }
  protocol_update_check
' _ "$ROOT" > "$singbox_update_capture" 2>&1

grep -q 'sing-box 有新稳定版：v1.14.2 → v1.15.0' "$singbox_update_capture"
grep -q '当前第 7 项先负责提示' "$singbox_update_capture"
grep -q '请先确认新版本与当前配置兼容' "$singbox_update_capture"

echo 'round28 sing-box update detection: OK'

# 63c. Round27：协议模块函数名不得因新增菜单逻辑发生碰撞/截断。
[[ "$(grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' "$ROOT/modules/protocol.sh" | sed 's/(.*//' | sort | uniq -d | wc -l)" -eq 0 ]]

echo 'round27 function-name guard: OK'
# 63b. Round30：端口跳跃失败回滚、路径统一、key 字面量匹配、全量端口冲突检查。
grep -q 'dir="\${VPS_TOOL_ETC}/port-hop"' "$ROOT/modules/protocol.sh"
grep -q 'file="\${VPS_TOOL_ETC}/port-hop/\${name}.nft"' "$ROOT/modules/protocol.sh"
grep -q 'file="\${VPS_TOOL_ETC}/port-hop/\${name}.iptables"' "$ROOT/modules/protocol.sh"
grep -q 'awk -v k="\$key"' "$ROOT/modules/protocol.sh"
grep -q '用户 ID (UUID)' "$ROOT/modules/protocol.sh"
! grep -q '用户 ID \\(UUID\\)' "$ROOT/modules/protocol.sh"
grep -q '正在回滚本次端口跳跃' "$ROOT/modules/protocol.sh"

hop_probe_dir="$TEST_STATE_ROOT/hop-probe-bin"
mkdir -p "$hop_probe_dir"
cat > "$hop_probe_dir/ss" <<'EOF_SS'
#!/usr/bin/env bash
# ss -H -lun: local address is field 5.
printf '%s\n' \
  'UNCONN 0 0 0.0.0.0:20055 0.0.0.0:*' \
  'UNCONN 0 0 0.0.0.0:31000 0.0.0.0:*'
EOF_SS
chmod +x "$hop_probe_dir/ss"
PATH="$hop_probe_dir:$PATH" VPS_TOOL_ROOT="$TEST_STATE_ROOT/hop-probe-root" bash -c '
  source "$1/modules/protocol.sh"
  if hop_range_conflicts 20000 20100; then exit 0; else exit 1; fi
' _ "$ROOT"
PATH="$hop_probe_dir:$PATH" VPS_TOOL_ROOT="$TEST_STATE_ROOT/hop-probe-root2" bash -c '
  source "$1/modules/protocol.sh"
  if hop_range_conflicts 30000 30050; then exit 1; else exit 0; fi
' _ "$ROOT"

# 63c. Round30：端口跳跃防火墙中途失败必须自动回滚已创建的状态与规则。
hop_rollback_dir="$TEST_STATE_ROOT/hop-rollback-bin"
mkdir -p "$hop_rollback_dir"
cat > "$hop_rollback_dir/nft" <<'EOF_NFT'
#!/usr/bin/env bash
exit 0
EOF_NFT
chmod +x "$hop_rollback_dir/nft"
PATH="$hop_rollback_dir:$PATH" VPS_TOOL_ROOT="$TEST_STATE_ROOT/hop-rollback-root" bash -c '
  source "$1/modules/protocol.sh"
  mkdir -p "$VPS_TOOL_ROOT" "$VPS_TOOL_ETC" "$VPS_TOOL_STATE" "$VPS_TOOL_BACKUPS"
  firewall_calls="$VPS_TOOL_ROOT/firewall-calls"
  firewall_allow(){
    printf "allow %s/%s\n" "$1" "$2" >> "$firewall_calls"
    [[ "$1" != "20001" ]]
  }
  firewall_remove_owned_rules(){
    printf "remove %s/%s\n" "$1" "$2" >> "$firewall_calls"
    return 0
  }
  if setup_port_hopping hy2 20000-20002 20000; then
    exit 1
  fi
  ! state_exists "$(protocol_hop_state_key hy2)"
  grep -q "remove 20000/udp" "$firewall_calls"
' _ "$ROOT"

# 63d. Round30：node_info_value 使用字面量 key，不把正则元字符当成模式。
VPS_TOOL_ROOT="$TEST_STATE_ROOT/node-key-root" bash -c '
  source "$1/modules/protocol.sh"
  mkdir -p "$VPS_TOOL_ROOT"
  f="$VPS_TOOL_ROOT/node.txt"
  printf "%s\n" "a.b: literal" "aXb: wrong" > "$f"
  [[ "$(node_info_value "$f" "a.b")" == "literal" ]]
' _ "$ROOT"

echo 'round30 targeted defect checks: OK'

# 64. Round29：当前缺陷修复与新增功能的静态/单元验收。
grep -q '因此客户端链接包含 allow_insecure=1' "$ROOT/modules/protocol.sh"
grep -q '因此客户端链接包含 insecure=1' "$ROOT/modules/protocol.sh"
grep -q "releases?per_page=10" "$ROOT/modules/protocol.sh"
grep -q '本次跳过了 sing-box SHA-256 校验' "$ROOT/modules/protocol.sh"
grep -q '下载到的 protocol_catalog.json 格式无效，已拒绝更新' "$ROOT/install.sh"
grep -q '^check_protocol_resources()' "$ROOT/modules/protocol.sh"
grep -q '^generate_clash_yaml()' "$ROOT/modules/protocol.sh"
grep -q '^display_protocol_qr()' "$ROOT/modules/protocol.sh"
grep -q '^protocol_diagnose()' "$ROOT/modules/protocol.sh"
grep -q '^setup_port_hopping()' "$ROOT/modules/protocol.sh"
grep -q '^remove_port_hopping()' "$ROOT/modules/protocol.sh"
grep -q 'VPS_TOOL_FORCE_DEPLOY' "$ROOT/modules/protocol.sh"
grep -q '3. 协议诊断（只读）' "$ROOT/modules/protocol.sh"
grep -q '2. 生成 / 查看 Clash / Mihomo 配置' "$ROOT/modules/protocol.sh"
grep -q '2. 显示节点二维码' "$ROOT/modules/protocol.sh"
grep -q '4. 关闭端口跳跃并恢复单端口' "$ROOT/modules/protocol.sh"

# 64a. 资源预检阈值、流水线和强制继续行为。
resource_capture="$TEST_STATE_ROOT/resource-check.txt"
VPS_TOOL_ROOT="$TEST_STATE_ROOT/resource-root" bash -c '
  source "$1/modules/protocol.sh"
  get_mem_available_mb(){ echo 110; }
  get_root_free_mb(){ echo 600; }
  current_swap_mb(){ echo 0; }
  read(){ return 1; }
  if check_protocol_resources vless; then echo "rc=0"; else echo "rc=1"; fi
' _ "$ROOT" > "$resource_capture" 2>&1
 grep -q '处于警告区' "$resource_capture"
grep -q 'rc=1' "$resource_capture"

resource_yes="$TEST_STATE_ROOT/resource-check-yes.txt"
VPS_TOOL_ROOT="$TEST_STATE_ROOT/resource-root-yes" bash -c '
  source "$1/modules/protocol.sh"
  get_mem_available_mb(){ echo 110; }
  get_root_free_mb(){ echo 600; }
  current_swap_mb(){ echo 0; }
  printf "y\n" | check_protocol_resources vless
' _ "$ROOT" > "$resource_yes" 2>&1
grep -q '\[通过\]' "$resource_yes"

VPS_TOOL_PIPELINE=1 VPS_TOOL_ROOT="$TEST_STATE_ROOT/resource-root-pipeline" bash -c '
  source "$1/modules/protocol.sh"
  get_mem_available_mb(){ echo 110; }
  get_root_free_mb(){ echo 600; }
  current_swap_mb(){ echo 0; }
  read(){ echo "READ_SHOULD_NOT_RUN" >&2; return 1; }
  check_protocol_resources vless
' _ "$ROOT" > /dev/null 2>&1

VPS_TOOL_FORCE_DEPLOY=1 VPS_TOOL_ROOT="$TEST_STATE_ROOT/resource-root-force" bash -c '
  source "$1/modules/protocol.sh"
  get_mem_available_mb(){ echo 90; }
  get_root_free_mb(){ echo 200; }
  current_swap_mb(){ echo 0; }
  check_protocol_resources vless
' _ "$ROOT" > "$TEST_STATE_ROOT/resource-force.txt" 2>&1
grep -q '已按用户要求强制继续' "$TEST_STATE_ROOT/resource-force.txt"

# 64b. 端口跳跃范围校验。
VPS_TOOL_ROOT="$TEST_STATE_ROOT/hop-root" bash -c '
  source "$1/modules/protocol.sh"
  validate_hop_range 20000-20100
  ! validate_hop_range 100-200
  ! validate_hop_range 20000-100
  ! validate_hop_range 20000-20500
' _ "$ROOT"

# 64c. QR 可选依赖：调用被 command_exists 包裹，非交互/流水线模式不会阻塞。
grep -q 'if ! command_exists qrencode' "$ROOT/modules/protocol.sh"
grep -q 'qrencode -t ANSIUTF8' "$ROOT/modules/protocol.sh"
grep -q 'VPS_TOOL_PIPELINE' "$ROOT/modules/protocol.sh"

# 64d. Clash YAML：三协议节点都有时必须输出三个 server。
clash_root="$TEST_STATE_ROOT/clash-root"
mkdir -p "$clash_root/root" "$clash_root/etc/state" "$clash_root/etc/backups" "$clash_root/etc/sing-box"
cat > "$clash_root/node_setup.sh" <<'EOF_CLASH'
EOF_CLASH
VPS_TOOL_ROOT="$clash_root/root" VPS_TOOL_ETC="$clash_root/etc" VPS_TOOL_STATE="$clash_root/etc/state" VPS_TOOL_BACKUPS="$clash_root/etc/backups" bash -c '
  source "$1/modules/protocol.sh"
  CONF_DIR="$VPS_TOOL_ETC/sing-box"; PROTOCOL_NODE_INFO_DIR="$CONF_DIR"
  state_set protocol_vless 1; state_set protocol_vless_port 12345
  state_set protocol_hy2 1; state_set protocol_hy2_port 23456
  state_set protocol_tuic 1; state_set protocol_tuic_port 34567
  for p in vless hy2 tuic; do :; done
  cat > "$CONF_DIR/node_info_vless.txt" <<EOF_V
服务器地址: 203.0.113.10
连接端口: 12345
用户 ID (UUID): uuid-v
流控: xtls-rprx-vision
SNI: addons.mozilla.org
PublicKey: public-v
ShortId: deadbeef
EOF_V
  cat > "$CONF_DIR/node_info_hy2.txt" <<EOF_H
服务器地址: 203.0.113.10
UDP 端口: 23456
连接密码: pass-h
SNI: bing.com
EOF_H
  cat > "$CONF_DIR/node_info_tuic.txt" <<EOF_T
服务器地址: 203.0.113.10
UDP 端口: 34567
用户 ID (UUID): uuid-t
连接密码: pass-t
SNI: bing.com
EOF_T
  generate_clash_yaml >/dev/null
' _ "$ROOT"
[[ "$(grep -c '^    server:' "$clash_root/etc/sing-box/clash.yaml")" -eq 3 ]]
[[ "$(stat -c '%a' "$clash_root/etc/sing-box/clash.yaml")" == 600 ]]

# 64e. 协议诊断只读约束。
awk '/^protocol_diagnose\(\)/,/^}/ {print}' "$ROOT/modules/protocol.sh" > "$TEST_STATE_ROOT/diagnose-body.txt"
! grep -q 'state_set' "$TEST_STATE_ROOT/diagnose-body.txt"
! grep -q 'systemctl restart' "$TEST_STATE_ROOT/diagnose-body.txt"
! grep -qE '> *[^>]*(config\.json)' "$TEST_STATE_ROOT/diagnose-body.txt"

# 64f. 端口跳跃关闭入口必须调用精确撤销函数而不是 flush 全表。
grep -q '^disable_protocol_hopping_menu()' "$ROOT/modules/protocol.sh"
grep -q 'remove_port_hopping "$name"' "$ROOT/modules/protocol.sh"
grep -q 'VPS_TOOL_HOP_' "$ROOT/modules/protocol.sh"
! grep -q 'nft flush table' "$ROOT/modules/protocol.sh"

echo 'round29 defects-and-features: OK'



# Round31：模块 2 界面精简与三项行为调整。
grep -q '5. 移除协议 / 清理全部' "$ROOT/modules/protocol.sh"
grep -q '7. 其他与诊断' "$ROOT/modules/protocol.sh"
! grep -q '5. 移除指定协议$' "$ROOT/modules/protocol.sh"
! grep -q '6. 清理本工具创建的协议环境$' "$ROOT/modules/protocol.sh"
grep -q '请选择 \[0-7\]' "$ROOT/modules/protocol.sh"
grep -qE 'RED.*0\.\s*退出' "$ROOT/modules/protocol.sh"
grep -q '^remove_or_clean_menu()' "$ROOT/modules/protocol.sh"
grep -q '1. 清理全部协议与协议环境' "$ROOT/modules/protocol.sh"
grep -q '^other_and_diagnose_menu()' "$ROOT/modules/protocol.sh"
grep -q '^qr_menu()' "$ROOT/modules/protocol.sh"
grep -q '1. 安装 / 检查二维码依赖' "$ROOT/modules/protocol.sh"
grep -q '2. 显示节点二维码' "$ROOT/modules/protocol.sh"
grep -q '是否现在安装' "$ROOT/modules/protocol.sh"
! grep -qE 'for cmd in .*qrencode' "$ROOT/install.sh"
grep -q '是否启用 UDP 端口跳跃.*\[Y/n\]' "$ROOT/modules/protocol.sh"
! grep -q '是否启用 UDP 端口跳跃.*\[y/N\]' "$ROOT/modules/protocol.sh"
grep -q '云平台安全组需放行整段' "$ROOT/modules/protocol.sh"
grep -q 'vision_flow="xtls-rprx-vision"' "$ROOT/modules/protocol.sh"
grep -qF '启用 Vision 流控？[Y/n]' "$ROOT/modules/protocol.sh"
cat_ver=$(grep -m1 '^CURRENT_VERSION=' "$ROOT/install.sh" | cut -d'"' -f2)
cat_tool=$(jq -r '.tool_version' "$ROOT/protocol_catalog.json")
[[ "$cat_ver" == "$cat_tool" ]]
