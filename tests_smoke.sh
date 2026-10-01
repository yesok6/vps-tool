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
grep -q 'grep -F -- "$asset"' "$ROOT/modules/protocol.sh"

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

# 19. restore_runtime_values 没有记录时允许调用方显式忽略，不应触发 set -e 中断。
if restore_runtime_values; then
    echo 'restore_runtime_values unexpectedly succeeded without state directory' >&2
    exit 1
fi

# 20. 本测试脚本本身不允许留下真实 VPS 工具状态目录。
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


# 24. 已安装的本地 install.sh 启动时不得静默 sync_bundle；更新应通过选项 8。
grep -qF 'current_script_path=$(readlink -f -- "${BASH_SOURCE[0]}")' "$ROOT/install.sh"
grep -qF 'local_install_path=$(readlink -f -- "${LOCAL_ROOT}/install.sh")' "$ROOT/install.sh"
grep -qF '    # 首次通过网络脚本启动时同步完整本地工具包；已安装版本启动时不再静默更新。' "$ROOT/install.sh"

# 25. 顶层防火墙单条删除 helper 应按后端参数校验并返回失败，而不是异常成功。
if firewall_remove_owned_rule invalid_backend 65535 tcp; then
    echo 'firewall_remove_owned_rule unexpectedly accepted an invalid backend' >&2
    exit 1
fi

# 26. 路径规范化应让同一实际文件的不同符号链接解析到相同目标。
path_link="$TEST_STATE_ROOT/install-link.sh"
ln -s "$ROOT/install.sh" "$path_link"
normalized_link=$(readlink -f -- "$path_link")
normalized_root=$(readlink -f -- "$ROOT/install.sh")
[[ "$normalized_link" == "$normalized_root" ]]


# 27. SSH 端口迁移必须提供三种模式，并要求自动/手动删除使用真实新会话验证。
grep -q '修改 SSH 端口（保留旧端口）' "$ROOT/modules/security.sh"
grep -q '新端口真实登录后自动删除旧端口' "$ROOT/modules/security.sh"
grep -q '删除已验证的旧 SSH 端口' "$ROOT/modules/security.sh"
grep -q 'current_ssh_session_uses_port' "$ROOT/modules/security.sh"
grep -q 'wait_for_new_ssh_session' "$ROOT/modules/security.sh"

# 28. 当前会话端口识别必须来自 SSH_CONNECTION；自动删除不得只看监听状态。
SSH_CONNECTION='198.51.100.20 54321 192.0.2.10 34567' bash -c 'source "$1"; [[ "$(current_ssh_session_port)" == "34567" ]]; current_ssh_session_uses_port 34567' _ "$ROOT/modules/security.sh"

# 29. 实际新 SSH 会话检测要求目标端口 + 当前来源地址同时匹配。
ssh_stub_dir="$TEST_STATE_ROOT/ssh-stub"
mkdir -p "$ssh_stub_dir"
cat > "$ssh_stub_dir/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ESTAB 0 0 192.0.2.10:34567 198.51.100.20:54322 users:(())'
EOF
chmod +x "$ssh_stub_dir/ss"
PATH="$ssh_stub_dir:$PATH" SSH_CONNECTION='198.51.100.20 54321 192.0.2.10 22' bash -c 'source "$1"; ssh_new_session_detected 34567' _ "$ROOT/modules/security.sh"

# 30. SSH 双端口配置必须保留原有其它全局 Port，并保留 Match 块。
ssh_cfg="$TEST_STATE_ROOT/sshd_config.test"
cat > "$ssh_cfg" <<'EOF'
Port 22
Port 2200
PermitRootLogin yes

Match User test
    Port 2201
EOF
bash -c 'source "$1"; SSHD_CONFIG="$2"; set_sshd_ports_global 22 34567; grep -qx "Port 22" "$SSHD_CONFIG"; grep -qx "Port 34567" "$SSHD_CONFIG"; grep -qx "Port 2200" "$SSHD_CONFIG"; grep -q "^Match User test$" "$SSHD_CONFIG"; grep -q "^    Port 2201$" "$SSHD_CONFIG"' _ "$ROOT/modules/security.sh" "$ssh_cfg"


# 31. 自动删除模式必须依赖“真实新会话已检测到”，而不能要求当前脚本会话已经切到新端口；手动模式则相反。
SSH_CONNECTION='198.51.100.20 54321 192.0.2.10 22' bash -c '
    source "$1"
    state_set ssh_migration_old_port 22
    state_set ssh_migration_new_port 34567
    ssh_new_session_detected() { return 0; }
    current_ssh_session_uses_port() { return 1; }
    sshd_has_port() { return 0; }
    FAKE_OLD_REMOVED=0
    ssh_port_listening() { if [[ "$1" == "22" && "$FAKE_OLD_REMOVED" == "1" ]]; then return 1; fi; return 0; }
    backup_current_ssh_files() { mkdir -p "$1"; printf "missing\\n" > "$1/authorized_keys.state"; }
    remove_sshd_port_global() { FAKE_OLD_REMOVED=1; return 0; }
    validate_sshd_config() { return 0; }
    restart_or_reload_ssh() { return 0; }
    firewall_backend() { echo none; }
    log_action() { :; }
    make_temp_dir() { mktemp -d "'"$TEST_STATE_ROOT"'/auto-remove.XXXXXX"; }
    remove_old_ssh_port 22 34567 1
    [[ ! -f "'"$VPS_TOOL_STATE"'/ssh_migration_old_port" ]] && [[ ! -f "'"$VPS_TOOL_STATE"'/ssh_migration_new_port" ]]
' _ "$ROOT/modules/security.sh"

if SSH_CONNECTION='198.51.100.20 54321 192.0.2.10 22' bash -c '
    source "$1"
    state_set ssh_migration_old_port 22
    state_set ssh_migration_new_port 34567
    ssh_new_session_detected() { return 0; }
    current_ssh_session_uses_port() { return 1; }
    sshd_has_port() { return 0; }
    ssh_port_listening() { return 0; }
    remove_old_ssh_port 22 34567 0
' _ "$ROOT/modules/security.sh"; then
    echo 'manual old-port deletion unexpectedly accepted an old-port session' >&2
    exit 1
fi
state_unset ssh_migration_old_port
state_unset ssh_migration_new_port

# 32. SSH Port 指令的空格/等号两种写法都必须被规范化，避免留下脏的 Port= 配置。
ssh_cfg_eq="$TEST_STATE_ROOT/sshd_config.port-equals.test"
cat > "$ssh_cfg_eq" <<'EOF'
Port=22
Port = 2200
PermitRootLogin yes

Match User test
    Port=2201
EOF
bash -c 'source "$1"; SSHD_CONFIG="$2"; set_sshd_ports_global 22 34567; grep -qx "Port 22" "$SSHD_CONFIG"; grep -qx "Port 34567" "$SSHD_CONFIG"; grep -qx "Port 2200" "$SSHD_CONFIG"; ! grep -qE "^[[:space:]]*Port[[:space:]]*=" "$SSHD_CONFIG"; grep -q "^Match User test$" "$SSHD_CONFIG"; grep -q "^    Port=2201$" "$SSHD_CONFIG"' _ "$ROOT/modules/security.sh" "$ssh_cfg_eq"

# 33. 自动删除的二次检测必须存在，避免第一次发现后瞬时状态变化造成假失败。
grep -q '^confirm_new_ssh_session()' "$ROOT/modules/security.sh"
grep -qF 'confirm_new_ssh_session "$new_port" 10' "$ROOT/modules/security.sh"

# 34. SSH 迁移必须提供安全回退菜单项。
grep -q '放弃本次迁移并恢复原 SSH 端口' "$ROOT/modules/security.sh"
grep -q '^cancel_ssh_port_migration()' "$ROOT/modules/security.sh"

# 35. 防火墙重复进入时应先展示当前状态；已启用后不应再次询问“立即启用”。
grep -q '^firewall_show_allowed()' "$ROOT/modules/security.sh"
grep -q 'UFW 已启用，不需要再次执行“立即启用”' "$ROOT/modules/security.sh"
grep -q 'firewalld 已运行，不需要再次执行“立即启用”' "$ROOT/modules/security.sh"
grep -q '以后再次进入本选项将只展示当前状态' "$ROOT/modules/security.sh"

# 36. README 必须包含迁移回退与防火墙状态式流程说明。
grep -q '模块 1 → 3 → 4 放弃迁移并恢复原端口' "$ROOT/README.md"
grep -q '不会重复出现“立即启用”提示' "$ROOT/README.md"

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
awk '/cancel_ssh_port_migration\(\)/,/^}/' "$ROOT/modules/security.sh" | grep -q 'if ! firewall_remove_owned_rules'

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

echo 'smoke tests: OK'
