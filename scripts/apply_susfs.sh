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

# 下载一律走 curl 优先：runner 上两者都有，但本地 Git Bash 常常没有 wget
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 "$1" -o "$2"
  else
    wget -q --tries=3 --timeout=120 "$1" -O "$2"
  fi
}

if [ "$KSUTYPE" = "none" ]; then
  echo "无内置 KernelSU，跳过 SUSFS 补丁"
  exit 0
fi

echo "应用 SUSFS 补丁（kmi=$KMI, ksu=$KSUTYPE）..."

# 补丁源：
#   finasu  -> gitlab.com/simonpunk/susfs4ksu（上游本体；GitHub 上的 simonpunk/ShirkNeko 镜像已删除）
#   其它    -> cctv18/susfs4oki 的 oki-* 分支（旧代次，与 BakaSU/SukiSU/KernelSU-Next 自带的一致）
# 两个源都允许用环境变量改，方便换镜像或临时钉版本。
SUSFS_GITLAB_BASE="${SUSFS_GITLAB_BASE:-https://gitlab.com/simonpunk/susfs4ksu}"
SUSFS_GITHUB_BASE="${SUSFS_GITHUB_BASE:-https://github.com/cctv18/susfs4oki}"
SUSFS_PIN="${SUSFS_PIN:-}"

if [ "$KSUTYPE" = "finasu" ]; then
  SUSFS_SRC="${SUSFS_GITLAB_BASE%/}"
  SUSFS_BRANCH="gki-$KMI"
else
  SUSFS_SRC="${SUSFS_GITHUB_BASE%/}"
  SUSFS_BRANCH="oki-$KMI"
fi

rm -rf susfs4ksu
CLONED=0
for attempt in 1 2 3; do
  if git clone --depth=1 --branch "$SUSFS_BRANCH" "$SUSFS_SRC.git" susfs4ksu >/dev/null 2>&1; then
    CLONED=1
    break
  fi
  echo "SUSFS 源码克隆失败（第 $attempt 次）: $SUSFS_SRC@$SUSFS_BRANCH" >&2
  rm -rf susfs4ksu
done

if [ "$CLONED" != 1 ]; then
  # CI 里 443 被挡或对方临时抽风时退回归档包：git 走不通不代表 HTTP 也不通
  case "$SUSFS_SRC" in
    *gitlab.com*) TARBALL="$SUSFS_SRC/-/archive/$SUSFS_BRANCH/susfs4ksu-$SUSFS_BRANCH.tar.gz" ;;
    *)            TARBALL="$SUSFS_SRC/archive/refs/heads/$SUSFS_BRANCH.tar.gz" ;;
  esac
  echo "改用归档包: $TARBALL" >&2
  mkdir -p susfs4ksu
  if ! fetch "$TARBALL" /tmp/susfs_src.tar.gz; then
    echo "ERROR: 无法获取 SUSFS 源码（git 与归档包都失败）: $SUSFS_SRC@$SUSFS_BRANCH" >&2
    exit 1
  fi
  tar --force-local -xzf /tmp/susfs_src.tar.gz -C susfs4ksu --strip-components=1
  SUSFS_COMMIT="archive:${SUSFS_BRANCH}"
fi

if [ -n "$SUSFS_PIN" ] && [ "$CLONED" = 1 ]; then
  # 需要钉到指定提交时（排查「上游刚改、我们还没跟」这类问题）用 SUSFS_PIN=<sha>
  if git -C susfs4ksu fetch --depth=1 origin "$SUSFS_PIN" >/dev/null 2>&1; then
    git -C susfs4ksu -c advice.detachedHead=false checkout -q FETCH_HEAD
  else
    echo "WARNING: SUSFS_PIN=$SUSFS_PIN 取不到，继续用分支 HEAD" >&2
  fi
fi

if [ "$CLONED" = 1 ]; then
  SUSFS_COMMIT=$(git -C susfs4ksu rev-parse --short HEAD 2>/dev/null || echo unknown)
fi
echo "SUSFS 源码: $SUSFS_SRC@$SUSFS_BRANCH ($SUSFS_COMMIT)"
[ -f "./susfs4ksu/kernel_patches/50_add_susfs_in_gki-$KMI.patch" ] || {
  echo "ERROR: 该分支下没有 50_add_susfs_in_gki-$KMI.patch，检查分支名或上游结构调整" >&2; exit 1; }

mkdir -p common/fs common/include/linux
# 本地跑时允许直接给磁盘路径（Windows 的 D:/... 会被 curl 当成协议头，必须先分流）
case "$HIDE_URL" in
  http://*|https://*) # 本地跑时允许直接给磁盘路径（Windows 的 D:/... 会被 curl 当成协议头，必须先分流）
case "$HIDE_URL" in
  http://*|https://*) fetch "$HIDE_URL" ./common/69_hide_stuff.patch ;;
  *) cp "$HIDE_URL" ./common/69_hide_stuff.patch ;;
esac ;;
  *) cp "$HIDE_URL" ./common/69_hide_stuff.patch ;;
esac
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

echo "SUSFS 补丁完成（$SUSFS_SRC@$SUSFS_BRANCH $SUSFS_COMMIT）"
