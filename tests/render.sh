#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-render-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

export SB_HOME=$TEST_ROOT/etc/sing-box
export SB_LIB_DIR=$REPO_DIR/lib

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/protocols.sh
. "$REPO_DIR/lib/protocols.sh"

install -d -m 0755 "$SB_CONF_DIR" "$SB_CERT_DIR"
install -d -m 0700 "$SB_NODE_DIR"

cat >"$SB_BASE_CONFIG" <<'EOF'
{"log":{"level":"error"},"outbounds":[{"type":"direct","tag":"direct"}]}
EOF

create_node() {
  protocol=$1
  name=$2
  port=$3
  shift 3
  meta="$SB_NODE_DIR/$name.json"
  config="$SB_CONF_DIR/$name.json"
  cert_stage="$SB_CERT_DIR/$name"
  generate_node_metadata "$meta" "$protocol" "$name" 0.0.0.0 "$port" \
    203.0.113.10 "$((port + 10000))" default '' "${1:-2022-blake3-aes-128-gcm}" \
    "${2:-www.microsoft.com}" 443 '' '' "$cert_stage"
  render_node_config "$meta" "$config"
}

create_node anytls test-anytls 31001
create_node ss2022 test-ss2022 31002
create_node vless-reality test-reality 31003
create_node socks5 test-socks 31004

sing-box check -c "$SB_BASE_CONFIG" -C "$SB_CONF_DIR"

uri=$(node_share_uri "$SB_NODE_DIR/test-anytls.json")
printf '%s' "$uri" | grep -q '203.0.113.10:41001'

printf 'Multi-node render test passed.\n'
