#!/bin/sh

extended_protocol() {
  case "$1" in hysteria2|tuic|trojan|vmess|vless-tls) return 0 ;; *) return 1 ;; esac
}

generate_tls_assets() {
  cert_dir=$1
  public_address=$2
  cert_source=$3
  key_source=$4
  install -d -m 0700 "$cert_dir"
  if [ -n "$cert_source" ] || [ -n "$key_source" ]; then
    [ -n "$cert_source" ] && [ -n "$key_source" ] || die '--cert and --key must be supplied together'
    openssl x509 -in "$cert_source" -pubkey -noout >"$cert_dir/cert.pub"
    openssl pkey -in "$key_source" -pubout >"$cert_dir/key.pub"
    cmp -s "$cert_dir/cert.pub" "$cert_dir/key.pub" || die 'certificate and private key do not match'
    install -m 0644 "$cert_source" "$cert_dir/cert.pem"
    install -m 0640 "$key_source" "$cert_dir/key.pem"
    rm -f "$cert_dir/cert.pub" "$cert_dir/key.pub"
    printf 'trusted\n'
    return
  fi
  if is_ipv4 "$public_address"; then san="IP:$public_address"; else san="DNS:$public_address"; fi
  openssl ecparam -genkey -name prime256v1 -out "$cert_dir/key.pem"
  openssl req -new -x509 -key "$cert_dir/key.pem" -sha256 -days 3650 \
    -out "$cert_dir/cert.pem" -subj "/CN=$public_address" -addext "subjectAltName=$san"
  chmod 0640 "$cert_dir/key.pem"
  chmod 0644 "$cert_dir/cert.pem"
  printf 'self-signed\n'
}

protocol_generate() {
  output=$1; protocol=$2; name=$3; listen_address=$4; listen_port=$5; public_address=$6; public_port=$7
  username=$8; password=$9; shift 9
  ss_method=${1:-2022-blake3-aes-128-gcm}; reality_server=${2:-developer.apple.com}; reality_port=${3:-443}; tls_server_name=${4:-$public_address}
  cert_source=${5:-}; key_source=${6:-}; cert_stage=${7:-}; transport=${8:-tcp}; path=${9:-/proxy}
  host=${10:-$public_address}; shift 10
  tls_mode=${1:-}; acme_email=${2:-}; obfs_password=${3:-}

if [ "$protocol" = anytls ] && [ "$tls_mode" = acme ]; then
    is_ipv4 "$public_address" && die 'AnyTLS ACME requires a DNS name'
    [ -n "$acme_email" ] || die '--acme-email is required for AnyTLS ACME'
    [ "$tls_server_name" = "$public_address" ] || die '--tls-sni must match the AnyTLS ACME domain'
    [ -n "$password" ] || password=$(openssl rand -hex 24)
    created_at=$(timestamp)
    jq -n --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" --argjson listen_port "$listen_port" \
      --arg public_address "$public_address" --argjson public_port "$public_port" --arg username "$username" --arg password "$password" \
      --arg email "$acme_email" --arg tls_server_name "$tls_server_name" --arg created_at "$created_at" \
      '{schema:1,name:$name,protocol:$protocol,enabled:true,listen:{address:$listen_address,port:$listen_port,transports:["tcp"]},public:{address:$public_address,port:$public_port},credentials:{username:$username,password:$password},tls:{mode:"acme",insecure:false,domain:$public_address,email:$email,server_name:$tls_server_name},created_at:$created_at,updated_at:$created_at}' >"$output"
    return
  fi

  if ! extended_protocol "$protocol"; then
    generate_node_metadata "$output" "$protocol" "$name" "$listen_address" "$listen_port" "$public_address" "$public_port" \
      "$username" "$password" "$ss_method" "$reality_server" "$reality_port" "$tls_server_name" "$cert_source" "$key_source" "$cert_stage"
    return
  fi

  created_at=$(timestamp)
  case "$protocol" in
    hysteria2)
      [ -n "$password" ] || password=$(sing-box generate rand --base64 32)
      [ -n "$tls_mode" ] || tls_mode=self-signed
      case "$tls_mode" in self-signed|trusted) tls_mode=$(generate_tls_assets "$cert_stage" "$public_address" "$cert_source" "$key_source") ;; *) die 'Hysteria2 tls-mode must be self-signed or trusted' ;; esac
      [ -n "$obfs_password" ] || obfs_password=$(openssl rand -hex 16)
      jq -n --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" --argjson listen_port "$listen_port" \
        --arg public_address "$public_address" --argjson public_port "$public_port" --arg username "$username" --arg password "$password" \
      --arg tls_mode "$tls_mode" --arg tls_server_name "$tls_server_name" --arg obfs_password "$obfs_password" --arg created_at "$created_at" \
        '{schema:1,name:$name,protocol:$protocol,enabled:true,listen:{address:$listen_address,port:$listen_port,transports:["udp"]},public:{address:$public_address,port:$public_port},credentials:{username:$username,password:$password},tls:{mode:$tls_mode,insecure:($tls_mode=="self-signed"),server_name:$tls_server_name},obfs:{type:"salamander",password:$obfs_password},created_at:$created_at,updated_at:$created_at}' >"$output"
      ;;
    tuic)
      uuid=$(sing-box generate uuid)
      [ -n "$password" ] || password=$(sing-box generate rand --base64 32)
      [ -n "$tls_mode" ] || tls_mode=self-signed
      case "$tls_mode" in self-signed|trusted) tls_mode=$(generate_tls_assets "$cert_stage" "$public_address" "$cert_source" "$key_source") ;; *) die 'TUIC tls-mode must be self-signed or trusted' ;; esac
      jq -n --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" --argjson listen_port "$listen_port" \
        --arg public_address "$public_address" --argjson public_port "$public_port" --arg username "$username" --arg uuid "$uuid" --arg password "$password" \
      --arg tls_mode "$tls_mode" --arg tls_server_name "$tls_server_name" --arg created_at "$created_at" \
        '{schema:1,name:$name,protocol:$protocol,enabled:true,listen:{address:$listen_address,port:$listen_port,transports:["udp"]},public:{address:$public_address,port:$public_port},credentials:{username:$username,uuid:$uuid,password:$password},tls:{mode:$tls_mode,insecure:($tls_mode=="self-signed"),server_name:$tls_server_name},tuic:{congestion_control:"cubic",zero_rtt:false},created_at:$created_at,updated_at:$created_at}' >"$output"
      ;;
    trojan|vless-tls|vmess)
      case "$transport" in tcp|ws|http|h2|httpupgrade|quic) ;; *) die 'unsupported transport' ;; esac
      if [ "$protocol" != vmess ] && [ "$transport" = quic ]; then die 'QUIC transport is supported only for VMess in this manager'; fi
      [ -n "$tls_mode" ] || { if [ "$protocol" = vmess ] && [ "$transport" = tcp ]; then tls_mode=none; else tls_mode=self-signed; fi; }
      if [ "$transport" = quic ] && [ "$tls_mode" = none ]; then die 'QUIC transport requires native TLS'; fi
      if [ "$tls_mode" = caddy ]; then
        case "$transport" in ws|http|h2|httpupgrade) ;; *) die 'Caddy mode requires ws, http, h2, or httpupgrade transport' ;; esac
        is_ipv4 "$public_address" && die 'Caddy automatic TLS requires a DNS name'
        listen_address=127.0.0.1
      elif [ "$tls_mode" != none ]; then
        case "$tls_mode" in self-signed|trusted) tls_mode=$(generate_tls_assets "$cert_stage" "$public_address" "$cert_source" "$key_source") ;; *) die 'tls-mode must be none, self-signed, trusted, or caddy' ;; esac
      elif [ "$protocol" = trojan ] || [ "$protocol" = vless-tls ]; then
        die 'Trojan and VLESS TLS require TLS or Caddy mode'
      fi
      credential_type=password
      [ -n "$password" ] || password=$(sing-box generate rand --base64 32)
      uuid=
      if [ "$protocol" = vmess ] || [ "$protocol" = vless-tls ]; then uuid=$(sing-box generate uuid); credential_type=uuid; fi
      jq -n --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" --argjson listen_port "$listen_port" \
        --arg public_address "$public_address" --argjson public_port "$public_port" --arg username "$username" --arg password "$password" --arg uuid "$uuid" \
        --arg credential_type "$credential_type" --arg transport "$transport" --arg path "$path" --arg host "$host" --arg tls_mode "$tls_mode" --arg created_at "$created_at" \
        '{schema:1,name:$name,protocol:$protocol,enabled:true,listen:{address:$listen_address,port:$listen_port,transports:(if $transport=="quic" then ["udp"] else ["tcp"] end)},public:{address:$public_address,port:$public_port},credentials:{username:$username,password:$password,uuid:$uuid,type:$credential_type},transport:{type:$transport,path:$path,host:$host},tls:{mode:$tls_mode,insecure:($tls_mode=="self-signed")},created_at:$created_at,updated_at:$created_at}' >"$output"
      ;;
  esac
}

transport_json() {
  meta=$1
  transport=$(jq -r '.transport.type' "$meta")
  path=$(jq -r '.transport.path' "$meta")
  host=$(jq -r '.transport.host' "$meta")
  case "$transport" in
    tcp) printf 'null\n' ;;
    ws) jq -n --arg path "$path" --arg host "$host" '{type:"ws",path:$path,headers:{Host:$host}}' ;;
    http|h2) jq -n --arg path "$path" --arg host "$host" '{type:"http",host:[$host],path:$path}' ;;
    httpupgrade) jq -n --arg path "$path" --arg host "$host" '{type:"httpupgrade",host:$host,path:$path}' ;;
    quic) printf '{"type":"quic"}\n' ;;
  esac
}

protocol_render() {
  meta=$1
  output=$2
  protocol=$(jq -r '.protocol' "$meta")
if [ "$protocol" = anytls ] && [ "$(jq -r '.tls.mode // empty' "$meta")" = acme ]; then
    name=$(jq -r '.name' "$meta"); listen=$(jq -r '.listen.address' "$meta"); port=$(jq -r '.listen.port' "$meta")
    username=$(jq -r '.credentials.username' "$meta"); password=$(jq -r '.credentials.password' "$meta")
    domain=$(jq -r '.tls.domain' "$meta"); email=$(jq -r '.tls.email' "$meta")
    version=$(sing-box version | awk 'NR==1{print $3}'); minor=$(printf '%s' "$version" | cut -d. -f2)
    if [ "$minor" -ge 14 ]; then
      tls=$(jq -n --arg domain "$domain" --arg email "$email" '{enabled:true,certificate_provider:{type:"acme",domain:[$domain],email:$email}}')
    else
      tls=$(jq -n --arg domain "$domain" --arg email "$email" '{enabled:true,acme:{domain:[$domain],email:$email}}')
    fi
    jq -n --arg tag "anytls-$name" --arg listen "$listen" --argjson port "$port" --arg username "$username" --arg password "$password" --argjson tls "$tls" \
      '{inbounds:[{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,password:$password}],tls:$tls}]}' >"$output"
    return
  fi
  if ! extended_protocol "$protocol"; then render_node_config "$meta" "$output"; return; fi
  name=$(jq -r '.name' "$meta"); listen=$(jq -r '.listen.address' "$meta"); port=$(jq -r '.listen.port' "$meta"); tag="$protocol-$name"
  tls_mode=$(jq -r '.tls.mode // "none"' "$meta")
  tls=null
  if [ "$tls_mode" = self-signed ] || [ "$tls_mode" = trusted ]; then
    tls=$(jq -n --arg cert "$SB_CERT_DIR/$name/cert.pem" --arg key "$SB_CERT_DIR/$name/key.pem" '{enabled:true,certificate_path:$cert,key_path:$key}')
  fi
  case "$protocol" in
    hysteria2)
      username=$(jq -r '.credentials.username' "$meta"); password=$(jq -r '.credentials.password' "$meta"); obfs=$(jq -r '.obfs.password' "$meta")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg username "$username" --arg password "$password" --arg obfs "$obfs" --argjson tls "$tls" \
        '{inbounds:[{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,password:$password}],obfs:{type:"salamander",password:$obfs},tls:$tls}]}' >"$output"
      ;;
    tuic)
      username=$(jq -r '.credentials.username' "$meta"); uuid=$(jq -r '.credentials.uuid' "$meta"); password=$(jq -r '.credentials.password' "$meta")
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg username "$username" --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" \
        '{inbounds:[{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,uuid:$uuid,password:$password}],congestion_control:"cubic",zero_rtt_handshake:false,tls:$tls}]}' >"$output"
      ;;
    trojan|vless-tls|vmess)
      transport=$(transport_json "$meta")
      if [ "$protocol" = trojan ]; then
        username=$(jq -r '.credentials.username' "$meta"); password=$(jq -r '.credentials.password' "$meta")
        jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg username "$username" --arg password "$password" --argjson tls "$tls" --argjson transport "$transport" \
          '{inbounds:[({type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,password:$password}]} + (if $tls==null then {} else {tls:$tls} end) + (if $transport==null then {} else {transport:$transport} end))]}' >"$output"
      elif [ "$protocol" = vless-tls ]; then
        username=$(jq -r '.credentials.username' "$meta"); uuid=$(jq -r '.credentials.uuid' "$meta")
        jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg username "$username" --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" \
          '{inbounds:[({type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,uuid:$uuid}]} + (if $tls==null then {} else {tls:$tls} end) + (if $transport==null then {} else {transport:$transport} end))]}' >"$output"
      else
        username=$(jq -r '.credentials.username' "$meta"); uuid=$(jq -r '.credentials.uuid' "$meta")
        jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg username "$username" --arg uuid "$uuid" --argjson tls "$tls" --argjson transport "$transport" \
          '{inbounds:[({type:"vmess",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,uuid:$uuid,alterId:0}]} + (if $tls==null then {} else {tls:$tls} end) + (if $transport==null then {} else {transport:$transport} end))]}' >"$output"
      fi
      ;;
  esac
}

protocol_share_uri() {
  meta=$1
  protocol=$(jq -r '.protocol' "$meta")
  if ! extended_protocol "$protocol"; then node_share_uri "$meta"; return; fi
  name=$(jq -r '.name' "$meta"); address=$(jq -r '.public.address' "$meta"); port=$(jq -r '.public.port' "$meta")
  encoded_name=$(uri_encode "$name")
  insecure=$(jq -r 'if .tls.insecure then 1 else 0 end' "$meta")
  tls_server_name=$(jq -r '.tls.server_name // .public.address' "$meta")
  case "$protocol" in
    hysteria2)
      password=$(uri_encode "$(jq -r '.credentials.password' "$meta")")
      obfs=$(uri_encode "$(jq -r '.obfs.password' "$meta")")
      printf 'hysteria2://%s@%s:%s?sni=%s&insecure=%s&obfs=salamander&obfs-password=%s#%s\n' "$password" "$address" "$port" "$(uri_encode "$tls_server_name")" "$insecure" "$obfs" "$encoded_name"
      ;;
    tuic)
      uuid=$(jq -r '.credentials.uuid' "$meta")
      password=$(uri_encode "$(jq -r '.credentials.password' "$meta")")
      printf 'tuic://%s:%s@%s:%s?congestion_control=cubic&udp_relay_mode=native&sni=%s&allow_insecure=%s#%s\n' "$uuid" "$password" "$address" "$port" "$(uri_encode "$tls_server_name")" "$insecure" "$encoded_name"
      ;;
    trojan|vless-tls|vmess)
      transport=$(jq -r '.transport.type' "$meta"); path=$(jq -r '.transport.path' "$meta"); host=$(jq -r '.transport.host' "$meta"); tls_mode=$(jq -r '.tls.mode' "$meta")
      security=none; [ "$tls_mode" = none ] || security=tls
      if [ "$protocol" = trojan ]; then
        credential=$(uri_encode "$(jq -r '.credentials.password' "$meta")")
        printf 'trojan://%s@%s:%s?security=%s&sni=%s&type=%s&host=%s&path=%s#%s\n' "$credential" "$address" "$port" "$security" "$(uri_encode "$host")" "$transport" "$(uri_encode "$host")" "$(uri_encode "$path")" "$encoded_name"
      elif [ "$protocol" = vless-tls ]; then
        credential=$(jq -r '.credentials.uuid' "$meta")
        printf 'vless://%s@%s:%s?encryption=none&security=%s&sni=%s&type=%s&host=%s&path=%s#%s\n' "$credential" "$address" "$port" "$security" "$(uri_encode "$host")" "$transport" "$(uri_encode "$host")" "$(uri_encode "$path")" "$encoded_name"
      else
        uuid=$(jq -r '.credentials.uuid' "$meta")
        vmess_json=$(jq -nc --arg name "$name" --arg address "$address" --arg port "$port" --arg uuid "$uuid" --arg transport "$transport" --arg host "$host" --arg path "$path" --arg tls "$security" '{v:"2",ps:$name,add:$address,port:$port,id:$uuid,aid:"0",scy:"auto",net:$transport,type:"none",host:$host,path:$path,tls:(if $tls=="tls" then "tls" else "" end),sni:$host}')
        printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64 | tr -d '\n')"
      fi
      ;;
  esac
}

protocol_default_port_all() {
  protocol_default_port "$1" 2>/dev/null && return
  case "$1" in
    hysteria2|tuic|trojan|vless-tls) printf '443\n' ;;
    vmess) printf '10000\n' ;;
    *) return 1 ;;
  esac
}
