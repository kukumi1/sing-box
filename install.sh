#!/bin/sh

set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

SERVER_ADDRESS=
UPGRADE=0
FORCE=0
DRY_RUN=0
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  cat <<'EOF'
Usage: install.sh --server-address PUBLIC_ADDRESS [--force] [--dry-run]
       install.sh --upgrade

Installs the persistent `sb` multi-node manager on Alpine, Debian, or Ubuntu.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --server-address) [ "$#" -ge 2 ] || die '--server-address requires a value'; SERVER_ADDRESS=$2; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die 'run this installer as root'
[ -r /etc/os-release ] || die 'cannot identify operating system'
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in alpine) PLATFORM=alpine ;; debian|ubuntu) PLATFORM=systemd ;; *) die 'supported systems: Alpine, Debian, Ubuntu' ;; esac

[ -f "$SOURCE_DIR/sb" ] && [ -d "$SOURCE_DIR/lib" ] || die 'run install.sh from a complete repository checkout'

if [ "$UPGRADE" -eq 0 ]; then
  [ -n "$SERVER_ADDRESS" ] || die '--server-address is required for initial installation'
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run passed.\nPlatform: %s\nSource: %s\nUpgrade: %s\n' "$PLATFORM" "$SOURCE_DIR" "$UPGRADE"
  exit 0
fi

install_packages() {
  if [ "$PLATFORM" = alpine ]; then
    apk add --no-cache sing-box sing-box-openrc jq openssl ca-certificates curl tar util-linux
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl jq openssl tar util-linux iproute2
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod 0644 /etc/apt/keyrings/sagernet.asc
  cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update
  apt-get install -y --no-install-recommends sing-box
}

info 'Installing packages'
install_packages

existing_manager=0
[ -f /etc/sing-box/manager.json ] && existing_manager=1
legacy_config=0
[ -s /etc/sing-box/config.json ] && [ "$existing_manager" -eq 0 ] && legacy_config=1
if [ "$legacy_config" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
  die 'an existing unmanaged sing-box configuration was found; back it up and rerun with --force'
fi

backup=
if [ "$legacy_config" -eq 1 ]; then
  backup=/root/sing-box-legacy-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
  tar -C / -czf "$backup" etc/sing-box var/lib/sing-box-installer root/sing-box-client.txt 2>/dev/null || true
  chmod 0600 "$backup" 2>/dev/null || true
fi

info 'Installing sb manager files'
install -d -m 0755 /usr/local/lib/sb-manager /usr/local/bin
install -m 0755 "$SOURCE_DIR/sb" /usr/local/bin/sb
for file in "$SOURCE_DIR"/lib/*.sh; do install -m 0644 "$file" "/usr/local/lib/sb-manager/${file##*/}"; done

install -d -m 0750 /etc/sing-box /etc/sing-box/conf.d /etc/sing-box/certs
install -d -m 0700 /etc/sing-box/nodes /etc/sing-box/backups
install -d -m 0755 /var/lib/sing-box

if [ ! -f /etc/sing-box/config.json ] || [ "$legacy_config" -eq 1 ]; then
  cat >/etc/sing-box/config.json <<'EOF'
{
  "log": {"level": "info", "timestamp": true},
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
fi

if [ "$existing_manager" -eq 0 ]; then
  jq -n --arg server_address "$SERVER_ADDRESS" \
    '{schema:1,manager_version:"3.0.0",server_address:$server_address}' >/etc/sing-box/manager.json
fi

chmod 0640 /etc/sing-box/config.json
chmod 0600 /etc/sing-box/manager.json

if getent group sing-box >/dev/null 2>&1; then
  chown root:sing-box /etc/sing-box/config.json
  chown -R root:sing-box /etc/sing-box/conf.d /etc/sing-box/certs
fi

if [ "$PLATFORM" = alpine ]; then
  cat >/etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box managed by sb"
supervisor="supervise-daemon"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json -C /etc/sing-box/conf.d"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { after net dns firewall; }
start_pre() { /usr/bin/sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d; }
EOF
  chmod 0755 /etc/init.d/sing-box
  rc-update add sing-box default
else
  cat >/etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box managed by sb
After=network-online.target
Wants=network-online.target

[Service]
User=sing-box
Group=sing-box
ExecStartPre=/usr/bin/sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d
ExecStart=/usr/bin/sing-box run -D /var/lib/sing-box -c /etc/sing-box/config.json -C /etc/sing-box/conf.d
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
fi

sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d
if [ "$PLATFORM" = alpine ]; then rc-service sing-box restart || rc-service sing-box start; else systemctl restart sing-box; fi

printf '\nInstallation completed. Run: sb\n'
[ -z "$backup" ] || printf 'Legacy backup: %s\n' "$backup"
