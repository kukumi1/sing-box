#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-alpine-migration.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

cat >"$TEST_ROOT/legacy.json" <<'EOF'
{
  "log": {"level": "info"},
  "dns": {"servers": [{"address": "tls://8.8.8.8"}]},
  "inbounds": [{"type": "shadowsocks", "listen_port": 30010, "password": "test-secret"}],
  "outbounds": [{"type": "direct"}, {"type": "dns", "tag": "dns-out"}],
  "route": {"rules": [{"port": 53, "outbound": "dns-out"}]}
}
EOF

jq -n '
  {
    log:{level:"info"},
    dns:{servers:[{address:"tls://8.8.8.8"}]},
    outbounds:[{type:"direct",tag:"direct"},{type:"dns",tag:"dns-out"}],
    route:{rules:[{port:53,outbound:"dns-out"}]}
  }
' >"$TEST_ROOT/managed-base.json"
jq -e -f "$REPO_DIR/lib/sing-box-1.12-managed-base-legacy.jq" "$TEST_ROOT/managed-base.json" >/dev/null

jq -f "$REPO_DIR/lib/sing-box-1.12-migration.jq" "$TEST_ROOT/legacy.json" >"$TEST_ROOT/migrated.json"

jq -e '
  .dns.servers == [{"type":"tls","tag":"google-dns","server":"8.8.8.8","server_port":853}] and
  (.route.rules == [{"port":53,"action":"hijack-dns"}]) and
  (has("outbounds") | not) and
  (.inbounds[0].type == "shadowsocks") and
  (.inbounds[0].password == "test-secret")
' "$TEST_ROOT/migrated.json" >/dev/null

printf 'Alpine sing-box 1.12 migration test passed.\n'
