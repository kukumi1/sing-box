#!/bin/sh
set -eu
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-ipv6-test.XXXXXX)
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
run_sb() { SB_HOME=$TEST_HOME SB_LIB_DIR=$TEST_LIB SB_LOCK_FILE=$TEST_ROOT/lock sh "$REPO_DIR/sb" "$@"; }
run_sb add ss2022 --name v6-node --address-family ipv6 --public-address 2001:db8::10 --listen-port 34001 --public-port 44001 >/dev/null
jq -e '.address_family == "ipv6" and .listen.address == "::" and .public.address == "2001:db8::10"' "$TEST_HOME/nodes/v6-node.json" >/dev/null
run_sb url v6-node | grep -Fq '@[2001:db8::10]:44001'
run_sb client v6-node | jq -e '.server == "2001:db8::10" and .server_port == 44001' >/dev/null
run_sb add anytls --name v6-anytls --address-family ipv6 --public-address 2001:db8::11 --listen-port 34002 --public-port 44002 >/dev/null
run_sb url v6-anytls | grep -Fq '@[2001:db8::11]:44002'
run_sb add ss2022 --name dual-node --address-family dual --public-address 2001:db8::12 --listen-port 34003 --public-port 44003 >/dev/null
jq -e '.address_family == "dual" and .listen.address == "::"' "$TEST_HOME/nodes/dual-node.json" >/dev/null
run_sb url dual-node | grep -Fq '@[2001:db8::12]:44003'
run_sb delete v6-node --yes >/dev/null
[ ! -f "$TEST_HOME/nodes/v6-node.json" ]
sing-box check -c "$TEST_HOME/config.json" -C "$TEST_HOME/conf.d"
printf 'IPv6 integration test passed.\n'
