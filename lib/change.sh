#!/bin/sh

command_change() {
  [ "$#" -ge 1 ] || die 'node name is required'
  ch_name=$1; shift
  ch_source=$(node_meta_file "$ch_name"); [ -f "$ch_source" ] || die "node not found: $ch_name"
  ch_listen_port=; ch_public_address=; ch_public_port=; ch_username=; ch_password=; ch_ss_method=
  ch_reality_server=; ch_reality_port=; ch_tls_sni=; ch_transport=; ch_path=; ch_host=; ch_tls_mode=; ch_cert=; ch_key=; ch_acme_email=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --listen-port|--port) [ "$#" -ge 2 ] || die "$1 requires a value"; ch_listen_port=$2; shift 2 ;;
      --public-address|--server-address) [ "$#" -ge 2 ] || die "$1 requires a value"; ch_public_address=$2; shift 2 ;;
      --public-port) [ "$#" -ge 2 ] || die '--public-port requires a value'; ch_public_port=$2; shift 2 ;;
      --username) [ "$#" -ge 2 ] || die '--username requires a value'; ch_username=$2; shift 2 ;;
      --password) [ "$#" -ge 2 ] || die '--password requires a value'; ch_password=$2; shift 2 ;;
      --ss-method) [ "$#" -ge 2 ] || die '--ss-method requires a value'; ch_ss_method=$2; shift 2 ;;
      --reality-server) [ "$#" -ge 2 ] || die '--reality-server requires a value'; ch_reality_server=$2; shift 2 ;;
      --reality-port) [ "$#" -ge 2 ] || die '--reality-port requires a value'; ch_reality_port=$2; shift 2 ;;
      --tls-sni|--sni) [ "$#" -ge 2 ] || die '--tls-sni requires a value'; ch_tls_sni=$2; shift 2 ;;
      --transport) [ "$#" -ge 2 ] || die '--transport requires a value'; ch_transport=$2; shift 2 ;;
      --path) [ "$#" -ge 2 ] || die '--path requires a value'; ch_path=$2; shift 2 ;;
      --host) [ "$#" -ge 2 ] || die '--host requires a value'; ch_host=$2; shift 2 ;;
      --tls-mode) [ "$#" -ge 2 ] || die '--tls-mode requires a value'; ch_tls_mode=$2; shift 2 ;;
      --cert) [ "$#" -ge 2 ] || die '--cert requires a value'; ch_cert=$2; shift 2 ;;
      --key) [ "$#" -ge 2 ] || die '--key requires a value'; ch_key=$2; shift 2 ;;
      --acme-email) [ "$#" -ge 2 ] || die '--acme-email requires a value'; ch_acme_email=$2; shift 2 ;;
      *) die "unknown change option: $1" ;;
    esac
  done
  [ -n "$ch_listen_port$ch_public_address$ch_public_port$ch_username$ch_password$ch_ss_method$ch_reality_server$ch_reality_port$ch_tls_sni$ch_transport$ch_path$ch_host$ch_tls_mode$ch_cert$ch_key$ch_acme_email" ] || { info 'No changes requested.'; return; }
  ch_work=$(mktemp -d /tmp/sb-change.XXXXXX); cp "$ch_source" "$ch_work/meta.json"
  ch_protocol=$(jq -r '.protocol' "$ch_source")
  ch_old_public_address=$(jq -r '.public.address' "$ch_source")
  if [ -n "$ch_listen_port" ]; then validate_port "$ch_listen_port" || die 'invalid listen port'; port_in_metadata "$ch_listen_port" "$ch_name" && die 'listen port already managed'; jq --argjson v "$ch_listen_port" '.listen.port=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_public_address" ]; then validate_host "$ch_public_address" || die 'invalid public address'; jq --arg v "$ch_public_address" '.public.address=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_public_port" ]; then validate_port "$ch_public_port" || die 'invalid public port'; jq --argjson v "$ch_public_port" '.public.port=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_tls_sni" ]; then
    case "$ch_protocol" in anytls|hysteria2|tuic) ;; *) die '--tls-sni applies only to AnyTLS, Hysteria2, or TUIC' ;; esac
    validate_host "$ch_tls_sni" || die 'invalid TLS SNI'
    jq --arg v "$ch_tls_sni" '.tls.server_name=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"
  elif [ -n "$ch_public_address" ]; then
    case "$ch_protocol" in
      anytls|hysteria2|tuic)
        ch_current_sni=$(jq -r '.tls.server_name // .public.address' "$ch_source")
        if [ "$ch_current_sni" = "$ch_old_public_address" ]; then
          jq --arg v "$ch_public_address" '.tls.server_name=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"
        fi
        ;;
    esac
  fi
  if [ -n "$ch_username" ]; then jq --arg v "$ch_username" '.credentials.username=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_password" ]; then jq --arg v "$ch_password" '.credentials.password=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_ss_method" ]; then
    [ "$ch_protocol" = ss2022 ] || die '--ss-method applies only to SS2022'; ch_bytes=$(ss_key_bytes "$ch_ss_method") || die 'unsupported SS2022 method'; ch_new_key=$(sing-box generate rand --base64 "$ch_bytes")
    jq --arg method "$ch_ss_method" --arg password "$ch_new_key" '.credentials.method=$method | .credentials.password=$password' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"
  fi
  if [ -n "$ch_reality_server" ]; then [ "$ch_protocol" = vless-reality ] || die '--reality-server applies only to VLESS REALITY'; validate_host "$ch_reality_server" || die 'invalid REALITY server'; jq --arg v "$ch_reality_server" '.reality.server=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_reality_port" ]; then validate_port "$ch_reality_port" || die 'invalid REALITY port'; jq --argjson v "$ch_reality_port" '.reality.port=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_transport" ]; then case "$ch_transport" in tcp|ws|http|h2|httpupgrade|quic) ;; *) die 'invalid transport' ;; esac; jq --arg v "$ch_transport" '.transport.type=$v | .listen.transports=(if $v=="quic" then ["udp"] else ["tcp"] end)' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_path" ]; then jq --arg v "$ch_path" '.transport.path=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  if [ -n "$ch_host" ]; then jq --arg v "$ch_host" '.transport.host=$v' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
  ch_cert_stage=
  ch_effective_tls_mode=$(jq -r '.tls.mode // ""' "$ch_work/meta.json")
  if [ "$ch_protocol" = anytls ] && [ "$ch_effective_tls_mode" = acme ]; then
    ch_acme_domain=$(jq -r '.tls.domain // .public.address' "$ch_work/meta.json")
    ch_acme_sni=$(jq -r '.tls.server_name // .public.address' "$ch_work/meta.json")
    [ "$ch_acme_sni" = "$ch_acme_domain" ] || die '--tls-sni must match the AnyTLS ACME domain'
  fi
  if [ -n "$ch_tls_mode" ]; then
    case "$ch_tls_mode" in none|self-signed|trusted|caddy|acme) ;; *) die 'invalid TLS mode' ;; esac
    if [ "$ch_tls_mode" = acme ]; then
      [ "$ch_protocol" = anytls ] || die 'ACME mode currently applies only to AnyTLS'; [ -n "$ch_acme_email" ] || die '--acme-email is required'; ch_domain=$(jq -r '.public.address' "$ch_work/meta.json"); is_ipv4 "$ch_domain" && die 'ACME requires a DNS name'
      ch_acme_sni=$(jq -r '.tls.server_name // .public.address' "$ch_work/meta.json")
      [ "$ch_acme_sni" = "$ch_domain" ] || die '--tls-sni must match the AnyTLS ACME domain'
      jq --arg email "$ch_acme_email" --arg domain "$ch_domain" --arg sni "$ch_acme_sni" '.tls={mode:"acme",insecure:false,email:$email,domain:$domain,server_name:$sni}' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"
    elif [ "$ch_tls_mode" = self-signed ] || [ "$ch_tls_mode" = trusted ]; then
      ch_cert_stage="$ch_work/certs"; ch_address=$(jq -r '.public.address' "$ch_work/meta.json")
      ch_actual_mode=$(generate_tls_assets "$ch_cert_stage" "$ch_address" "$ch_cert" "$ch_key")
      ch_tls_server_name=$(jq -r '.tls.server_name // .public.address' "$ch_work/meta.json")
      jq --arg mode "$ch_actual_mode" --arg sni "$ch_tls_server_name" '.tls={mode:$mode,insecure:($mode=="self-signed"),server_name:$sni}' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"
    else
      ch_tls_server_name=$(jq -r '.tls.server_name // .public.address' "$ch_work/meta.json")
      jq --arg mode "$ch_tls_mode" --arg sni "$ch_tls_server_name" '.tls={mode:$mode,insecure:false,server_name:$sni}' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"
      if [ "$ch_tls_mode" = caddy ]; then jq '.listen.address="127.0.0.1"' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"; fi
    fi
  fi
  ch_old_address=$(jq -r '.public.address' "$ch_source"); ch_new_address=$(jq -r '.public.address' "$ch_work/meta.json"); ch_mode=$(jq -r '.tls.mode // "none"' "$ch_work/meta.json")
  if [ -z "$ch_cert_stage" ] && [ "$ch_old_address" != "$ch_new_address" ] && [ "$ch_mode" = self-signed ]; then ch_cert_stage="$ch_work/certs"; generate_tls_assets "$ch_cert_stage" "$ch_new_address" '' '' >/dev/null; fi
  jq --arg updated "$(timestamp)" '.updated_at=$updated' "$ch_work/meta.json" >"$ch_work/x"; mv "$ch_work/x" "$ch_work/meta.json"
  protocol_render "$ch_work/meta.json" "$ch_work/config.json"
  commit_node_change "$ch_name" "$ch_work/config.json" "$ch_work/meta.json" "$ch_cert_stage" change
  rm -rf "$ch_work"
  info "Node changed: $ch_name"
  command_info "$ch_name"
}
