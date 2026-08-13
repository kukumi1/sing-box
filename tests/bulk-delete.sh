#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-bulk-delete-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
TEST_HOME=$TEST_ROOT/etc/sing-box
TEST_LIB=$TEST_ROOT/lib
TEST_BIN=$TEST_ROOT/bin
mkdir -p "$TEST_HOME/conf.d" "$TEST_HOME/nodes" "$TEST_HOME/certs" "$TEST_HOME/backups" "$TEST_HOME/forwards" "$TEST_LIB" "$TEST_BIN"
cp "$REPO_DIR"/lib/*.sh "$TEST_LIB/"

cat >"$TEST_LIB/platform.sh" <<'EOF'
#!/bin/sh
detect_platform() { SB_PLATFORM=alpine; }
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
case "${1:-}" in
  version) printf '%s\n' 'sing-box version 1.13.18' ;;
  check) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"$TEST_BIN/getent" <<'EOF'
#!/bin/sh
printf '%s\n' '198.51.100.42 STREAM target.example'
EOF
cat >"$TEST_BIN/iptables" <<'EOF'
#!/bin/sh
printf 'iptables %s\n' "$*" >>"$FW_LOG"
EOF
cat >"$TEST_BIN/iptables-save" <<'EOF'
#!/bin/sh
printf '%s\n' '*filter' 'COMMIT'
EOF
cat >"$TEST_BIN/iptables-restore" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' 'iptables-restore' >>"$FW_LOG"
EOF
cat >"$TEST_BIN/sysctl" <<'EOF'
#!/bin/sh
printf 'sysctl %s\n' "$*" >>"$FW_LOG"
EOF
chmod +x "$TEST_BIN"/*

printf '%s\n' '{"log":{"level":"error"}}' >"$TEST_HOME/config.json"
printf '%s\n' '{"schema":1,"manager_version":"test","server_address":"203.0.113.10"}' >"$TEST_HOME/manager.json"
printf '%s\n' '{"name":"node-one","enabled":true,"listen":{"port":31001}}' >"$TEST_HOME/nodes/node-one.json"
printf '%s\n' '{"name":"node-two","enabled":false,"listen":{"port":31002}}' >"$TEST_HOME/nodes/node-two.json"
printf '%s\n' '{"type":"socks"}' >"$TEST_HOME/conf.d/node-one.json"
printf '%s\n' '{"type":"socks"}' >"$TEST_HOME/conf.d/node-two.json"
mkdir -p "$TEST_HOME/certs/node-one"
printf '%s\n' 'certificate' >"$TEST_HOME/certs/node-one/cert.pem"

export FW_LOG=$TEST_ROOT/iptables.log
export SB_HOME=$TEST_HOME
export SB_LIB_DIR=$TEST_LIB
export SB_LOCK_FILE=$TEST_ROOT/sb.lock
export SB_FORWARD_SYNC_LOCK=$TEST_ROOT/forward.lock
export SB_FORWARD_SYSCTL_FILE=$TEST_ROOT/sysctl.d/99-sb-forward.conf
export SB_FORWARD_SKIP_SCHEDULER=1
export SB_PATH=$TEST_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

run_sb() {
  sh "$REPO_DIR/sb" "$@"
}

printf 'n\n' | run_sb delete-all >/dev/null
[ -f "$TEST_HOME/nodes/node-one.json" ]
[ -f "$TEST_HOME/nodes/node-two.json" ]
run_sb delete-all --yes >/dev/null
[ ! -f "$TEST_HOME/nodes/node-one.json" ]
[ ! -f "$TEST_HOME/nodes/node-two.json" ]
[ ! -f "$TEST_HOME/conf.d/node-one.json" ]
[ ! -f "$TEST_HOME/conf.d/node-two.json" ]
[ ! -d "$TEST_HOME/certs/node-one" ]

printf '%s\n' '{"name":"forward-one","enabled":true,"listen_port":32001,"target":{"host":"target.example","port":32001},"protocols":["tcp"],"resolved_ip":"198.51.100.42"}' >"$TEST_HOME/forwards/forward-one.json"
printf '%s\n' '{"name":"forward-two","enabled":false,"listen_port":32002,"target":{"host":"target.example","port":32002},"protocols":["udp"],"resolved_ip":"198.51.100.42"}' >"$TEST_HOME/forwards/forward-two.json"

printf 'n\n' | run_sb forward delete-all >/dev/null
[ -f "$TEST_HOME/forwards/forward-one.json" ]
[ -f "$TEST_HOME/forwards/forward-two.json" ]
run_sb forward delete-all --yes >/dev/null
[ ! -f "$TEST_HOME/forwards/forward-one.json" ]
[ ! -f "$TEST_HOME/forwards/forward-two.json" ]
grep -Fq -- '-F SB_DNAT' "$FW_LOG"
grep -Fq -- '-F SB_SNAT' "$FW_LOG"
grep -Fq -- '-F SB_FORWARD' "$FW_LOG"

printf '%s\n' 'Bulk delete integration test passed.'
