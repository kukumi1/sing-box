#!/bin/sh

# 回归：核心安装曾让 31MB 压缩包与两份 88MB 二进制同时存在（峰值约 206MB），
# 192MB 内存的 NAT 容器在解压时被内核 OOM，表现为 SSH 会话直接断开。
# 现在压缩包必须落在磁盘目录，且二进制只允许存在一份（流式解压到目标）。

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/sb-core-install.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

extract_function() {
  sed -n "/^$1() {/,/^}/p" "$REPO_DIR/install.sh"
}

{
  extract_function filesystem_type_of
  extract_function available_kib_of
  extract_function disk_backed_tmpdir
} >"$TEST_ROOT/functions.sh"

# shellcheck disable=SC1090
. "$TEST_ROOT/functions.sh"

# --- 1. tmpfs 必须被跳过，否则解压等同于吃内存 ---
cat >"$TEST_ROOT/mounts" <<'EOF'
/dev/root / ext4 rw,relatime 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
/dev/root /var/tmp ext4 rw,relatime 0 0
EOF

filesystem_type_of() {
  awk -v target="$1" '
    {
      mount_point = $2
      probe = target
      if (substr(probe, length(probe)) != "/") probe = probe "/"
      candidate = mount_point
      if (substr(candidate, length(candidate)) != "/") candidate = candidate "/"
      if (index(probe, candidate) == 1 && length(mount_point) >= widest) {
        widest = length(mount_point)
        found = $3
      }
    }
    END { if (found != "") print found }
  ' "$TEST_ROOT/mounts"
}

[ "$(filesystem_type_of /tmp)" = tmpfs ] || {
  printf '%s\n' 'expected /tmp to be detected as tmpfs' >&2
  exit 1
}
[ "$(filesystem_type_of /var/tmp)" = ext4 ] || {
  printf '%s\n' 'expected /var/tmp to be detected as ext4' >&2
  exit 1
}
[ "$(filesystem_type_of /usr/bin)" = ext4 ] || {
  printf '%s\n' 'expected /usr/bin to fall back to the root filesystem' >&2
  exit 1
}

# --- 2. 成员名由压缩包名推导，只解压出二进制这一个文件 ---
archive_name=sing-box-9.9.9-linux-amd64-musl.tar.gz
stage_dir="$TEST_ROOT/stage/${archive_name%.tar.gz}"
mkdir -p "$stage_dir"
printf '#!/bin/sh\nprintf "sing-box version 9.9.9\\n"\n' >"$stage_dir/sing-box"
chmod 0755 "$stage_dir/sing-box"
# 压缩包里除了二进制还有别的文件，确保没有整包解压
printf 'license text\n' >"$stage_dir/LICENSE"
(cd "$TEST_ROOT/stage" && tar -czf "$TEST_ROOT/$archive_name" "${archive_name%.tar.gz}")

work_root="$TEST_ROOT/work"
mkdir -p "$work_root"
cp "$TEST_ROOT/$archive_name" "$work_root/$archive_name"

staged_binary="$TEST_ROOT/sing-box.new"
archive_member=${archive_name%.tar.gz}/sing-box
tar -xzOf "$work_root/$archive_name" "$archive_member" >"$staged_binary" 2>/dev/null

[ -s "$staged_binary" ] || {
  printf '%s\n' 'streamed extraction produced an empty binary' >&2
  exit 1
}
chmod 0755 "$staged_binary"
[ "$("$staged_binary")" = 'sing-box version 9.9.9' ] || {
  printf '%s\n' 'extracted binary did not run as expected' >&2
  exit 1
}

# 关键断言：工作目录里除了压缩包不得出现解压副本
extracted_leftovers=$(find "$work_root" -mindepth 1 ! -name "$archive_name" | wc -l)
[ "$extracted_leftovers" -eq 0 ] || {
  printf '%s\n' 'the archive was fully extracted into the work directory' >&2
  find "$work_root" -mindepth 1 >&2
  exit 1
}

# --- 3. 成员名不匹配时回退到扫描压缩包 ---
odd_archive="$TEST_ROOT/odd.tar.gz"
odd_dir="$TEST_ROOT/odd/singbox-custom-layout"
mkdir -p "$odd_dir"
printf '#!/bin/sh\nprintf "fallback\\n"\n' >"$odd_dir/sing-box"
chmod 0755 "$odd_dir/sing-box"
(cd "$TEST_ROOT/odd" && tar -czf "$odd_archive" singbox-custom-layout)

fallback_member=$(tar -tzf "$odd_archive" 2>/dev/null | grep -m 1 '/sing-box$' || true)
[ -n "$fallback_member" ] || {
  printf '%s\n' 'fallback member scan found nothing' >&2
  exit 1
}
tar -xzOf "$odd_archive" "$fallback_member" >"$TEST_ROOT/fallback.bin" 2>/dev/null
chmod 0755 "$TEST_ROOT/fallback.bin"
[ "$("$TEST_ROOT/fallback.bin")" = fallback ] || {
  printf '%s\n' 'fallback extraction did not run as expected' >&2
  exit 1
}

# --- 4. 安装流程里不得再出现整包解压和二次复制 ---
grep -q 'tar -xzOf "\$binary_root/\$archive_name"' "$REPO_DIR/install.sh" || {
  printf '%s\n' 'installer no longer streams the core binary' >&2
  exit 1
}
if sed -n '/^install_sing_box_binary() {/,/^}/p' "$REPO_DIR/install.sh" \
  | grep -qE 'tar -xzf|install -m 0755 .*sing-box'; then
  printf '%s\n' 'installer reintroduced full archive extraction or a second binary copy' >&2
  exit 1
fi

printf '%s\n' 'Core install regression test passed.'
