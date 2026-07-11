#!/bin/sh

set -eu

umask 077

SB_HOME=${SB_HOME:-/etc/sing-box}
SB_BASE_CONFIG=$SB_HOME/config.json
SB_CONF_DIR=$SB_HOME/conf.d
SB_NODE_DIR=$SB_HOME/nodes
SB_CERT_DIR=$SB_HOME/certs
SB_MANAGER_CONFIG=$SB_HOME/manager.json
SB_BACKUP_DIR=$SB_HOME/backups
SB_RUNTIME_DIR=/usr/local/lib/sb-manager
SB_LOCK_FILE=/run/lock/sb-manager.lock

say() {
  printf '%s\n' "$*"
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die 'run this command as root'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

is_ipv4() {
  printf '%s' "$1" | awk -F. '
    NF != 4 { exit 1 }
    { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
  '
}

validate_host() {
  value=$1
  case "$value" in ''|*[!A-Za-z0-9.-]*|.*|*.|*..*) return 1 ;; esac
  if printf '%s' "$value" | grep -Eq '^[0-9.]+$'; then
    is_ipv4 "$value"
  else
    printf '%s' "$value" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
  fi
}

validate_port() {
  is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_name() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

json_get() {
  jq -er "$2" "$1"
}

node_meta_file() {
  printf '%s/%s.json\n' "$SB_NODE_DIR" "$1"
}

node_config_file() {
  printf '%s/%s.json\n' "$SB_CONF_DIR" "$1"
}

node_exists() {
  [ -f "$(node_meta_file "$1")" ] && [ -f "$(node_config_file "$1")" ]
}

list_node_names() {
  find "$SB_NODE_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null \
    | sed 's|.*/||; s/\.json$//' \
    | sort
}

acquire_lock() {
  install -d -m 0755 /run/lock
  exec 9>"$SB_LOCK_FILE"
  flock -n 9 || die 'another sb operation is running'
}

manager_server_address() {
  jq -er '.server_address' "$SB_MANAGER_CONFIG"
}

port_in_metadata() {
  requested=$1
  except_name=${2:-}
  for meta in "$SB_NODE_DIR"/*.json; do
    [ -f "$meta" ] || continue
    name=$(jq -r '.name' "$meta")
    [ "$name" = "$except_name" ] && continue
    port=$(jq -r '.listen_port' "$meta")
    [ "$port" != "$requested" ] || return 0
  done
  return 1
}

validate_complete_config() {
  candidate_dir=$1
  sing-box check -c "$SB_BASE_CONFIG" -C "$candidate_dir"
}

build_candidate_dir() {
  target_name=$1
  replacement=$2
  candidate=$(mktemp -d /tmp/sb-conf.XXXXXX)
  for file in "$SB_CONF_DIR"/*.json; do
    [ -f "$file" ] || continue
    [ "${file##*/}" = "$target_name.json" ] && continue
    cp "$file" "$candidate/"
  done
  [ -z "$replacement" ] || cp "$replacement" "$candidate/$target_name.json"
  printf '%s\n' "$candidate"
}

timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

confirm() {
  prompt=$1
  printf '%s [y/N]: ' "$prompt"
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
