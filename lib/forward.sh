#!/bin/sh

SB_FORWARD_CHAIN_DNAT=SB_DNAT
SB_FORWARD_CHAIN_SNAT=SB_SNAT
SB_FORWARD_CHAIN_FILTER=SB_FORWARD
SB_FORWARD_SYNC_LOCK=${SB_FORWARD_SYNC_LOCK:-/run/lock/sb-forward-sync.lock}
SB_FORWARD_SYSCTL_FILE=${SB_FORWARD_SYSCTL_FILE:-/etc/sysctl.d/99-sb-forward.conf}
SB_FORWARD_BACKEND=${SB_FORWARD_BACKEND:-auto}
SB_FORWARD_SYSTEMD_DIR=${SB_FORWARD_SYSTEMD_DIR:-/etc/systemd/system}
SB_FORWARD_SOCAT_PREFIX=${SB_FORWARD_SOCAT_PREFIX:-sb-forward-socat-}

forward_config_file() {
  printf '%s/%s.json\n' "$SB_FORWARD_DIR" "$1"
}

forward_list_names() {
  find "$SB_FORWARD_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null \
    | sed 's|.*/||; s/\.json$//' | sort
}

forward_resolve_ipv4() {
  fw_resolve_host=$1
  if is_ipv4 "$fw_resolve_host"; then
    printf '%s\n' "$fw_resolve_host"
    return 0
  fi
  getent ahosts "$fw_resolve_host" 2>/dev/null \
    | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}'
}

forward_protocols_json() {
  case "$1" in
    tcp) printf '["tcp"]\n' ;;
    udp) printf '["udp"]\n' ;;
    both) printf '["tcp","udp"]\n' ;;
    *) return 1 ;;
  esac
}

forward_port_conflicts() {
  fw_conflict_port=$1
  fw_conflict_protocol=$2
  fw_conflict_except=${3:-}
  for fw_conflict_file in "$SB_FORWARD_DIR"/*.json; do
    [ -f "$fw_conflict_file" ] || continue
    [ "$(jq -r '.name' "$fw_conflict_file")" = "$fw_conflict_except" ] && continue
    [ "$(jq -r '.listen_port' "$fw_conflict_file")" = "$fw_conflict_port" ] || continue
    jq -e --arg protocol "$fw_conflict_protocol" '.protocols | index($protocol) != null' "$fw_conflict_file" >/dev/null && return 0
  done
  return 1
}

forward_iptables_usable() {
  command -v iptables >/dev/null 2>&1 || return 1
  command -v iptables-save >/dev/null 2>&1 || return 1
  command -v iptables-restore >/dev/null 2>&1 || return 1
  iptables-save >/dev/null 2>&1
}

forward_socat_usable() {
  [ "$SB_PLATFORM" = systemd ] || return 1
  command -v socat >/dev/null 2>&1 || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl show-environment >/dev/null 2>&1
}

forward_select_backend() {
  case "$SB_FORWARD_BACKEND" in
    iptables)
      forward_iptables_usable || { warn 'iptables 后端不可用'; return 1; }
      printf 'iptables\n'
      ;;
    socat)
      forward_socat_usable || { warn 'socat 后端需要 systemd 正常运行且已安装 socat'; return 1; }
      printf 'socat\n'
      ;;
    auto)
      if forward_iptables_usable; then
        printf 'iptables\n'
        return 0
      fi
      fw_backend_error=$(mktemp /tmp/sb-forward-backend.XXXXXX) || return 1
      iptables-save >/dev/null 2>"$fw_backend_error" || true
      if grep -Eqi 'permission denied|operation not permitted|you must be root|could not fetch rule set generation id' "$fw_backend_error"; then
        rm -f "$fw_backend_error"
        forward_socat_usable || { warn '容器未授予 iptables 权限，且 socat/systemd 用户态中继不可用'; return 1; }
        printf 'socat\n'
        return 0
      fi
      if [ -s "$fw_backend_error" ]; then
        fw_backend_message=$(tr '\n' ' ' <"$fw_backend_error")
        warn "iptables 不可用: $fw_backend_message"
      else
        warn 'iptables 不可用'
      fi
      rm -f "$fw_backend_error"
      return 1
      ;;
    *) warn '端口转发后端必须是 auto、iptables 或 socat'; return 1 ;;
  esac
}

forward_socat_unit_name() {
  fw_socat_unit_id=$(printf '%s' "$1:$2" | sha256sum | awk '{print substr($1, 1, 16)}')
  printf '%s%s.service\n' "$SB_FORWARD_SOCAT_PREFIX" "$fw_socat_unit_id"
}

forward_socat_write_unit() {
  fw_socat_config=$1
  fw_socat_ip=$2
  fw_socat_protocol=$3
  fw_socat_output=$4
  fw_socat_name=$(jq -r '.name' "$fw_socat_config")
  fw_socat_listen=$(jq -r '.listen_port' "$fw_socat_config")
  fw_socat_target=$(jq -r '.target.port' "$fw_socat_config")
  case "$fw_socat_protocol" in
    tcp) fw_socat_listen_address="TCP4-LISTEN:$fw_socat_listen,reuseaddr,fork"; fw_socat_target_address="TCP4:$fw_socat_ip:$fw_socat_target" ;;
    udp) fw_socat_listen_address="UDP4-RECVFROM:$fw_socat_listen,reuseaddr,fork"; fw_socat_target_address="UDP4-SENDTO:$fw_socat_ip:$fw_socat_target" ;;
    *) return 1 ;;
  esac
  cat >"$fw_socat_output" <<EOF
[Unit]
Description=sb socat $fw_socat_protocol relay $fw_socat_name
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat $fw_socat_listen_address $fw_socat_target_address
Restart=on-failure
RestartSec=2
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

forward_socat_backup_units() {
  fw_socat_backup_dir=$1/socat-backup
  install -d -m 0700 "$fw_socat_backup_dir"
  for fw_socat_existing in "$SB_FORWARD_SYSTEMD_DIR"/"$SB_FORWARD_SOCAT_PREFIX"*.service; do
    [ -f "$fw_socat_existing" ] || continue
    cp "$fw_socat_existing" "$fw_socat_backup_dir/${fw_socat_existing##*/}"
  done
}

forward_socat_clear_all() {
  [ "$SB_PLATFORM" = systemd ] || return 0
  for fw_socat_existing in "$SB_FORWARD_SYSTEMD_DIR"/"$SB_FORWARD_SOCAT_PREFIX"*.service; do
    [ -f "$fw_socat_existing" ] || continue
    fw_socat_unit=${fw_socat_existing##*/}
    systemctl disable --now "$fw_socat_unit" 8>&- 9>&- || true
    rm -f "$fw_socat_existing"
  done
  systemctl daemon-reload 8>&- 9>&- || true
}

forward_socat_restore() {
  fw_socat_work=$1
  [ -d "$fw_socat_work/socat-backup" ] || return 0
  forward_socat_clear_all
  for fw_socat_backup in "$fw_socat_work/socat-backup"/*.service; do
    [ -f "$fw_socat_backup" ] || continue
    cp "$fw_socat_backup" "$SB_FORWARD_SYSTEMD_DIR/${fw_socat_backup##*/}"
  done
  systemctl daemon-reload || return 1
  for fw_socat_backup in "$fw_socat_work/socat-backup"/*.service; do
    [ -f "$fw_socat_backup" ] || continue
    fw_socat_unit=${fw_socat_backup##*/}
    systemctl enable "$fw_socat_unit" || return 1
    systemctl restart "$fw_socat_unit" || return 1
  done
}

forward_socat_reconcile_plan() {
  fw_socat_plan=$1
  fw_socat_work=$2
  forward_socat_backup_units "$fw_socat_work" || return 1
  fw_socat_desired=$fw_socat_work/socat-desired
  install -d -m 0700 "$fw_socat_desired" || return 1
  fw_socat_units=$fw_socat_work/socat-units
  : >"$fw_socat_units" || return 1
  while IFS='|' read -r fw_socat_config fw_socat_ip; do
    [ -n "$fw_socat_config" ] || continue
    fw_socat_name=$(jq -r '.name' "$fw_socat_config")
    for fw_socat_protocol in $(jq -r '.protocols[]' "$fw_socat_config"); do
      fw_socat_unit=$(forward_socat_unit_name "$fw_socat_name" "$fw_socat_protocol") || return 1
      forward_socat_write_unit "$fw_socat_config" "$fw_socat_ip" "$fw_socat_protocol" "$fw_socat_desired/$fw_socat_unit" || return 1
      if [ -f "$SB_FORWARD_SYSTEMD_DIR/$fw_socat_unit" ] && cmp -s "$fw_socat_desired/$fw_socat_unit" "$SB_FORWARD_SYSTEMD_DIR/$fw_socat_unit"; then
        printf '%s|unchanged\n' "$fw_socat_unit" >>"$fw_socat_units"
      else
        install -m 0644 "$fw_socat_desired/$fw_socat_unit" "$SB_FORWARD_SYSTEMD_DIR/$fw_socat_unit" || return 1
        printf '%s|changed\n' "$fw_socat_unit" >>"$fw_socat_units"
      fi
    done
  done <"$fw_socat_plan"
  systemctl daemon-reload || { forward_socat_restore "$fw_socat_work" || true; return 1; }
  while IFS='|' read -r fw_socat_unit fw_socat_state; do
    [ -n "$fw_socat_unit" ] || continue
    if ! systemctl enable "$fw_socat_unit"; then forward_socat_restore "$fw_socat_work" || true; return 1; fi
    if [ "$fw_socat_state" = changed ]; then
      systemctl restart "$fw_socat_unit" || { forward_socat_restore "$fw_socat_work" || true; return 1; }
    elif ! systemctl is-active --quiet "$fw_socat_unit"; then
      systemctl start "$fw_socat_unit" || { forward_socat_restore "$fw_socat_work" || true; return 1; }
    fi
    systemctl is-active --quiet "$fw_socat_unit" || { forward_socat_restore "$fw_socat_work" || true; return 1; }
  done <"$fw_socat_units"
  for fw_socat_existing in "$SB_FORWARD_SYSTEMD_DIR"/"$SB_FORWARD_SOCAT_PREFIX"*.service; do
    [ -f "$fw_socat_existing" ] || continue
    fw_socat_unit=${fw_socat_existing##*/}
    grep -Fq "$fw_socat_unit|" "$fw_socat_units" && continue
    systemctl disable --now "$fw_socat_unit" || { forward_socat_restore "$fw_socat_work" || true; return 1; }
    rm -f "$fw_socat_existing"
  done
  systemctl daemon-reload || { forward_socat_restore "$fw_socat_work" || true; return 1; }
}

forward_ensure_chains() {
  iptables -t nat -N "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -N "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -N "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
  iptables -t nat -C PREROUTING -j "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "$SB_FORWARD_CHAIN_DNAT"
  iptables -t nat -C POSTROUTING -j "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j "$SB_FORWARD_CHAIN_SNAT"
  iptables -C FORWARD -j "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || iptables -I FORWARD 1 -j "$SB_FORWARD_CHAIN_FILTER"
}

forward_apply_plan() {
  fw_plan_file=$1
  forward_ensure_chains || return 1
  iptables -t nat -F "$SB_FORWARD_CHAIN_DNAT" || return 1
  iptables -t nat -F "$SB_FORWARD_CHAIN_SNAT" || return 1
  iptables -F "$SB_FORWARD_CHAIN_FILTER" || return 1

  while IFS='|' read -r fw_plan_config fw_plan_ip; do
    [ -n "$fw_plan_config" ] || continue
    fw_plan_listen=$(jq -r '.listen_port' "$fw_plan_config")
    fw_plan_target=$(jq -r '.target.port' "$fw_plan_config")
    for fw_plan_protocol in $(jq -r '.protocols[]' "$fw_plan_config"); do
      iptables -t nat -A "$SB_FORWARD_CHAIN_DNAT" -p "$fw_plan_protocol" --dport "$fw_plan_listen" -j DNAT --to-destination "$fw_plan_ip:$fw_plan_target" || return 1
      iptables -t nat -A "$SB_FORWARD_CHAIN_SNAT" -p "$fw_plan_protocol" -d "$fw_plan_ip" --dport "$fw_plan_target" -j MASQUERADE || return 1
      iptables -A "$SB_FORWARD_CHAIN_FILTER" -p "$fw_plan_protocol" -d "$fw_plan_ip" --dport "$fw_plan_target" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT || return 1
      iptables -A "$SB_FORWARD_CHAIN_FILTER" -p "$fw_plan_protocol" -s "$fw_plan_ip" --sport "$fw_plan_target" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
    done
  done <"$fw_plan_file"
}

forward_enable_kernel() {
  install -d -m 0755 "$(dirname "$SB_FORWARD_SYSCTL_FILE")"
  printf 'net.ipv4.ip_forward=1\n' >"$SB_FORWARD_SYSCTL_FILE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

forward_install_scheduler() {
  [ "${SB_FORWARD_SKIP_SCHEDULER:-0}" != 1 ] || return 0
  if [ "$SB_PLATFORM" = alpine ]; then
    install -d -m 0755 /etc/periodic /etc/init.d
    fw_cron_line='*/5 * * * * /usr/local/bin/sb forward sync --quiet >/dev/null 2>&1'
    touch /etc/crontabs/root
    grep -Fqx "$fw_cron_line" /etc/crontabs/root || printf '%s\n' "$fw_cron_line" >>/etc/crontabs/root
    cat >/etc/init.d/sb-forward <<'EOF'
#!/sbin/openrc-run
description="Restore sb dynamic port forwarding"
depend() { need net; after firewall; }
start() {
  ebegin "Applying sb port forwarding rules"
  /usr/local/bin/sb forward sync --quiet
  eend $?
}
EOF
    chmod 0755 /etc/init.d/sb-forward
    rc-update add sb-forward default 9>&- >/dev/null 2>&1 || true
    rc-update add crond default 9>&- >/dev/null 2>&1 || true
    rc-service crond start 8>&- 9>&- >/dev/null 2>&1 || true
  else
    cat >/etc/systemd/system/sb-forward-sync.service <<'EOF'
[Unit]
Description=Synchronize sb dynamic port forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sb forward sync --quiet
EOF
    cat >/etc/systemd/system/sb-forward-sync.timer <<'EOF'
[Unit]
Description=Refresh sb dynamic port forwarding every five minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 9>&-
    systemctl enable --now sb-forward-sync.timer 8>&- 9>&-
  fi
}

forward_remove_scheduler() {
  if [ "$SB_PLATFORM" = alpine ]; then
    fw_cron_line='*/5 * * * * /usr/local/bin/sb forward sync --quiet >/dev/null 2>&1'
    if [ -f /etc/crontabs/root ]; then
      grep -Fvx "$fw_cron_line" /etc/crontabs/root >/etc/crontabs/root.sb-tmp || true
      mv /etc/crontabs/root.sb-tmp /etc/crontabs/root
    fi
    rc-update del sb-forward default 9>&- >/dev/null 2>&1 || true
    rm -f /etc/init.d/sb-forward
  else
    systemctl disable --now sb-forward-sync.timer 9>&- >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sb-forward-sync.service /etc/systemd/system/sb-forward-sync.timer
    systemctl daemon-reload 9>&-
  fi
}

forward_clear_rules() {
  iptables -t nat -D PREROUTING -j "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -j "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -D FORWARD -j "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
  iptables -t nat -F "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -X "$SB_FORWARD_CHAIN_DNAT" 2>/dev/null || true
  iptables -t nat -F "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -t nat -X "$SB_FORWARD_CHAIN_SNAT" 2>/dev/null || true
  iptables -F "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
  iptables -X "$SB_FORWARD_CHAIN_FILTER" 2>/dev/null || true
}

forward_require_sync_commands() {
  fw_require_backend=$1
  require_command getent
  require_command flock
  case "$fw_require_backend" in
    iptables)
      require_command iptables
      require_command iptables-save
      require_command iptables-restore
      require_command sysctl
      ;;
    socat)
      require_command socat
      require_command sha256sum
      require_command systemctl
      ;;
    *) die '未知的端口转发后端' ;;
  esac
}

forward_acquire_sync_lock() {
  install -d -m 0755 /run/lock
  exec 8>"$SB_FORWARD_SYNC_LOCK"
  flock -n 8 && return 0
  exec 8>&-
  return 1
}

forward_release_sync_lock() {
  flock -u 8 2>/dev/null || true
  exec 8>&-
}

forward_sync_locked() {
  fw_quiet=$1
  fw_backend=$2
  install -d -m 0700 "$SB_FORWARD_DIR" || { warn '无法创建端口转发配置目录'; return 1; }
  fw_work=$(mktemp -d /tmp/sb-forward-sync.XXXXXX) || { warn '无法创建端口转发同步临时目录'; return 1; }
  fw_plan=$fw_work/plan
  : >"$fw_plan" || { rm -rf "$fw_work"; warn '无法创建端口转发同步计划'; return 1; }
  for fw_config in "$SB_FORWARD_DIR"/*.json; do
    [ -f "$fw_config" ] || continue
    [ "$(jq -r 'if has("enabled") then .enabled else true end' "$fw_config")" != false ] || continue
    fw_host=$(jq -r '.target.host' "$fw_config")
    fw_ip=$(forward_resolve_ipv4 "$fw_host" || true)
    if [ -z "$fw_ip" ]; then
      fw_ip=$(jq -r '.resolved_ip // empty' "$fw_config")
      [ -n "$fw_ip" ] || { warn "无法解析目标域名且没有历史 IP: $fw_host"; rm -rf "$fw_work"; return 1; }
      [ "$fw_quiet" -eq 1 ] || warn "DNS 解析失败，继续使用上次 IP: $fw_host -> $fw_ip"
    fi
    printf '%s|%s\n' "$fw_config" "$fw_ip" >>"$fw_plan" || { rm -rf "$fw_work"; warn '无法写入端口转发同步计划'; return 1; }
  done

  if [ "$fw_backend" = socat ]; then
    if ! forward_socat_reconcile_plan "$fw_plan" "$fw_work"; then
      rm -rf "$fw_work"
      warn '应用 socat 用户态中继失败，已恢复原服务状态'
      return 1
    fi
    while IFS='|' read -r fw_config fw_ip; do
      [ -n "$fw_config" ] || continue
      if ! jq --arg ip "$fw_ip" --arg updated "$(timestamp)" '.resolved_ip=$ip | .updated_at=$updated' "$fw_config" >"$fw_config.tmp"; then
        rm -f "$fw_config.tmp"
        forward_socat_restore "$fw_work" || true
        rm -rf "$fw_work"
        warn '无法保存域名解析结果，已恢复原中继服务状态'
        return 1
      fi
      if ! mv "$fw_config.tmp" "$fw_config"; then
        rm -f "$fw_config.tmp"
        forward_socat_restore "$fw_work" || true
        rm -rf "$fw_work"
        warn '无法更新端口转发配置，已恢复原中继服务状态'
        return 1
      fi
    done <"$fw_plan"
    rm -rf "$fw_work"
    [ "$fw_quiet" -eq 1 ] || info '端口转发规则已同步（socat 用户态中继）'
    return 0
  fi

  fw_backup=$fw_work/iptables.save
  iptables-save >"$fw_backup" || { rm -rf "$fw_work"; warn '无法备份当前 iptables 规则'; return 1; }
  forward_enable_kernel || { rm -rf "$fw_work"; warn '无法启用 IPv4 转发'; return 1; }
  if ! forward_apply_plan "$fw_plan"; then
    iptables-restore <"$fw_backup" || true
    rm -rf "$fw_work"
    warn '应用端口转发规则失败，已恢复原防火墙状态'
    return 1
  fi
  forward_socat_clear_all

  while IFS='|' read -r fw_config fw_ip; do
    [ -n "$fw_config" ] || continue
    if ! jq --arg ip "$fw_ip" --arg updated "$(timestamp)" '.resolved_ip=$ip | .updated_at=$updated' "$fw_config" >"$fw_config.tmp"; then
      rm -f "$fw_config.tmp"
      iptables-restore <"$fw_backup" || true
      rm -rf "$fw_work"
      warn '无法保存域名解析结果，已恢复原防火墙状态'
      return 1
    fi
    if ! mv "$fw_config.tmp" "$fw_config"; then
      rm -f "$fw_config.tmp"
      iptables-restore <"$fw_backup" || true
      rm -rf "$fw_work"
      warn '无法更新端口转发配置，已恢复原防火墙状态'
      return 1
    fi
  done <"$fw_plan"
  rm -rf "$fw_work"
  [ "$fw_quiet" -eq 1 ] || info '端口转发规则已同步'
  return 0
}

command_forward_sync() {
  fw_backend=$(forward_select_backend) || die '无法选择可用的端口转发后端'
  forward_require_sync_commands "$fw_backend"
  fw_quiet=0
  [ "${1:-}" != --quiet ] || fw_quiet=1
  if ! forward_acquire_sync_lock; then
    [ "$fw_quiet" -eq 1 ] && return 0
    warn '另一个端口转发同步任务正在运行'
    return 1
  fi
  fw_sync_status=0
  forward_sync_locked "$fw_quiet" "$fw_backend" || fw_sync_status=$?
  forward_release_sync_lock
  return "$fw_sync_status"
}

command_forward_add() {
  fw_name=; fw_listen=; fw_host=; fw_target=; fw_protocol=both
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) [ "$#" -ge 2 ] || die '--name 需要参数'; fw_name=$2; shift 2 ;;
      --listen-port|--port) [ "$#" -ge 2 ] || die '--listen-port 需要参数'; fw_listen=$2; shift 2 ;;
      --target-host) [ "$#" -ge 2 ] || die '--target-host 需要参数'; fw_host=$2; shift 2 ;;
      --target-port) [ "$#" -ge 2 ] || die '--target-port 需要参数'; fw_target=$2; shift 2 ;;
      --protocol) [ "$#" -ge 2 ] || die '--protocol 需要参数'; fw_protocol=$2; shift 2 ;;
      *) die "未知的端口转发参数: $1" ;;
    esac
  done
  [ -n "$fw_listen" ] || die '必须指定本机监听端口'
  [ -n "$fw_host" ] || die '必须指定目标域名或 IP'
  [ -n "$fw_target" ] || fw_target=$fw_listen
  [ -n "$fw_name" ] || fw_name="forward-$fw_listen"
  validate_name "$fw_name" || die '转发规则名称无效'
  validate_port "$fw_listen" || die '本机监听端口无效'
  validate_port "$fw_target" || die '目标端口无效'
  validate_host "$fw_host" || die '目标域名或 IP 无效'
  fw_protocols=$(forward_protocols_json "$fw_protocol") || die '协议必须是 tcp、udp 或 both'
  [ ! -f "$(forward_config_file "$fw_name")" ] || die "转发规则已存在: $fw_name"
  port_in_metadata "$fw_listen" '' && die "该端口已被 sing-box 节点使用: $fw_listen"
  for fw_check_protocol in $(printf '%s' "$fw_protocols" | jq -r '.[]'); do
    forward_port_conflicts "$fw_listen" "$fw_check_protocol" '' && die "该端口和协议已有转发规则: $fw_listen/$fw_check_protocol"
  done

  install -d -m 0700 "$SB_FORWARD_DIR"
  fw_file=$(forward_config_file "$fw_name")
  jq -n --arg name "$fw_name" --argjson listen "$fw_listen" --arg host "$fw_host" --argjson target "$fw_target" --argjson protocols "$fw_protocols" --arg now "$(timestamp)" \
    '{schema:1,name:$name,enabled:true,listen_port:$listen,target:{host:$host,port:$target},protocols:$protocols,resolved_ip:"",created_at:$now,updated_at:$now}' >"$fw_file"
  chmod 0600 "$fw_file"
  if ! command_forward_sync; then rm -f "$fw_file"; return 1; fi
  forward_install_scheduler
  info "端口转发已添加: $fw_name"
}

command_forward_change() {
  [ "$#" -ge 1 ] || die '必须指定转发规则名称'
  fw_change_name=$1
  shift
  fw_change_file=$(forward_config_file "$fw_change_name")
  [ -f "$fw_change_file" ] || die "转发规则不存在: $fw_change_name"

  fw_change_listen=$(jq -r '.listen_port' "$fw_change_file")
  fw_change_host=$(jq -r '.target.host' "$fw_change_file")
  fw_change_target=$(jq -r '.target.port' "$fw_change_file")
  fw_change_protocol=$(jq -r 'if (.protocols | length) == 2 then "both" else .protocols[0] end' "$fw_change_file")
  fw_change_requested=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --listen-port|--port) [ "$#" -ge 2 ] || die '--listen-port 需要参数'; fw_change_listen=$2; fw_change_requested=1; shift 2 ;;
      --target-host) [ "$#" -ge 2 ] || die '--target-host 需要参数'; fw_change_host=$2; fw_change_requested=1; shift 2 ;;
      --target-port) [ "$#" -ge 2 ] || die '--target-port 需要参数'; fw_change_target=$2; fw_change_requested=1; shift 2 ;;
      --protocol) [ "$#" -ge 2 ] || die '--protocol 需要参数'; fw_change_protocol=$2; fw_change_requested=1; shift 2 ;;
      *) die "未知的端口转发参数: $1" ;;
    esac
  done
  [ "$fw_change_requested" -eq 1 ] || die '至少指定一项要修改的转发参数'
  validate_port "$fw_change_listen" || die '本机监听端口无效'
  validate_port "$fw_change_target" || die '目标端口无效'
  validate_host "$fw_change_host" || die '目标域名或 IP 无效'
  fw_change_protocols=$(forward_protocols_json "$fw_change_protocol") || die '协议必须是 tcp、udp 或 both'
  port_in_metadata "$fw_change_listen" '' && die "该端口已被 sing-box 节点使用: $fw_change_listen"
  for fw_change_check_protocol in $(printf '%s' "$fw_change_protocols" | jq -r '.[]'); do
    forward_port_conflicts "$fw_change_listen" "$fw_change_check_protocol" "$fw_change_name" && die "该端口和协议已有转发规则: $fw_change_listen/$fw_change_check_protocol"
  done

  install -d -m 0700 "$SB_FORWARD_DIR"
  fw_change_candidate=$(mktemp "$SB_FORWARD_DIR/.${fw_change_name}.edit.XXXXXX")
  fw_change_backup=$(mktemp /tmp/sb-forward-change.XXXXXX)
  cp "$fw_change_file" "$fw_change_backup"
  jq --argjson listen "$fw_change_listen" --arg host "$fw_change_host" --argjson target "$fw_change_target" --argjson protocols "$fw_change_protocols" --arg updated "$(timestamp)" '
      (if .target.host == $host then . else .resolved_ip = "" end)
      | .listen_port = $listen
      | .target.host = $host
      | .target.port = $target
      | .protocols = $protocols
      | .updated_at = $updated
    ' "$fw_change_file" >"$fw_change_candidate"
  chmod 0600 "$fw_change_candidate"

  fw_change_backend=$(forward_select_backend) || die '无法选择可用的端口转发后端'
  forward_require_sync_commands "$fw_change_backend"
  if ! forward_acquire_sync_lock; then
    rm -f "$fw_change_candidate" "$fw_change_backup"
    die '另一个端口转发同步任务正在运行，请稍后重试'
  fi
  if ! mv "$fw_change_candidate" "$fw_change_file"; then
    rm -f "$fw_change_candidate" "$fw_change_backup"
    forward_release_sync_lock
    warn '无法保存修改后的转发规则'
    return 1
  fi

  if forward_sync_locked 0 "$fw_change_backend"; then
    rm -f "$fw_change_backup"
    forward_release_sync_lock
    info "端口转发已修改: $fw_change_name"
    return 0
  fi

  fw_change_restore=$(mktemp "$SB_FORWARD_DIR/.${fw_change_name}.rollback.XXXXXX")
  cp "$fw_change_backup" "$fw_change_restore"
  chmod 0600 "$fw_change_restore"
  mv "$fw_change_restore" "$fw_change_file"
  if ! forward_sync_locked 1 "$fw_change_backend"; then
    warn '旧配置已恢复，但重新同步旧转发规则失败，请立即运行 sb forward sync'
  fi
  rm -f "$fw_change_backup"
  forward_release_sync_lock
  warn "修改失败，已恢复原转发规则: $fw_change_name"
  return 1
}

command_forward_list() {
  printf '%-4s %-20s %-8s %-24s %-22s %-8s\n' 序号 名称 协议 本机端口 目标地址 状态
  fw_index=1
  for fw_name in $(forward_list_names); do
    fw_file=$(forward_config_file "$fw_name")
    fw_protocol=$(jq -r '.protocols|join("+")' "$fw_file")
    fw_listen=$(jq -r '.listen_port' "$fw_file")
    fw_target=$(jq -r '.target.host+":"+(.target.port|tostring)' "$fw_file")
    fw_enabled=$(jq -r 'if .enabled == false then "禁用" else "启用" end' "$fw_file")
    printf '%-4s %-20s %-8s %-24s %-22s %-8s\n' "$fw_index" "$fw_name" "$fw_protocol" "$fw_listen" "$fw_target" "$fw_enabled"
    fw_index=$((fw_index + 1))
  done
}

command_forward_set_enabled() {
  fw_enabled_value=$1; fw_name=$2; fw_file=$(forward_config_file "$fw_name")
  [ -f "$fw_file" ] || die "转发规则不存在: $fw_name"
  jq --argjson enabled "$fw_enabled_value" --arg updated "$(timestamp)" '.enabled=$enabled | .updated_at=$updated' "$fw_file" >"$fw_file.tmp"
  mv "$fw_file.tmp" "$fw_file"
  command_forward_sync
}

command_forward_delete() {
  [ "$#" -eq 1 ] || die '必须指定转发规则名称'
  fw_name=$1; fw_file=$(forward_config_file "$fw_name")
  [ -f "$fw_file" ] || die "转发规则不存在: $fw_name"
  fw_backup=$(mktemp /tmp/sb-forward-delete.XXXXXX)
  cp "$fw_file" "$fw_backup"
  rm -f "$fw_file"
  if ! command_forward_sync; then cp "$fw_backup" "$fw_file"; rm -f "$fw_backup"; return 1; fi
  rm -f "$fw_backup"
  if [ -z "$(forward_list_names)" ]; then forward_remove_scheduler; fi
  info "端口转发已删除: $fw_name"
}

command_forward_status() {
  fw_status_backend=$(forward_select_backend) || { warn '无法检测端口转发后端'; return 1; }
  say "转发后端: $fw_status_backend"
  if [ "$fw_status_backend" = iptables ]; then
    say 'IPv4 转发状态:'
    sysctl net.ipv4.ip_forward
    say 'DNAT 规则:'
    iptables -t nat -L "$SB_FORWARD_CHAIN_DNAT" -n -v --line-numbers 2>/dev/null || say '尚未创建规则'
    return 0
  fi
  say 'socat 用户态中继服务:'
  for fw_status_name in $(forward_list_names); do
    fw_status_file=$(forward_config_file "$fw_status_name")
    for fw_status_protocol in $(jq -r '.protocols[]' "$fw_status_file"); do
      fw_status_unit=$(forward_socat_unit_name "$fw_status_name" "$fw_status_protocol")
      if systemctl is-active --quiet "$fw_status_unit"; then
        say "$fw_status_name [$fw_status_protocol]: 运行中"
      else
        say "$fw_status_name [$fw_status_protocol]: 未运行"
      fi
    done
  done
}

command_forward() {
  fw_action=${1:-list}; [ "$#" -eq 0 ] || shift
  case "$fw_action" in
    add) command_forward_add "$@" ;;
    change|edit) command_forward_change "$@" ;;
    list|ls) command_forward_list ;;
    sync) command_forward_sync "$@" ;;
    enable) [ "$#" -eq 1 ] || die '必须指定转发规则名称'; command_forward_set_enabled true "$1" ;;
    disable) [ "$#" -eq 1 ] || die '必须指定转发规则名称'; command_forward_set_enabled false "$1" ;;
    delete|del) command_forward_delete "$@" ;;
    status) command_forward_status ;;
    install-scheduler) forward_install_scheduler ;;
    *) die '用法: sb forward add|change|list|sync|enable|disable|delete|status' ;;
  esac
}

forward_uninstall() {
  forward_remove_scheduler
  forward_socat_clear_all
  forward_clear_rules
}
