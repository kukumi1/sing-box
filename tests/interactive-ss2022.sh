#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-interactive-ss2022-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
TEST_HOME=$TEST_ROOT/etc/sing-box
TEST_LIB=$TEST_ROOT/lib
mkdir -p "$TEST_HOME/conf.d" "$TEST_HOME/nodes" "$TEST_HOME/certs" "$TEST_HOME/backups" "$TEST_LIB"
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

printf '%s\n' '{"log":{"level":"error"},"outbounds":[{"type":"direct","tag":"direct"}]}' >"$TEST_HOME/config.json"
printf '%s\n' '{"schema":1,"manager_version":"test","server_address":"203.0.113.10"}' >"$TEST_HOME/manager.json"

run_menu() {
  SB_HOME=$TEST_HOME SB_LIB_DIR=$TEST_LIB SB_LOCK_FILE=$TEST_ROOT/menu.lock sh "$REPO_DIR/sb"
}

printf '%s\n' 1 2 interactive-ss2022 33102 203.0.113.10 43102 3 0 | run_menu >/dev/null
meta=$TEST_HOME/nodes/interactive-ss2022.json
[ "$(jq -r '.credentials.method' "$meta")" = '2022-blake3-chacha20-poly1305' ]
old_key=$(jq -r '.credentials.password' "$meta")
[ "$(printf '%s' "$old_key" | base64 -d | wc -c | tr -d ' ')" = 32 ]

printf '%s\n' 6 1 '' '' 2 0 | run_menu >/dev/null
[ "$(jq -r '.credentials.method' "$meta")" = '2022-blake3-aes-256-gcm' ]
new_key=$(jq -r '.credentials.password' "$meta")
[ "$old_key" != "$new_key" ]
[ "$(printf '%s' "$new_key" | base64 -d | wc -c | tr -d ' ')" = 32 ]
jq -e '.inbounds[0].method == "2022-blake3-aes-256-gcm" and .inbounds[0].password == $password' --arg password "$new_key" "$TEST_HOME/conf.d/interactive-ss2022.json" >/dev/null

printf 'Interactive SS2022 method test passed.\n'