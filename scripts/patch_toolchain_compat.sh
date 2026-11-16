#!/usr/bin/env bash
# 新 clang 的兼容补丁：内核 tools/ 下的 host 程序用的是老代码 + 写死的 -Werror，
# 换到更新版本的 clang 后会在这些小地方直接编译失败。
#
# 用法: patch_toolchain_compat.sh <kernel_workspace>
#
# 目前覆盖：
#   tools/lib/bpf/libbpf.c  next_path = strchr(s, ':')
#     s 是 const char*，strchr 返回 char*，clang 报
#     -Wincompatible-pointer-types-discards-qualifiers。
#     tools/lib/bpf/Makefile 里 `override CFLAGS += -Werror -Wall` 是硬加的，
#     EXTRA_CFLAGS 里塞 -Wno-... 也压不住（它在 -Werror 之前赋值），只能改代码。
#
# 每处都先 grep 再改，找不到就跳过并打印，不把「没打上」当成错误。
set -euo pipefail

KW="${1:?用法: patch_toolchain_compat.sh <kernel_workspace>}"
cd "$KW"

fixed=0

# --- libbpf.c ---
f=./common/tools/lib/bpf/libbpf.c
if [ -f "$f" ]; then
  if grep -q "next_path = strchr(s, ':');" "$f"; then
    sed -i "s|next_path = strchr(s, ':');|next_path = (char *)strchr(s, ':');|" "$f"
    fixed=$((fixed + 1))
    echo "[+] libbpf.c: next_path 赋值补 (char *) 强转"
  elif grep -q "next_path = (char \*)strchr(s, ':');" "$f"; then
    echo "[*] libbpf.c: 已修过，跳过"
  else
    echo "[!] libbpf.c: 没找到 next_path = strchr(...)，上游可能已改，跳过"
  fi
else
  echo "[!] 缺少 $f，跳过 libbpf 兼容补丁"
fi

# 落盘校验：改过就必须能看到强转，否则说明 sed 没生效
if [ "$fixed" -gt 0 ]; then
  grep -q "next_path = (char \*)strchr" "$f" || { echo "ERROR: libbpf.c 补丁未落盘" >&2; exit 1; }
fi

echo "工具链兼容补丁完成（改动 $fixed 处）"
