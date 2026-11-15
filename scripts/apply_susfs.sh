#!/usr/bin/env bash
# SUSFS 内核侧补丁：按 KSU 变体选补丁代次并应用，附 OKI 树差异的兜底与落盘自检。
#
# 用法: apply_susfs.sh <kernel_workspace> <kmi> <ksu_type> [hide_patch_url]
#   <kernel_workspace>  含 common/ 的那一层
#   <kmi>               如 android14-6.1
#   <ksu_type>          bakasu|sukisu|ksunext|finasu|ksu|none
#   [hide_patch_url]    69_hide_stuff.patch 地址，默认取 CI 仓库 raw（本地跑传 cctv18 的）
#
# 代次差异（这是踩过的坑，别随手改）：
#   FinaSU 内核侧锁 SUSFS 2.4.0（ec03d0c），走 fs/susfs.c 的 susfs_add_sus_type / fake_status；
#   cctv18/susfs4oki 的 oki-* 分支是旧代次，security/selinux/* 里 `extern struct selinux_state
#   fake_state` —— FinaSU 驱动没有这个符号，链接期直接 undefined symbol: fake_state。
set -euo pipefail

KW="${1:?用法: apply_susfs.sh <kernel_workspace> <kmi> <ksu_type> [hide_patch_url]}"
KMI="${2:?需要 kmi，如 android14-6.1}"
KSUTYPE="${3:-none}"
HIDE_URL="${4:-}"

if [ -z "$HIDE_URL" ]; then
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    HIDE_URL="https://github.com/$GITHUB_REPOSITORY/raw/refs/heads/$GITHUB_REF_NAME/other_patch/69_hide_stuff.patch"
  else
    HIDE_URL="https://github.com/cctv18/oppo_oplus_realme_sm8650/raw/refs/heads/main/other_patch/69_hide_stuff.patch"
  fi
fi

cd "$KW"

if [ "$KSUTYPE" = "none" ]; then
  echo "无内置 KernelSU，跳过 SUSFS 补丁"
  exit 0
fi

echo "应用 SUSFS 补丁（kmi=$KMI, ksu=$KSUTYPE）..."
if [ "$KSUTYPE" = "finasu" ]; then
  SUSFS_REPO="ShirkNeko/susfs4ksu"
  SUSFS_BRANCH="gki-$KMI"
else
  SUSFS_REPO="cctv18/susfs4oki"
  SUSFS_BRANCH="oki-$KMI"
fi

rm -rf susfs4ksu
git clone --depth=1 "https://github.com/$SUSFS_REPO.git" susfs4ksu -b "$SUSFS_BRANCH"
SUSFS_COMMIT=$(git -C susfs4ksu rev-parse --short HEAD)

mkdir -p common/fs common/include/linux
wget -q "$HIDE_URL" -O ./common/69_hide_stuff.patch
cp "./susfs4ksu/kernel_patches/50_add_susfs_in_gki-$KMI.patch" ./common/
cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

cd ./common
patch -p1 -F 3 < "50_add_susfs_in_gki-$KMI.patch" || true
patch -p1 -N -F 3 < 69_hide_stuff.patch || true

if [ "$KSUTYPE" = "finasu" ]; then
  # OKI 树的 include 区与 GKI 不同，两个 hunk 靠 -F3 也可能落不下来，逐个补：
  #   fs/proc/base.c 的 susfs_def.h include、fs/namespace.c 的 CL_COPY_MNT_NS 与两个 extern
  grep -q 'susfs_def.h' fs/proc/base.c || \
    sed -i '/^#include <trace\/events\/oom.h>/i #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux\/susfs_def.h>\n#endif' fs/proc/base.c
  if ! grep -q 'CL_COPY_MNT_NS BIT(25)' fs/namespace.c; then
    awk '
      !done && /^\/\* Maximum number of mounts in a mount namespace \*\// {
        print "#ifdef CONFIG_KSU_SUSFS"
        print "#include <linux/susfs_def.h>"
        print "#endif"
        print ""
        print "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        print "extern bool susfs_is_current_ksu_domain(void);"
        print "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;"
        print ""
        print "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */"
        print "#endif"
        print ""
        done = 1
      }
      { print }
    ' fs/namespace.c > fs/namespace.c.tmp && mv fs/namespace.c.tmp fs/namespace.c
  fi
  # namespace.c 那个 hunk 已被上面的 awk 替代，rej 不留
  rm -f fs/namespace.c.rej 2>/dev/null || true

  # 缺一处就是没打全，宁可在这里失败也别拖到链接期
  for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    [ -f "$f" ] || { echo "ERROR: SUSFS 新代次补丁未落盘: $f 缺失" >&2; exit 1; }
  done
  grep -q 'susfs_add_sus_type' fs/susfs.c || { echo "ERROR: fs/susfs.c 缺 susfs_add_sus_type" >&2; exit 1; }
  grep -q 'CL_COPY_MNT_NS BIT(25)' fs/namespace.c || { echo "ERROR: fs/namespace.c 缺 CL_COPY_MNT_NS" >&2; exit 1; }
  grep -q 'susfs_def.h' fs/proc/base.c || { echo "ERROR: fs/proc/base.c 缺 susfs_def.h" >&2; exit 1; }
fi

# 原版 KernelSU 需要额外的 KSU 侧补丁（FinaSU/其它变体树内已自带）
if [ "$KSUTYPE" = "ksu" ]; then
  cd "$KW"
  cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
  ( cd ./KernelSU && patch -p1 -F 3 < 10_enable_susfs_for_ksu.patch || true )
fi

echo "SUSFS 补丁完成（$SUSFS_REPO@$SUSFS_COMMIT）"
