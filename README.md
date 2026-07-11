# sb: sing-box Multi-Node Manager

Clean-room multi-node manager for sing-box on Alpine Linux, Debian, and Ubuntu. It provides a persistent `sb` command, an interactive menu, independent node files, NAT-aware client metadata, transactional configuration validation, service management, backups, restore, update, and uninstall.

This project is inspired by the user experience of `233boy/sing-box`, but contains an independent implementation and does not copy its GPL source code.

## Supported protocols

- AnyTLS
- Shadowsocks 2022
- VLESS + REALITY with Vision flow
- Authenticated SOCKS5

Multiple nodes can run at the same time as long as their local listen ports are unique.

## Install

```sh
git clone https://github.com/Promiscuity1/sing-box-multi-protocol-installer.git
cd sing-box-multi-protocol-installer
sudo sh install.sh --server-address YOUR_PUBLIC_IP_OR_DOMAIN
```

Supported systems:

- Alpine Linux 3.23+ with OpenRC
- Debian and Ubuntu with systemd
- amd64 and arm64 packages supported by the official distribution/SagerNet repositories

The installer refuses to replace an existing unmanaged sing-box configuration unless `--force` is supplied. A legacy backup is created before replacement.

## Interactive menu

```sh
sudo sb
```

The menu provides node creation, listing, information, address/port changes, deletion, service status/restart, backup, and update.

## NAT machine example

Assume the hosting panel maps:

```text
Public 23.134.212.11:64491
  -> container 10.10.1.134:30009
```

Create the node with separate local and public ports:

```sh
sudo sb add anytls \
  --name tw-anytls \
  --listen-port 30009 \
  --public-address 23.134.212.11 \
  --public-port 64491
```

The server listens on `30009`; the generated client URI uses `64491`.

Protocol mappings:

- AnyTLS: TCP
- VLESS + REALITY: TCP
- Shadowsocks 2022: TCP and UDP
- SOCKS5: TCP and UDP when the client needs UDP associate

The manager does not modify hosting-provider NAT mappings, cloud security groups, UFW, nftables, or iptables.

## Node commands

```sh
sb add PROTOCOL [options]
sb list
sb info NAME
sb url NAME
sb qr NAME
sb change NAME [options]
sb delete NAME [--yes]
```

Common add options:

```text
--name NAME
--listen-address 0.0.0.0
--listen-port PORT
--public-address HOST
--public-port PORT
--username NAME
--password PASSWORD
```

Protocol-specific options:

```text
--ss-method 2022-blake3-aes-128-gcm
--reality-server www.microsoft.com
--reality-port 443
--cert /path/to/fullchain.pem
--key /path/to/private.key
```

Examples:

```sh
sb add ss2022 --name ss-main --listen-port 8388 --public-port 50001

sb add vless-reality \
  --name reality-main \
  --listen-port 30010 \
  --public-port 64492 \
  --reality-server www.microsoft.com

sb add socks5 --name socks-private --listen-port 1080
```

`sb change` currently changes the listen port, public address, and public port while preserving credentials.

## Service commands

```sh
sb start
sb stop
sb restart
sb status
sb check
sb log [LINES]
```

The service loads:

```text
/etc/sing-box/config.json
/etc/sing-box/conf.d/*.json
```

Each node is an independent JSON file. All node operations stage the complete configuration set and run `sing-box check` before changing live files.

## Backup and restore

```sh
sb backup
sb backup /root/my-sb-backup.tar.gz
sb restore /root/my-sb-backup.tar.gz
```

Backups contain credentials and private keys, use mode `0600`, and include a SHA-256 sidecar file.

## Update and uninstall

```sh
sb update
sb uninstall
sb uninstall --purge --remove-core --yes
```

Default uninstall preserves `/etc/sing-box`. `--purge` removes configurations, certificates, credentials, and backups. `--remove-core` also removes the sing-box package.

## Files

```text
/usr/local/bin/sb
/usr/local/lib/sb-manager/
/etc/sing-box/config.json
/etc/sing-box/manager.json
/etc/sing-box/conf.d/<node>.json
/etc/sing-box/nodes/<node>.json
/etc/sing-box/certs/<node>/
/etc/sing-box/backups/
```

Node metadata includes secrets and is root-only. Server JSON and private keys are readable by the sing-box service group where available.

## Security notes

- SOCKS5 authentication does not encrypt traffic. Avoid exposing SOCKS directly on untrusted networks.
- Self-signed AnyTLS nodes require `insecure=1`; trusted domain certificates are preferred.
- VLESS URI output is a compatibility format; the metadata and sing-box configuration are authoritative.
- Review scripts before running them as root.

## Development tests

GitHub Actions runs shell syntax and dry-run tests on Alpine 3.23 and Debian Bookworm. Integration tests also render all four protocols into one multi-node configuration and validate it with sing-box.
