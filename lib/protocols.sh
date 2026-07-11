#!/bin/sh

protocol_default_port() {
  case "$1" in anytls|vless-reality) printf '443\n' ;; ss2022) printf '8388\n' ;; socks5) printf '1080\n' ;; *) return 1 ;; esac
}

protocol_transports() {
  case "$1" in anytls|vless-reality) printf '["tcp"]\n' ;; ss2022|socks5) printf '["tcp","udp"]\n' ;; *) return 1 ;; esac
}

ss_key_bytes() {
  case "$1" in
    2022-blake3-aes-128-gcm) printf '16\n' ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf '32\n' ;;
    *) return 1 ;;
  esac
}

generate_node_metadata() {
  output=$1
  protocol=$2
  name=$3
  listen_address=$4
  listen_port=$5
  public_address=$6
  public_port=$7
  username=$8
  password=$9
  shift 9
  ss_method=${1:-2022-blake3-aes-128-gcm}
  reality_server=${2:-www.microsoft.com}
  reality_port=${3:-443}
  cert_source=${4:-}
  key_source=${5:-}
  cert_stage_dir=${6:-}

  created_at=$(timestamp)
  transports=$(protocol_transports "$protocol")

  case "$protocol" in
    anytls)
      [ -n "$password" ] || password=$(openssl rand -hex 24)
      tls_mode=self-signed
      insecure=true
      install -d -m 0700 "$cert_stage_dir"
      if [ -n "$cert_source" ] || [ -n "$key_source" ]; then
        [ -n "$cert_source" ] && [ -n "$key_source" ] || die '--cert and --key must be supplied together'
        [ -r "$cert_source" ] && [ -r "$key_source" ] || die 'certificate or key is not readable'
        openssl x509 -in "$cert_source" -pubkey -noout >"$cert_stage_dir/cert.pub"
        openssl pkey -in "$key_source" -pubout >"$cert_stage_dir/key.pub"
        cmp -s "$cert_stage_dir/cert.pub" "$cert_stage_dir/key.pub" || die 'certificate and private key do not match'
        install -m 0644 "$cert_source" "$cert_stage_dir/cert.pem"
        install -m 0640 "$key_source" "$cert_stage_dir/key.pem"
        rm -f "$cert_stage_dir/cert.pub" "$cert_stage_dir/key.pub"
        tls_mode=trusted
        insecure=false
      else
        if is_ipv4 "$public_address"; then san="IP:$public_address"; else san="DNS:$public_address"; fi
        openssl ecparam -genkey -name prime256v1 -out "$cert_stage_dir/key.pem"
        openssl req -new -x509 -key "$cert_stage_dir/key.pem" -sha256 -days 3650 \
          -out "$cert_stage_dir/cert.pem" -subj "/CN=$public_address" -addext "subjectAltName=$san"
        chmod 0640 "$cert_stage_dir/key.pem"
        chmod 0644 "$cert_stage_dir/cert.pem"
      fi
      jq -n \
        --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" --arg public_address "$public_address" \
        --argjson public_port "$public_port" --arg username "$username" --arg password "$password" \
        --arg tls_mode "$tls_mode" --argjson insecure "$insecure" --arg created_at "$created_at" \
        --argjson transports "$transports" \
        '{schema:1,name:$name,protocol:$protocol,listen:{address:$listen_address,port:$listen_port,transports:$transports},public:{address:$public_address,port:$public_port},credentials:{username:$username,password:$password},tls:{mode:$tls_mode,insecure:$insecure},created_at:$created_at,updated_at:$created_at}' >"$output"
      ;;
    ss2022)
      bytes=$(ss_key_bytes "$ss_method") || die 'unsupported SS2022 method'
      if [ -z "$password" ]; then password=$(sing-box generate rand --base64 "$bytes"); fi
      decoded=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
      [ "$decoded" -eq "$bytes" ] || die "SS2022 method requires a $bytes-byte Base64 key"
      jq -n \
        --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" --arg public_address "$public_address" \
        --argjson public_port "$public_port" --arg method "$ss_method" --arg password "$password" \
        --arg created_at "$created_at" --argjson transports "$transports" \
        '{schema:1,name:$name,protocol:$protocol,listen:{address:$listen_address,port:$listen_port,transports:$transports},public:{address:$public_address,port:$public_port},credentials:{method:$method,password:$password},created_at:$created_at,updated_at:$created_at}' >"$output"
      ;;
    vless-reality)
      uuid=$(sing-box generate uuid)
      keypair=$(sing-box generate reality-keypair)
      private_key=$(printf '%s\n' "$keypair" | awk -F': ' '/PrivateKey/ {print $2; exit}')
      public_key=$(printf '%s\n' "$keypair" | awk -F': ' '/PublicKey/ {print $2; exit}')
      [ -n "$private_key" ] && [ -n "$public_key" ] || die 'failed to generate REALITY key pair'
      short_id=$(openssl rand -hex 8)
      jq -n \
        --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" --arg public_address "$public_address" \
        --argjson public_port "$public_port" --arg username "$username" --arg uuid "$uuid" \
        --arg reality_server "$reality_server" --argjson reality_port "$reality_port" \
        --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" \
        --arg created_at "$created_at" --argjson transports "$transports" \
        '{schema:1,name:$name,protocol:$protocol,listen:{address:$listen_address,port:$listen_port,transports:$transports},public:{address:$public_address,port:$public_port},credentials:{username:$username,uuid:$uuid},reality:{server:$reality_server,port:$reality_port,private_key:$private_key,public_key:$public_key,short_id:$short_id},created_at:$created_at,updated_at:$created_at}' >"$output"
      ;;
    socks5)
      [ -n "$password" ] || password=$(openssl rand -hex 24)
      jq -n \
        --arg name "$name" --arg protocol "$protocol" --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" --arg public_address "$public_address" \
        --argjson public_port "$public_port" --arg username "$username" --arg password "$password" \
        --arg created_at "$created_at" --argjson transports "$transports" \
        '{schema:1,name:$name,protocol:$protocol,listen:{address:$listen_address,port:$listen_port,transports:$transports},public:{address:$public_address,port:$public_port},credentials:{username:$username,password:$password},created_at:$created_at,updated_at:$created_at}' >"$output"
      ;;
    *) die 'unsupported protocol' ;;
  esac
}

render_node_config() {
  meta=$1
  output=$2
  protocol=$(jq -r '.protocol' "$meta")
  name=$(jq -r '.name' "$meta")
  listen_address=$(jq -r '.listen.address' "$meta")
  listen_port=$(jq -r '.listen.port' "$meta")
  tag="$protocol-$name"

  case "$protocol" in
    anytls)
      username=$(jq -r '.credentials.username' "$meta")
      password=$(jq -r '.credentials.password' "$meta")
      jq -n --arg tag "$tag" --arg listen "$listen_address" --argjson port "$listen_port" \
        --arg username "$username" --arg password "$password" \
        --arg cert "$SB_CERT_DIR/$name/cert.pem" --arg key "$SB_CERT_DIR/$name/key.pem" \
        '{inbounds:[{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}]}' >"$output"
      ;;
    ss2022)
      method=$(jq -r '.credentials.method' "$meta")
      password=$(jq -r '.credentials.password' "$meta")
      jq -n --arg tag "$tag" --arg listen "$listen_address" --argjson port "$listen_port" \
        --arg method "$method" --arg password "$password" \
        '{inbounds:[{type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,method:$method,password:$password}]}' >"$output"
      ;;
    vless-reality)
      username=$(jq -r '.credentials.username' "$meta")
      uuid=$(jq -r '.credentials.uuid' "$meta")
      server=$(jq -r '.reality.server' "$meta")
      server_port=$(jq -r '.reality.port' "$meta")
      private_key=$(jq -r '.reality.private_key' "$meta")
      short_id=$(jq -r '.reality.short_id' "$meta")
      jq -n --arg tag "$tag" --arg listen "$listen_address" --argjson port "$listen_port" \
        --arg username "$username" --arg uuid "$uuid" --arg server "$server" --argjson server_port "$server_port" \
        --arg private_key "$private_key" --arg short_id "$short_id" \
        '{inbounds:[{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$username,uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$server,reality:{enabled:true,handshake:{server:$server,server_port:$server_port},private_key:$private_key,short_id:[$short_id]}}}]}' >"$output"
      ;;
    socks5)
      username=$(jq -r '.credentials.username' "$meta")
      password=$(jq -r '.credentials.password' "$meta")
      jq -n --arg tag "$tag" --arg listen "$listen_address" --argjson port "$listen_port" \
        --arg username "$username" --arg password "$password" \
        '{inbounds:[{type:"socks",tag:$tag,listen:$listen,listen_port:$port,users:[{username:$username,password:$password}]}]}' >"$output"
      ;;
  esac
}

node_share_uri() {
  meta=$1
  protocol=$(jq -r '.protocol' "$meta")
  name=$(jq -r '.name' "$meta")
  address=$(jq -r '.public.address' "$meta")
  port=$(jq -r '.public.port' "$meta")
  case "$protocol" in
    anytls)
      password=$(jq -r '.credentials.password' "$meta")
      insecure=$(jq -r 'if .tls.insecure then 1 else 0 end' "$meta")
      if is_ipv4 "$address"; then query="insecure=$insecure"; else query="sni=$address&insecure=$insecure"; fi
      printf 'anytls://%s@%s:%s/?%s#%s\n' "$password" "$address" "$port" "$query" "$name"
      ;;
    ss2022)
      method=$(jq -r '.credentials.method' "$meta")
      password=$(jq -r '.credentials.password' "$meta" | sed 's/%/%25/g;s/+/%2B/g;s|/|%2F|g;s/=/%3D/g')
      printf 'ss://%s:%s@%s:%s#%s\n' "$method" "$password" "$address" "$port" "$name"
      ;;
    vless-reality)
      uuid=$(jq -r '.credentials.uuid' "$meta")
      server=$(jq -r '.reality.server' "$meta")
      public_key=$(jq -r '.reality.public_key' "$meta")
      short_id=$(jq -r '.reality.short_id' "$meta")
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' "$uuid" "$address" "$port" "$server" "$public_key" "$short_id" "$name"
      ;;
    socks5)
      username=$(jq -r '.credentials.username' "$meta")
      password=$(jq -r '.credentials.password' "$meta")
      printf 'socks5://%s:%s@%s:%s#%s\n' "$username" "$password" "$address" "$port" "$name"
      ;;
  esac
}
