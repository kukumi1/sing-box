#!/bin/sh

protocol_client_json() {
  po_meta=$1
  po_protocol=$(jq -r '.protocol' "$po_meta")
  po_address=$(jq -r '.public.address' "$po_meta")
  po_port=$(jq -r '.public.port' "$po_meta")
  case "$po_protocol" in
    anytls)
      po_password=$(jq -r '.credentials.password' "$po_meta"); po_insecure=$(jq -r '.tls.insecure' "$po_meta"); po_sni=$(jq -r '.tls.server_name // .public.address' "$po_meta")
      jq -n --arg server "$po_address" --argjson port "$po_port" --arg password "$po_password" --arg sni "$po_sni" --argjson insecure "$po_insecure" \
        '{type:"anytls",tag:"proxy",server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,insecure:$insecure}}'
      ;;
    ss2022)
      po_method=$(jq -r '.credentials.method' "$po_meta"); po_password=$(jq -r '.credentials.password' "$po_meta")
      jq -n --arg server "$po_address" --argjson port "$po_port" --arg method "$po_method" --arg password "$po_password" \
        '{type:"shadowsocks",tag:"proxy",server:$server,server_port:$port,method:$method,password:$password}'
      ;;
    socks5)
      po_user=$(jq -r '.credentials.username' "$po_meta"); po_password=$(jq -r '.credentials.password' "$po_meta")
      jq -n --arg server "$po_address" --argjson port "$po_port" --arg username "$po_user" --arg password "$po_password" \
        '{type:"socks",tag:"proxy",server:$server,server_port:$port,username:$username,password:$password}'
      ;;
    vless-reality)
      po_uuid=$(jq -r '.credentials.uuid' "$po_meta"); po_sni=$(jq -r '.reality.server' "$po_meta"); po_public=$(jq -r '.reality.public_key' "$po_meta"); po_short=$(jq -r '.reality.short_id' "$po_meta")
      jq -n --arg server "$po_address" --argjson port "$po_port" --arg uuid "$po_uuid" --arg sni "$po_sni" --arg public "$po_public" --arg short "$po_short" \
        '{type:"vless",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,reality:{enabled:true,public_key:$public,short_id:$short}}}'
      ;;
    hysteria2)
      po_password=$(jq -r '.credentials.password' "$po_meta"); po_obfs=$(jq -r '.obfs.password' "$po_meta"); po_insecure=$(jq -r '.tls.insecure' "$po_meta"); po_sni=$(jq -r '.tls.server_name // .public.address' "$po_meta")
      jq -n --arg server "$po_address" --argjson port "$po_port" --arg password "$po_password" --arg obfs "$po_obfs" --arg sni "$po_sni" --argjson insecure "$po_insecure" \
        '{type:"hysteria2",tag:"proxy",server:$server,server_port:$port,password:$password,obfs:{type:"salamander",password:$obfs},tls:{enabled:true,server_name:$sni,insecure:$insecure}}'
      ;;
    tuic)
      po_uuid=$(jq -r '.credentials.uuid' "$po_meta"); po_password=$(jq -r '.credentials.password' "$po_meta"); po_insecure=$(jq -r '.tls.insecure' "$po_meta"); po_sni=$(jq -r '.tls.server_name // .public.address' "$po_meta")
      jq -n --arg server "$po_address" --argjson port "$po_port" --arg uuid "$po_uuid" --arg password "$po_password" --arg sni "$po_sni" --argjson insecure "$po_insecure" \
        '{type:"tuic",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,password:$password,congestion_control:"cubic",udp_relay_mode:"native",zero_rtt_handshake:false,tls:{enabled:true,server_name:$sni,insecure:$insecure}}'
      ;;
    trojan|vless-tls|vmess)
      po_transport=$(transport_json "$po_meta"); po_tls_mode=$(jq -r '.tls.mode' "$po_meta"); po_tls=null
      if [ "$po_tls_mode" != none ]; then po_insecure=$(jq -r '.tls.insecure' "$po_meta"); po_sni=$(jq -r '.transport.host' "$po_meta"); po_tls=$(jq -n --arg sni "$po_sni" --argjson insecure "$po_insecure" '{enabled:true,server_name:$sni,insecure:$insecure}'); fi
      if [ "$po_protocol" = trojan ]; then
        po_password=$(jq -r '.credentials.password' "$po_meta")
        jq -n --arg server "$po_address" --argjson port "$po_port" --arg password "$po_password" --argjson tls "$po_tls" --argjson transport "$po_transport" \
          '{type:"trojan",tag:"proxy",server:$server,server_port:$port,password:$password} + (if $tls==null then {} else {tls:$tls} end) + (if $transport==null then {} else {transport:$transport} end)'
      elif [ "$po_protocol" = vless-tls ]; then
        po_uuid=$(jq -r '.credentials.uuid' "$po_meta")
        jq -n --arg server "$po_address" --argjson port "$po_port" --arg uuid "$po_uuid" --argjson tls "$po_tls" --argjson transport "$po_transport" \
          '{type:"vless",tag:"proxy",server:$server,server_port:$port,uuid:$uuid} + (if $tls==null then {} else {tls:$tls} end) + (if $transport==null then {} else {transport:$transport} end)'
      else
        po_uuid=$(jq -r '.credentials.uuid' "$po_meta")
        jq -n --arg server "$po_address" --argjson port "$po_port" --arg uuid "$po_uuid" --argjson tls "$po_tls" --argjson transport "$po_transport" \
          '{type:"vmess",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,security:"auto",alter_id:0} + (if $tls==null then {} else {tls:$tls} end) + (if $transport==null then {} else {transport:$transport} end)'
      fi
      ;;
    *) die 'client JSON is not implemented for this protocol' ;;
  esac
}

command_client() {
  [ "$#" -eq 1 ] || die 'node name is required'
  [ -f "$(node_meta_file "$1")" ] || die "node not found: $1"
  protocol_client_json "$(node_meta_file "$1")"
}

command_export() {
  po_format=uri; po_output=; po_all=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) po_all=1; shift ;;
      --format) [ "$#" -ge 2 ] || die '--format requires uri or json'; po_format=$2; shift 2 ;;
      --output) [ "$#" -ge 2 ] || die '--output requires a path'; po_output=$2; shift 2 ;;
      *) break ;;
    esac
  done
  case "$po_format" in uri|json) ;; *) die '--format must be uri or json' ;; esac
  if [ "$po_all" -eq 1 ] || [ "$#" -eq 0 ]; then po_names=$(list_node_names); else po_names="$*"; fi
  po_tmp=$(mktemp /tmp/sb-export.XXXXXX)
  if [ "$po_format" = json ]; then printf '{"schema":1,"nodes":[' >"$po_tmp"; po_first=1; fi
  for po_name in $po_names; do
    po_meta=$(node_meta_file "$po_name"); [ -f "$po_meta" ] || die "node not found: $po_name"
    if [ "$po_format" = uri ]; then protocol_share_uri "$po_meta" >>"$po_tmp"
    else
      [ "$po_first" -eq 1 ] || printf ',' >>"$po_tmp"; po_first=0
      protocol_client_json "$po_meta" >>"$po_tmp"
    fi
  done
  [ "$po_format" != json ] || printf ']}\n' >>"$po_tmp"
  if [ -n "$po_output" ]; then install -m 0600 "$po_tmp" "$po_output"; info "导出文件已保存: $po_output"; else cat "$po_tmp"; fi
  rm -f "$po_tmp"
}
