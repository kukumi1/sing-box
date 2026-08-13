#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-interactive-socks-test.XXXXXX)
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

printf '%s\n' '{"log":{"level":"error"}}' >"$TEST_HOME/config.json"
printf '%s\n' '{"schema":1,"manager_version":"test","server_address":"203.0.113.10"}' >"$TEST_HOME/manager.json"

run_menu() {
  SB_HOME=$TEST_HOME SB_LIB_DIR=$TEST_LIB SB_LOCK_FILE=$TEST_ROOT/menu.lock sh "$REPO_DIR/sb"
}

printf '%s\n' 1 4 interactive-socks 33101 203.0.113.10 43101 'custom user' 'pass:@ word' 0 | run_menu >/dev/null
meta=$TEST_HOME/nodes/interactive-socks.json
[ "$(jq -r '.credentials.username' "$meta")" = 'custom user' ]
[ "$(jq -r '.credentials.password' "$meta")" = 'pass:@ word' ]

printf '%s\n' 6 1 33111 '' '' 'changed user' 'changed:@ pass' 0 | run_menu >/dev/null
[ "$(jq -r '.listen.port' "$meta")" = 33111 ]
[ "$(jq -r '.credentials.username' "$meta")" = 'changed user' ]
[ "$(jq -r '.credentials.password' "$meta")" = 'changed:@ pass' ]
jq -e '.inbounds[0].listen_port == 33111 and .inbounds[0].users[0].username == "changed user" and .inbounds[0].users[0].password == "changed:@ pass"' "$TEST_HOME/conf.d/interactive-socks.json" >/dev/null
url=$(SB_HOME=$TEST_HOME SB_LIB_DIR=$TEST_LIB SB_LOCK_FILE=$TEST_ROOT/url.lock sh "$REPO_DIR/sb" url interactive-socks)
[ "$url" = 'socks5://changed%20user:changed%3A%40%20pass@203.0.113.10:43101#interactive-socks' ]

printf 'Interactive SOCKS5 credential test passed.\n'
