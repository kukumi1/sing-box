#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-crud-test.XXXXXX)
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
service_status() { printf 'test service active\n'; }
service_logs() { :; }
EOF

printf '%s\n' '{"log":{"level":"error"}}' >"$TEST_HOME/config.json"
printf '%s\n' '{"schema":1,"manager_version":"test","server_address":"203.0.113.10"}' >"$TEST_HOME/manager.json"

run_sb() {
  SB_HOME=$TEST_HOME SB_LIB_DIR=$TEST_LIB SB_LOCK_FILE=$TEST_ROOT/sb-manager.lock sh "$REPO_DIR/sb" "$@"
}

run_sb add ss2022 --name first-node --listen-port 33001 --public-port 43001 >/dev/null
run_sb add socks5 --name second-node --listen-port 33002 --public-port 43002 >/dev/null
run_sb add anytls --name anytls-node --listen-port 33003 --public-port 43003 --password test-anytls-password >/dev/null

anytls_url=$(run_sb url anytls-node)
[ "$anytls_url" = 'anytls://test-anytls-password@203.0.113.10:43003?insecure=1&fp=chrome#anytls-node' ]

menu_output=$(printf '4\n1\n0\n' | SB_HOME=$TEST_HOME SB_LIB_DIR=$TEST_LIB SB_LOCK_FILE=$TEST_ROOT/menu.lock sh "$REPO_DIR/sb")
printf '%s\n' "$menu_output" | grep -Fq "$anytls_url"
printf '%s\n' "$menu_output" | grep -Fq '1) anytls-node  [anytls]  203.0.113.10:43003'

[ -f "$TEST_HOME/nodes/first-node.json" ]
[ -f "$TEST_HOME/nodes/second-node.json" ]
[ -f "$TEST_HOME/nodes/anytls-node.json" ]
[ -f "$TEST_HOME/conf.d/first-node.json" ]
[ -f "$TEST_HOME/conf.d/second-node.json" ]
[ -f "$TEST_HOME/conf.d/anytls-node.json" ]

run_sb list | grep -q first-node
run_sb list | grep -q second-node
run_sb list | grep -q anytls-node

run_sb disable first-node >/dev/null
[ "$(jq -r '.enabled' "$TEST_HOME/nodes/first-node.json")" = false ]
[ ! -f "$TEST_HOME/conf.d/first-node.json" ]

run_sb enable first-node >/dev/null
[ "$(jq -r '.enabled' "$TEST_HOME/nodes/first-node.json")" = true ]
[ -f "$TEST_HOME/conf.d/first-node.json" ]

old_password=$(jq -r '.credentials.password' "$TEST_HOME/nodes/second-node.json")
run_sb rotate second-node >/dev/null
new_password=$(jq -r '.credentials.password' "$TEST_HOME/nodes/second-node.json")
[ "$old_password" != "$new_password" ]

run_sb change second-node --public-port 44002 >/dev/null
run_sb url second-node | grep -q ':44002'

run_sb export --all --format json | jq -e '.nodes | length == 3' >/dev/null

run_sb delete first-node --yes >/dev/null
[ ! -f "$TEST_HOME/nodes/first-node.json" ]
[ -f "$TEST_HOME/nodes/second-node.json" ]
[ -f "$TEST_HOME/nodes/anytls-node.json" ]

printf 'n\n' | run_sb delete-all >/dev/null
[ -f "$TEST_HOME/nodes/second-node.json" ]
[ -f "$TEST_HOME/nodes/anytls-node.json" ]
run_sb delete-all --yes >/dev/null
[ ! -f "$TEST_HOME/nodes/second-node.json" ]
[ ! -f "$TEST_HOME/nodes/anytls-node.json" ]
[ ! -f "$TEST_HOME/conf.d/second-node.json" ]
[ ! -f "$TEST_HOME/conf.d/anytls-node.json" ]

sing-box check -c "$TEST_HOME/config.json" -C "$TEST_HOME/conf.d"
printf 'CRUD integration test passed.\n'
