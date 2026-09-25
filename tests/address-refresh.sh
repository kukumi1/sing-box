#!/bin/sh
set -eu
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(mktemp -d /tmp/sb-address-refresh.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT HUP INT TERM
mkdir -p "$ROOT/bin" "$ROOT/etc/sing-box"
cat >"$ROOT/bin/curl" <<'EOF'
#!/bin/sh
case " $* " in *' -4 '*) printf '198.51.100.20\n' ;; *) exit 1 ;; esac
EOF
chmod +x "$ROOT/bin/curl"
printf '%s\n' '{"schema":1,"server_address":"34.80.47.10"}' >"$ROOT/etc/sing-box/manager.json"
SB_HOME="$ROOT/etc/sing-box" SB_MANAGER_CONFIG="$ROOT/etc/sing-box/manager.json" PATH="$ROOT/bin:$PATH" sh -c '. "$1/lib/common.sh"; [ "$(manager_server_address)" = 198.51.100.20 ]; [ "$(jq -r .server_address "$SB_MANAGER_CONFIG")" = 198.51.100.20 ]' sh "$REPO_DIR"
printf '%s\n' '{"schema":1,"server_address":"node.example.com"}' >"$ROOT/etc/sing-box/manager.json"
SB_HOME="$ROOT/etc/sing-box" SB_MANAGER_CONFIG="$ROOT/etc/sing-box/manager.json" PATH="$ROOT/bin:$PATH" sh -c '. "$1/lib/common.sh"; [ "$(manager_server_address)" = node.example.com ]' sh "$REPO_DIR"
printf 'Address refresh test passed.\n'
