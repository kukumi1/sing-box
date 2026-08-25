#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-extended-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

export SB_HOME=$TEST_ROOT/etc/sing-box
. "$REPO_DIR/lib/common.sh"
. "$REPO_DIR/lib/protocols.sh"
. "$REPO_DIR/lib/protocols_extended.sh"

install -d -m 0755 "$SB_CONF_DIR" "$SB_CERT_DIR"
install -d -m 0700 "$SB_NODE_DIR"
printf '%s\n' '{"log":{"level":"error"}}' >"$SB_BASE_CONFIG"

create_extended() {
  protocol=$1; name=$2; port=$3; transport=$4; tls_mode=$5; tls_sni=${6:-example.com}
  meta="$SB_NODE_DIR/$name.json"; config="$SB_CONF_DIR/$name.json"; certs="$SB_CERT_DIR/$name"
  protocol_generate "$meta" "$protocol" "$name" 0.0.0.0 "$port" example.com "$port" default '' \
    2022-blake3-aes-128-gcm developer.apple.com 443 "$tls_sni" '' '' "$certs" "$transport" /proxy example.com "$tls_mode" admin@example.com ''
  protocol_render "$meta" "$config"
}

create_extended hysteria2 test-hy2 32001 tcp self-signed developer.apple.com
create_extended tuic test-tuic 32002 tcp self-signed developer.apple.com
create_extended trojan test-trojan 32003 ws caddy
create_extended vmess test-vmess-tcp 32004 tcp none
create_extended vmess test-vmess-quic 32005 quic self-signed
create_extended vless-tls test-vless-ws 32006 ws self-signed
create_extended anytls test-anytls-acme 32007 tcp acme

[ "$(jq -r '.tls.server_name' "$SB_NODE_DIR/test-hy2.json")" = developer.apple.com ]
[ "$(jq -r '.tls.server_name' "$SB_NODE_DIR/test-tuic.json")" = developer.apple.com ]
protocol_share_uri "$SB_NODE_DIR/test-hy2.json" | grep -Fq 'sni=developer.apple.com'
protocol_share_uri "$SB_NODE_DIR/test-tuic.json" | grep -Fq 'sni=developer.apple.com'

sing-box check -c "$SB_BASE_CONFIG" -C "$SB_CONF_DIR"
printf 'Extended protocol render test passed.\n'
