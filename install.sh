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

detect_public_ipv4() {
  for public_ip_url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    public_ip=
    if command -v curl >/dev/null 2>&1; then
      public_ip=$(curl -4fsS --max-time 8 "$public_ip_url" 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
      public_ip=$(wget -qO- -T 8 "$public_ip_url" 2>/dev/null || true)
    fi
    public_ip=$(printf '%s' "$public_ip" | tr -d '[:space:]')
    if printf '%s' "$public_ip" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1; exit 0} {exit 1}'; then
      printf '%s\n' "$public_ip"
      return 0
    fi
  done
  return 1
}

bootstrap_download() {
  bootstrap_url=$1
  bootstrap_output=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 "$bootstrap_url" -o "$bootstrap_output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$bootstrap_output" "$bootstrap_url"
  else
    printf 'Error: curl or wget is required for one-command installation\n' >&2
    exit 1
  fi
}

bootstrap_if_needed() {
  [ -f "$SOURCE_DIR/sb" ] && [ -d "$SOURCE_DIR/lib" ] && return 0

  bootstrap_root=$(mktemp -d /tmp/sb-bootstrap.XXXXXX)
  trap 'rm -rf "$bootstrap_root"' EXIT HUP INT TERM
  bootstrap_base=https://github.com/kukumi1/sing-box/releases/latest/download

  printf '==> Downloading the latest verified sb manager release\n'
  bootstrap_download "$bootstrap_base/sb-manager.tar.gz" "$bootstrap_root/sb-manager.tar.gz"
  bootstrap_download "$bootstrap_base/sb-manager.tar.gz.sha256" "$bootstrap_root/sb-manager.tar.gz.sha256"
  (cd "$bootstrap_root" && sha256sum -c sb-manager.tar.gz.sha256) || {
    printf 'Error: release checksum verification failed\n' >&2
    exit 1
  }

  tar -xzf "$bootstrap_root/sb-manager.tar.gz" -C "$bootstrap_root"
  bootstrap_installer=$(find "$bootstrap_root" -mindepth 2 -maxdepth 2 -type f -name install.sh | head -n 1)
  [ -n "$bootstrap_installer" ] || {
    printf 'Error: install.sh was not found in the release archive\n' >&2
    exit 1
  }

  if [ "$#" -eq 0 ]; then
    bootstrap_detected_address=$(detect_public_ipv4 || true)
    if [ -t 0 ]; then
      if [ -n "$bootstrap_detected_address" ]; then
        printf '检测到公网 IPv4：%s\n直接回车使用该 IP，或输入其他 IP/域名: ' "$bootstrap_detected_address" >/dev/tty
      else
        printf '未能自动检测公网 IPv4，请输入客户端连接使用的 IP 或域名: ' >/dev/tty
      fi
      IFS= read -r bootstrap_server_address </dev/tty
      bootstrap_server_address=${bootstrap_server_address:-$bootstrap_detected_address}
    else
      bootstrap_server_address=$bootstrap_detected_address
    fi
    [ -n "$bootstrap_server_address" ] || {
      printf 'Error: public IP detection failed; use --server-address explicitly\n' >&2
      exit 1
    }
    set -- --server-address "$bootstrap_server_address"
  fi

  sh "$bootstrap_installer" "$@"
  exit $?
}

bootstrap_if_needed "$@"

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

if [ "$UPGRADE" -eq 0 ] && [ -z "$SERVER_ADDRESS" ]; then
  detected_address=$(detect_public_ipv4 || true)
  if [ -t 0 ]; then
    if [ -n "$detected_address" ]; then
      printf '检测到公网 IPv4：%s\n直接回车使用该 IP，或输入其他 IP/域名: ' "$detected_address" >/dev/tty
    else
      printf '未能自动检测公网 IPv4，请输入客户端连接使用的 IP 或域名: ' >/dev/tty
    fi
    IFS= read -r SERVER_ADDRESS </dev/tty
    SERVER_ADDRESS=${SERVER_ADDRESS:-$detected_address}
  else
    SERVER_ADDRESS=$detected_address
  fi
  [ -n "$SERVER_ADDRESS" ] || die 'public IP detection failed; use --server-address explicitly'
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run passed.\nPlatform: %s\nSource: %s\nUpgrade: %s\nServer address: %s\n' "$PLATFORM" "$SOURCE_DIR" "$UPGRADE" "$SERVER_ADDRESS"
  exit 0
fi

install_sing_box_binary() {
  case "$(uname -m)" in
    x86_64) binary_arch=amd64 ;;
    aarch64) binary_arch=arm64 ;;
    armv7l|armv7) binary_arch=armv7 ;;
    i386|i486|i586|i686) binary_arch=386 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac

  release_json=$(curl -fsSL --retry 3 --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest)
  release_tag=$(printf '%s' "$release_json" | jq -r '.tag_name // empty')
  [ -n "$release_tag" ] || die 'cannot determine the latest sing-box release'
  release_version=${release_tag#v}
  archive_name=sing-box-${release_version}-linux-${binary_arch}-musl.tar.gz
  archive_url=$(printf '%s' "$release_json" | jq -r --arg name "$archive_name" '.assets[] | select(.name == $name) | .browser_download_url')
  expected_checksum=$(printf '%s' "$release_json" | jq -r --arg name "$archive_name" '.assets[] | select(.name == $name) | .digest // empty' | sed 's/^sha256://')
  [ -n "$archive_url" ] || die "official release asset not found: $archive_name"
  [ -n "$expected_checksum" ] || die 'official release asset has no SHA-256 digest'
  binary_root=$(mktemp -d /tmp/sing-box-install.XXXXXX)

  info "Downloading official sing-box ${release_version} for ${binary_arch}"
  curl -fL --retry 3 --connect-timeout 15 "$archive_url" -o "$binary_root/$archive_name"
  printf '%s  %s\n' "$expected_checksum" "$binary_root/$archive_name" | sha256sum -c - || {
    rm -rf "$binary_root"
    die 'sing-box archive checksum verification failed'
  }

  tar -xzf "$binary_root/$archive_name" -C "$binary_root"
  binary_path=$(find "$binary_root" -type f -name sing-box | head -n 1)
  [ -n "$binary_path" ] || {
    rm -rf "$binary_root"
    die 'sing-box binary was not found in the official archive'
  }
  install -m 0755 "$binary_path" /usr/bin/sing-box
  hash -r 2>/dev/null || true
  /usr/bin/sing-box version >/dev/null 2>&1 || {
    rm -rf "$binary_root"
    die 'the downloaded sing-box binary cannot run on this Alpine system'
  }
  rm -rf "$binary_root"
}

install_packages() {
  if [ "$PLATFORM" = alpine ]; then
    apk add --no-cache jq openssl ca-certificates curl tar util-linux libqrencode-tools iptables socat
    if apk add --no-cache sing-box; then
      return
    fi
    info 'The Alpine repository has no sing-box package; using the official verified binary'
    install_sing_box_binary
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl jq openssl tar util-linux iproute2 qrencode iptables procps socat
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
info 'Installing packages'
install_packages
core_output=$(/usr/bin/sing-box version) || die 'sing-box was installed but cannot run on this system'
core_version=$(printf '%s\n' "$core_output" | awk 'NR==1{print $3}')
case "$core_version" in
  [0-9]*.[0-9]*.*) ;;
  *) die "cannot parse sing-box version: $core_version" ;;
esac
core_major=${core_version%%.*}; core_rest=${core_version#*.}; core_minor=${core_rest%%.*}
[ "$core_major" -gt 1 ] || { [ "$core_major" -eq 1 ] && [ "$core_minor" -ge 12 ]; } || die 'sing-box 1.12.0 or newer is required'


info 'Installing sb manager files'
install -d -m 0755 /usr/local/lib/sb-manager /usr/local/bin
install -m 0755 "$SOURCE_DIR/sb" /usr/local/bin/sb
for file in "$SOURCE_DIR"/lib/*.sh; do install -m 0644 "$file" "/usr/local/lib/sb-manager/${file##*/}"; done

install -d -m 0750 /etc/sing-box /etc/sing-box/conf.d /etc/sing-box/certs
install -d -m 0700 /etc/sing-box/nodes /etc/sing-box/backups /etc/sing-box/forwards
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
jq '.manager_version="3.3.5"' /etc/sing-box/manager.json >/etc/sing-box/manager.json.tmp
mv /etc/sing-box/manager.json.tmp /etc/sing-box/manager.json

chmod 0640 /etc/sing-box/config.json
chmod 0600 /etc/sing-box/manager.json

if getent group sing-box >/dev/null 2>&1; then
  # The systemd service runs as sing-box, so it must traverse this directory.
  chown root:sing-box /etc/sing-box
  chown root:sing-box /etc/sing-box/config.json
  chown -R root:sing-box /etc/sing-box/conf.d /etc/sing-box/certs
fi

if [ "$PLATFORM" = alpine ]; then
  cat >/etc/init.d/sb-sing-box <<'EOF'
#!/sbin/openrc-run
name="sb-sing-box"
description="sing-box managed by sb"
supervisor="supervise-daemon"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json -C /etc/sing-box/conf.d"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { after net dns firewall; }
start_pre() { /usr/bin/sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d; }
EOF
  chmod 0755 /etc/init.d/sb-sing-box
  rc-update add sb-sing-box default
else
  cat >/etc/systemd/system/sb-sing-box.service <<'EOF'
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
  systemctl enable sb-sing-box
fi

sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf.d
if [ "$PLATFORM" = alpine ]; then rc-service sb-sing-box restart 9>&- || rc-service sb-sing-box start 9>&-; else systemctl restart sb-sing-box 9>&-; fi

if find /etc/sing-box/forwards -maxdepth 1 -type f -name '*.json' | grep -q .; then
  /usr/local/bin/sb forward install-scheduler
  /usr/local/bin/sb forward sync --quiet
fi

printf '\nInstallation completed. Run: sb\n'
[ -z "$backup" ] || printf 'Legacy backup: %s\n' "$backup"
