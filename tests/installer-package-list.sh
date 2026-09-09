#!/bin/sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-installer-packages.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

extract_function() {
  sed -n "/^$1() {/,/^}/p" "$REPO_DIR/install.sh"
}

{
  extract_function append_package_once
  extract_function debian_packages_for_missing
  extract_function alpine_packages_for_missing
} >"$TEST_ROOT/functions.sh"

# shellcheck disable=SC1090
. "$TEST_ROOT/functions.sh"

debian_packages=$(debian_packages_for_missing 'jq qrencode iptables iptables-save iptables-restore socat')
set -- $debian_packages
[ "$#" -eq 4 ]
[ "$1" = jq ]
[ "$2" = qrencode ]
[ "$3" = iptables ]
[ "$4" = socat ]

alpine_packages=$(alpine_packages_for_missing 'jq qrencode iptables iptables-save iptables-restore socat')
set -- $alpine_packages
[ "$#" -eq 4 ]
[ "$1" = jq ]
[ "$2" = libqrencode-tools ]
[ "$3" = iptables ]
[ "$4" = socat ]

printf '%s\n' 'Installer package-list regression test passed.'
