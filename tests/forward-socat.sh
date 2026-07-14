#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-forward-socat-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/etc/sing-box/nodes" "$TEST_ROOT/etc/sing-box/forwards" "$TEST_ROOT/systemd"

cat >"$TEST_ROOT/bin/iptables-save" <<'EOF'
#!/bin/sh
printf '%s\n' 'iptables-save v1.8.11 (nf_tables): Could not fetch rule set generation id: Permission denied (you must be root)' >&2
exit 1
EOF
cat >"$TEST_ROOT/bin/getent" <<'EOF'
#!/bin/sh
[ "${FW_DNS_FAIL:-0}" != 1 ] || exit 2
printf '%s STREAM relay.example\n' "${FW_DNS_IP:-198.51.100.42}"
EOF
cat >"$TEST_ROOT/bin/socat" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TEST_ROOT/bin/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$FW_LOG"
exit 0
EOF
chmod +x "$TEST_ROOT/bin"/*

export PATH="$TEST_ROOT/bin:$PATH"
export FW_LOG=$TEST_ROOT/systemctl.log
export SB_HOME=$TEST_ROOT/etc/sing-box
export SB_NODE_DIR=$SB_HOME/nodes
export SB_FORWARD_DIR=$SB_HOME/forwards
export SB_FORWARD_SYNC_LOCK=$TEST_ROOT/forward.lock
export SB_FORWARD_SYSTEMD_DIR=$TEST_ROOT/systemd
export SB_FORWARD_SKIP_SCHEDULER=1
export SB_FORWARD_BACKEND=auto
SB_PLATFORM=systemd

. "$REPO_DIR/lib/output.sh"
. "$REPO_DIR/lib/common.sh"
. "$REPO_DIR/lib/forward.sh"

command_forward_add --name relay-test --listen-port 30009 --target-host relay.example --target-port 31009 --protocol both >/dev/null
config=$SB_FORWARD_DIR/relay-test.json
unit_tcp=$(forward_socat_unit_name relay-test tcp)
unit_udp=$(forward_socat_unit_name relay-test udp)
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.42 ]
grep -Fq 'TCP4-LISTEN:30009,reuseaddr,fork TCP4:198.51.100.42:31009' "$SB_FORWARD_SYSTEMD_DIR/$unit_tcp"
grep -Fq 'UDP4-RECVFROM:30009,reuseaddr,fork UDP4-SENDTO:198.51.100.42:31009' "$SB_FORWARD_SYSTEMD_DIR/$unit_udp"
grep -Fq "systemctl restart $unit_tcp" "$FW_LOG"
grep -Fq "systemctl restart $unit_udp" "$FW_LOG"
[ ! -e "$TEST_ROOT/sysctl.d/99-sb-forward.conf" ]

: >"$FW_LOG"
FW_DNS_IP=198.51.100.77 command_forward_sync --quiet
[ "$(jq -r '.resolved_ip' "$config")" = 198.51.100.77 ]
grep -Fq 'TCP4:198.51.100.77:31009' "$SB_FORWARD_SYSTEMD_DIR/$unit_tcp"
grep -Fq "systemctl restart $unit_tcp" "$FW_LOG"
grep -Fq "systemctl restart $unit_udp" "$FW_LOG"

FW_DNS_IP=203.0.113.9 command_forward_change relay-test --target-port 32000 --protocol udp >/dev/null
[ ! -f "$SB_FORWARD_SYSTEMD_DIR/$unit_tcp" ]
grep -Fq 'UDP4-SENDTO:203.0.113.9:32000' "$SB_FORWARD_SYSTEMD_DIR/$unit_udp"

command_forward_set_enabled false relay-test >/dev/null
[ ! -f "$SB_FORWARD_SYSTEMD_DIR/$unit_udp" ]
FW_DNS_IP=203.0.113.44 command_forward_set_enabled true relay-test >/dev/null
[ -f "$SB_FORWARD_SYSTEMD_DIR/$unit_udp" ]
command_forward_delete relay-test >/dev/null
[ ! -f "$config" ]
[ ! -f "$SB_FORWARD_SYSTEMD_DIR/$unit_udp" ]

printf 'socat forwarding fallback test passed.\n'