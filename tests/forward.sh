#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-forward-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/etc/sing-box/nodes" "$TEST_ROOT/etc/sing-box/conf.d" "$TEST_ROOT/etc/sing-box/certs" "$TEST_ROOT/etc/sing-box/backups" "$TEST_ROOT/etc/sing-box/forwards"

cat >"$TEST_ROOT/bin/iptables" <<'EOF'
#!/bin/sh
printf 'iptables %s\n' "$*" >>"$FW_LOG"
if [ -n "${FW_IPTABLES_FAIL_PORT:-}" ] && printf '%s' "$*" | grep -Fq -- "--dport $FW_IPTABLES_FAIL_PORT"; then
  exit 1
fi
exit 0
EOF
cat >"$TEST_ROOT/bin/iptables-save" <<'EOF'
#!/bin/sh
printf '*filter\nCOMMIT\n'
EOF
cat >"$TEST_ROOT/bin/iptables-restore" <<'EOF'
#!/bin/sh
cat >/dev/null
printf 'iptables-restore\n' >>"$FW_LOG"
EOF
cat >"$TEST_ROOT/bin/sysctl" <<'EOF'
#!/bin/sh
printf 'sysctl %s\n' "$*" >>"$FW_LOG"
EOF
cat >"$TEST_ROOT/bin/getent" <<'EOF'
#!/bin/sh
[ "${FW_DNS_FAIL:-0}" != 1 ] || exit 2
printf '%s STREAM target.example\n' "${FW_DNS_IP:-198.51.100.42}"
EOF
cat >"$TEST_ROOT/bin/sing-box" <<'EOF'
#!/bin/sh
case "${1:-}" in
  version) printf 'sing-box version 1.13.14\n' ;;
  check) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin"/*

printf '%s\n' '{"log":{"level":"error"}}' >"$TEST_ROOT/etc/sing-box/config.json"
printf '%s\n' '{"schema":1,"manager_version":"test","server_address":"203.0.113.10"}' >"$TEST_ROOT/etc/sing-box/manager.json"

export PATH="$TEST_ROOT/bin:$PATH"
export SB_PATH=$PATH
export FW_LOG=$TEST_ROOT/iptables.log
export SB_HOME=$TEST_ROOT/etc/sing-box
export SB_LIB_DIR=$REPO_DIR/lib
export SB_LOCK_FILE=$TEST_ROOT/manager.lock
export SB_FORWARD_SYNC_LOCK=$TEST_ROOT/forward.lock
export SB_FORWARD_SYSCTL_FILE=$TEST_ROOT/sysctl.d/99-sb-forward.conf
export SB_FORWARD_SKIP_SCHEDULER=1

run_sb() { sh "$REPO_DIR/sb" "$@"; }

run_sb forward add --name dynamic-test --listen-port 30009 --target-host target.example --target-port 30009 --protocol both >/dev/null
config=$SB_HOME/forwards/dynamic-test.json
[ -f "$config" ]
created_at=$(jq -r '.created_at' "$config")
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.42 ]
grep -Fq -- '-p tcp --dport 30009 -j DNAT --to-destination 198.51.100.42:30009' "$FW_LOG"
grep -Fq -- '-p udp --dport 30009 -j DNAT --to-destination 198.51.100.42:30009' "$FW_LOG"
grep -Fq -- '-d 198.51.100.42 --dport 30009 -j MASQUERADE' "$FW_LOG"
[ "$(cat "$SB_FORWARD_SYSCTL_FILE")" = 'net.ipv4.ip_forward=1' ]

: >"$FW_LOG"
FW_DNS_IP=198.51.100.77 run_sb forward sync --quiet
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.77 ]
grep -Fq -- '--to-destination 198.51.100.77:30009' "$FW_LOG"

FW_DNS_FAIL=1 run_sb forward sync --quiet
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.77 ]

if run_sb forward change dynamic-test >/dev/null 2>&1; then
  printf 'forward change without options unexpectedly succeeded\n' >&2
  exit 1
fi
if run_sb forward change missing-rule --target-port 31000 >/dev/null 2>&1; then
  printf 'forward change for a missing rule unexpectedly succeeded\n' >&2
  exit 1
fi

: >"$FW_LOG"
run_sb forward change dynamic-test --target-port 31009 >/dev/null
[ "$(jq -r '.listen_port' "$config")" = 30009 ]
[ "$(jq -r '.target.host' "$config")" = target.example ]
[ "$(jq -r '.target.port' "$config")" = 31009 ]
[ "$(jq -r '.protocols|join("+")' "$config")" = tcp+udp ]
grep -Fq -- '--dport 30009 -j DNAT --to-destination 198.51.100.42:31009' "$FW_LOG"

: >"$FW_LOG"
FW_DNS_IP=203.0.113.9 run_sb forward change dynamic-test --listen-port 31000 --target-host new.example --target-port 32000 --protocol udp >/dev/null
[ "$(jq -r '.name' "$config")" = dynamic-test ]
[ "$(jq -r '.enabled' "$config")" = true ]
[ "$(jq -r '.created_at' "$config")" = "$created_at" ]
[ "$(jq -r '.listen_port' "$config")" = 31000 ]
[ "$(jq -r '.target.host' "$config")" = new.example ]
[ "$(jq -r '.target.port' "$config")" = 32000 ]
[ "$(jq -r '.protocols|join("+")' "$config")" = udp ]
[ "$(jq -r '.resolved_ip' "$config")" = 203.0.113.9 ]
grep -Fq -- '-p udp --dport 31000 -j DNAT --to-destination 203.0.113.9:32000' "$FW_LOG"
if grep -Fq -- '-p tcp --dport 31000' "$FW_LOG"; then
  printf 'forward change left an obsolete TCP rule\n' >&2
  exit 1
fi

run_sb forward add --name tcp-conflict --listen-port 32001 --target-host target.example --target-port 32001 --protocol tcp >/dev/null
if run_sb forward change dynamic-test --listen-port 32001 --protocol both >/dev/null 2>&1; then
  printf 'overlapping forward protocol conflict was not rejected\n' >&2
  exit 1
fi
run_sb forward change dynamic-test --listen-port 32001 --protocol udp >/dev/null
[ "$(jq -r '.listen_port' "$config")" = 32001 ]
[ "$(jq -r '.protocols|join("+")' "$config")" = udp ]

printf '%s\n' '{"name":"node-conflict","listen":{"port":32002}}' >"$SB_HOME/nodes/node-conflict.json"
if run_sb forward change dynamic-test --listen-port 32002 >/dev/null 2>&1; then
  printf 'sing-box node port conflict was not rejected\n' >&2
  exit 1
fi
rm -f "$SB_HOME/nodes/node-conflict.json"
[ "$(jq -r '.listen_port' "$config")" = 32001 ]

old_host=$(jq -r '.target.host' "$config")
old_ip=$(jq -r '.resolved_ip' "$config")
if FW_DNS_FAIL=1 run_sb forward change dynamic-test --target-host unavailable.example >/dev/null 2>&1; then
  printf 'forward change with an unresolvable new host unexpectedly succeeded\n' >&2
  exit 1
fi
[ "$(jq -r '.target.host' "$config")" = "$old_host" ]
[ "$(jq -r '.resolved_ip' "$config")" = "$old_ip" ]

: >"$FW_LOG"
if FW_IPTABLES_FAIL_PORT=33000 run_sb forward change dynamic-test --target-port 33000 >/dev/null 2>&1; then
  printf 'forward change with an iptables failure unexpectedly succeeded\n' >&2
  exit 1
fi
[ "$(jq -r '.target.port' "$config")" = 32000 ]
grep -Fq 'iptables-restore' "$FW_LOG"

run_sb forward disable dynamic-test >/dev/null
[ "$(jq -r '.enabled' "$config")" = false ]
: >"$FW_LOG"
FW_DNS_FAIL=1 run_sb forward change dynamic-test --target-host disabled.example --target-port 34000 >/dev/null
[ "$(jq -r '.enabled' "$config")" = false ]
[ "$(jq -r '.target.host' "$config")" = disabled.example ]
[ "$(jq -r '.target.port' "$config")" = 34000 ]
[ -z "$(jq -r '.resolved_ip' "$config")" ]
if grep -Fq -- ':34000' "$FW_LOG"; then
  printf 'disabled forward change unexpectedly applied iptables rules\n' >&2
  exit 1
fi
FW_DNS_IP=203.0.113.44 run_sb forward enable dynamic-test >/dev/null
[ "$(jq -r '.enabled' "$config")" = true ]
run_sb forward list | grep -Fq 'disabled.example:34000'
printf 'n\n' | run_sb forward delete-all >/dev/null
[ -f "$SB_HOME/forwards/tcp-conflict.json" ]
[ -f "$config" ]
run_sb forward delete-all --yes >/dev/null
[ ! -f "$SB_HOME/forwards/tcp-conflict.json" ]
[ ! -f "$config" ]
grep -Fq -- '-F SB_DNAT' "$FW_LOG"
grep -Fq -- '-F SB_SNAT' "$FW_LOG"
grep -Fq -- '-F SB_FORWARD' "$FW_LOG"

printf 'Dynamic forwarding integration test passed.\n'
