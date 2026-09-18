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
SB_FORWARD_DIR=$SB_HOME/forwards
SB_RUNTIME_DIR=/usr/local/lib/sb-manager
SB_LOCK_FILE=${SB_LOCK_FILE:-/run/lock/sb-manager.lock}

say() {
  printf '%s\n' "$*"
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf '警告: %s\n' "$*" >&2
}

die() {
  printf '错误: %s\n' "$*" >&2
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

strip_ipv6_brackets() {
  value=$1
  case "$value" in [\[*\]]) printf '%s' "${value#\[}" | sed 's/\]$//' ;; *) printf '%s' "$value" ;; esac
}

is_ipv6() {
  value=$(strip_ipv6_brackets "$1")
  case "$value" in *:*) ;; *) return 1 ;; esac
  printf '%s' "$value" | awk -F: '
    BEGIN { valid=1; double=0; total=0 }
    { for (i=1; i<=NF; i++) {
        if ($i == "") { if (i==1 || i==NF || double) continue; double=1; continue }
        if ($i ~ /[^0-9A-Fa-f]/ || length($i)>4) valid=0
        total++
      }
      if (!double && total != 8) valid=0
      if (double && total >= 8) valid=0
      if (valid) exit 0; exit 1
    }'
}

validate_listen_address() {
  value=$(strip_ipv6_brackets "$1")
  [ "$value" = 0.0.0.0 ] || [ "$value" = :: ] || is_ipv4 "$value" || is_ipv6 "$value"
}

format_uri_host() {
  value=$(strip_ipv6_brackets "$1")
  if is_ipv6 "$value"; then printf '[%s]' "$value"; else printf '%s' "$value"; fi
}

detect_public_ipv6() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1     | grep -vE '^(fd|fc|fe80:)' | head -n1
}

validate_host() {
  value=$(strip_ipv6_brackets "$1")
  case "$value" in *:*) is_ipv6 "$value"; return ;; esac
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
  [ -f "$(node_meta_file "$1")" ]
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

port_in_metadata() (
  pim_requested=$1
  pim_except_name=${2:-}
  for pim_meta in "$SB_NODE_DIR"/*.json; do
    [ -f "$pim_meta" ] || continue
    pim_node_name=$(jq -r '.name' "$pim_meta")
    [ "$pim_node_name" = "$pim_except_name" ] && continue
    pim_node_port=$(jq -r '.listen.port' "$pim_meta")
    [ "$pim_node_port" != "$pim_requested" ] || return 0
  done
  return 1
)

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
