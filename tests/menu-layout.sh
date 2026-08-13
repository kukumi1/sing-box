#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-menu-layout-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
TEST_HOME=$TEST_ROOT/etc/sing-box
TEST_LIB=$TEST_ROOT/lib
TEST_BIN=$TEST_ROOT/bin
mkdir -p "$TEST_HOME/conf.d" "$TEST_HOME/nodes" "$TEST_HOME/certs" "$TEST_HOME/backups" "$TEST_LIB" "$TEST_BIN"
cp "$REPO_DIR"/lib/*.sh "$TEST_LIB/"

cat >"$TEST_LIB/platform.sh" <<'EOF'
#!/bin/sh
detect_platform() { SB_PLATFORM=test; }
service_active() { return 0; }
service_enabled() { return 0; }
service_start() { return 0; }
service_stop() { return 0; }
service_restart() { return 0; }
service_enable() { return 0; }
service_disable() { return 0; }
service_status() { :; }
service_logs() { :; }
EOF

cat >"$TEST_BIN/sing-box" <<'EOF'
#!/bin/sh
printf '%s\n' 'sing-box version 1.12.0'
EOF
chmod +x "$TEST_BIN/sing-box"

printf '%s\n' '{"log":{"level":"error"}}' >"$TEST_HOME/config.json"
printf '%s\n' '{"schema":1,"manager_version":"test","server_address":"203.0.113.10"}' >"$TEST_HOME/manager.json"

run_menu() {
  SB_HOME=$TEST_HOME SB_LIB_DIR=$TEST_LIB SB_LOCK_FILE=$TEST_ROOT/menu.lock SB_PATH=$TEST_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sh "$REPO_DIR/sb"
}

main_output=$TEST_ROOT/main-output.txt
printf '%s\n' 0 | run_menu >"$main_output"
grep -F 'sb · sing-box 管理器' "$main_output" >/dev/null
grep -F '【节点管理】' "$main_output" >/dev/null
grep -F '【服务与维护】' "$main_output" >/dev/null
grep -F '【网络工具】' "$main_output" >/dev/null
grep -F '[18] 删除全部节点' "$main_output" >/dev/null
grep -F '请选择操作 [0-18]:' "$main_output" >/dev/null
if grep -q "$(printf '\033')" "$main_output"; then
  printf '%s\n' 'Expected non-interactive menu output without ANSI escape codes.' >&2
  exit 1
fi

forward_output=$TEST_ROOT/forward-output.txt
printf '%s\n' 17 0 0 | run_menu >"$forward_output"
grep -F '【动态端口转发】' "$forward_output" >/dev/null
grep -F '[9] 删除全部转发' "$forward_output" >/dev/null
grep -F '请选择操作 [0-9]:' "$forward_output" >/dev/null
if grep -F '按 Enter 返回主菜单' "$forward_output" >/dev/null; then
  printf '%s\n' 'Expected non-interactive forwarding return without a pause prompt.' >&2
  exit 1
fi

printf '%s\n' 'Interactive menu layout test passed.'
