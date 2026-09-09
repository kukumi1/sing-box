#!/bin/sh
set -eu

apt-get update -qq
apt-get install -y --no-install-recommends -qq \
  ca-certificates curl jq openssl tar util-linux iproute2 qrencode iptables procps socat systemd

mock_systemctl=/usr/local/bin/systemctl
mock_apt=/usr/local/bin/apt-get
mock_sing_box=/usr/bin/sing-box
test ! -e "$mock_systemctl"
test ! -e "$mock_apt"
test ! -e "$mock_sing_box"
trap 'rm -f "$mock_systemctl" "$mock_apt" "$mock_sing_box"' EXIT INT TERM
cp /bin/true "$mock_systemctl"
test "$(command -v systemctl)" = "$mock_systemctl"

cat >"$mock_apt" <<'EOF'
#!/bin/sh
printf '%s\n' "unexpected apt-get invocation: $*" >&2
exit 1
EOF
chmod 0755 "$mock_apt"

cat >"$mock_sing_box" <<'EOF'
#!/bin/sh
case "${1:-}" in
  version) printf '%s\n' 'sing-box version 1.14.0' ;;
  check) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$mock_sing_box"

sh ./install.sh --server-address 203.0.113.10

test "$(stat -c '%U:%G' /etc/sing-box)" = 'root:sing-box'
su -s /bin/sh -c 'test -r /etc/sing-box/config.json && sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d' sing-box
