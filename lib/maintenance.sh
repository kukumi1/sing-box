#!/bin/sh

command_backup() {
  mb_archive=${1:-/root/sb-backup-$(timestamp)-$$.tar.gz}
  case "$mb_archive" in /*) ;; *) mb_archive="$(pwd)/$mb_archive" ;; esac
  mb_work=$(mktemp -d /tmp/sb-backup.XXXXXX)
  mb_root=$mb_work/sb-backup
  install -d -m 0700 "$mb_root/release"
  cp "$SB_BASE_CONFIG" "$mb_root/release/config.json"
  cp "$SB_MANAGER_CONFIG" "$mb_root/manager.json"
  cp -R "$SB_CONF_DIR" "$SB_NODE_DIR" "$SB_CERT_DIR" "$SB_FORWARD_DIR" "$mb_root/release/"
  jq -n --arg created_at "$(timestamp)" --arg manager_version "$VERSION" \
    --arg core_version "$(sing-box version | awk 'NR==1{print $3}')" \
    --argjson service_active "$(service_active && printf true || printf false)" \
    --argjson service_enabled "$(service_enabled && printf true || printf false)" \
    '{schema:1,created_at:$created_at,manager_version:$manager_version,core_version:$core_version,service:{active:$service_active,enabled:$service_enabled}}' >"$mb_root/backup.json"
  (cd "$mb_root" && find . -type f ! -name SHA256SUMS -print | sort | while read -r file; do sha256sum "$file"; done >SHA256SUMS)
  tar -C "$mb_work" -czf "$mb_archive" sb-backup
  chmod 0600 "$mb_archive"
  sha256sum "$mb_archive" >"$mb_archive.sha256"
  chmod 0600 "$mb_archive.sha256"
  rm -rf "$mb_work"
  info "备份已创建: $mb_archive"
}

command_restore() {
  [ "$#" -eq 1 ] || die 'backup archive is required'
  mr_archive=$1
  [ -r "$mr_archive" ] || die 'backup archive is not readable'
  [ -r "$mr_archive.sha256" ] || die 'backup checksum sidecar is missing'
  (cd "$(dirname "$mr_archive")" && sha256sum -c "$(basename "$mr_archive").sha256")
  tar -tzf "$mr_archive" | grep -Eq '(^/|(^|/)\.\.(/|$))' && die 'unsafe archive path'
  tar -tvzf "$mr_archive" | awk '$1 ~ /^[lhbcp]/ {bad=1} END{exit bad?0:1}' && die 'archive contains links or special files'
  mr_work=$(mktemp -d /tmp/sb-restore.XXXXXX)
  tar -C "$mr_work" -xzf "$mr_archive"
  mr_root=$mr_work/sb-backup
  [ -f "$mr_root/backup.json" ] && [ -f "$mr_root/SHA256SUMS" ] || die 'invalid backup layout'
  (cd "$mr_root" && sha256sum -c SHA256SUMS)
  sing-box check -c "$mr_root/release/config.json" -C "$mr_root/release/conf.d"
  mr_snapshot="before-restore-$(timestamp)-$$"
  command_snapshot "$mr_snapshot"
  rm -rf "$SB_CONF_DIR" "$SB_NODE_DIR" "$SB_CERT_DIR" "$SB_FORWARD_DIR"
  cp "$mr_root/release/config.json" "$SB_BASE_CONFIG"
  cp "$mr_root/manager.json" "$SB_MANAGER_CONFIG"
  cp -R "$mr_root/release/conf.d" "$SB_CONF_DIR"
  cp -R "$mr_root/release/nodes" "$SB_NODE_DIR"
  cp -R "$mr_root/release/certs" "$SB_CERT_DIR"
  if [ -d "$mr_root/release/forwards" ]; then cp -R "$mr_root/release/forwards" "$SB_FORWARD_DIR"; else install -d -m 0700 "$SB_FORWARD_DIR"; fi
  if ! restart_and_verify || ! command_forward_sync --quiet; then
    command_rollback_release "$mr_snapshot" || true
    rm -rf "$mr_work"
    die 'restored configuration failed to start; previous release restored'
  fi
  if [ -n "$(forward_list_names)" ]; then forward_install_scheduler; else forward_remove_scheduler; fi
  rm -rf "$mr_work"
  info '备份恢复完成。'
}

command_update() {
  mu_kind=${1:-manager}
  case "$mu_kind" in
    manager)
      mu_work=$(mktemp -d /tmp/sb-manager-update.XXXXXX)
      mu_api=https://api.github.com/repos/kukumi1/sing-box/releases/latest
      curl -fsSL "$mu_api" -o "$mu_work/release.json"
      mu_archive_url=$(jq -r '.assets[] | select(.name=="sb-manager.tar.gz") | .browser_download_url' "$mu_work/release.json")
      mu_checksum_url=$(jq -r '.assets[] | select(.name=="sb-manager.tar.gz.sha256") | .browser_download_url' "$mu_work/release.json")
      [ -n "$mu_archive_url" ] && [ "$mu_archive_url" != null ] || die 'latest release has no manager archive'
      curl -fsSL "$mu_archive_url" -o "$mu_work/sb-manager.tar.gz"
      curl -fsSL "$mu_checksum_url" -o "$mu_work/sb-manager.tar.gz.sha256"
      (cd "$mu_work" && sha256sum -c sb-manager.tar.gz.sha256)
      tar -C "$mu_work" -xzf "$mu_work/sb-manager.tar.gz"
      mu_source=$(find "$mu_work" -mindepth 1 -maxdepth 1 -type d | head -n 1)
      for mu_file in "$mu_source"/install.sh "$mu_source"/sb "$mu_source"/lib/*.sh; do sh -n "$mu_file"; done
      mu_backup=/usr/local/lib/sb-manager-backups/$(timestamp)-$$
      install -d -m 0700 "$mu_backup"
      cp -R "$SB_RUNTIME_DIR" "$mu_backup/runtime"
      cp /usr/local/bin/sb "$mu_backup/sb"
      if ! sh "$mu_source/install.sh" --upgrade; then
        rm -rf "$SB_RUNTIME_DIR"; cp -R "$mu_backup/runtime" "$SB_RUNTIME_DIR"; cp "$mu_backup/sb" /usr/local/bin/sb
        die 'manager update failed and was rolled back'
      fi
      rm -rf "$mu_work"
      info '管理器更新完成。'
      ;;
    core)
      command_core update
      ;;
    *) die 'usage: sb update manager|core' ;;
  esac
}

command_manager_rollback() {
  mr_latest=$(find /usr/local/lib/sb-manager-backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)
  [ -n "$mr_latest" ] || die 'no manager backup is available'
  rm -rf "$SB_RUNTIME_DIR"
  cp -R "$mr_latest/runtime" "$SB_RUNTIME_DIR"
  cp "$mr_latest/sb" /usr/local/bin/sb
  info "管理器已从备份回滚: $mr_latest"
}

command_core() {
  mc_action=${1:-status}
  mc_dir=/opt/sb-sing-box-backups
  case "$mc_action" in
    status) sing-box version ;;
    update)
      install -d -m 0700 "$mc_dir"
      mc_version=$(sing-box version | awk 'NR==1{print $3}')
      cp "$(command -v sing-box)" "$mc_dir/sing-box-$mc_version-$(timestamp)"
      if [ "$SB_PLATFORM" = alpine ]; then apk upgrade sing-box; else apt-get update; apt-get install -y --only-upgrade sing-box; fi
      if ! command_check || ! restart_and_verify; then
        mc_old=$(find "$mc_dir" -type f | sort | tail -n 1)
        cp "$mc_old" "$(command -v sing-box)"
        restart_and_verify || true
        die 'core update failed; previous binary restored'
      fi
      sing-box version
      ;;
    rollback)
      mc_old=$(find "$mc_dir" -type f 2>/dev/null | sort | tail -n 1)
      [ -n "$mc_old" ] || die 'no core backup is available'
      cp "$mc_old" "$(command -v sing-box)"
      command_check
      restart_and_verify
      sing-box version
      ;;
    *) die 'usage: sb core status|update|rollback' ;;
  esac
}
