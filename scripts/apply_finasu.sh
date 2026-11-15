#!/usr/bin/env bash
# FinaSU 集成：clone -> in-tree 挂载 -> 版本号 -> 管理器证书注入第二信任槽 -> 品牌化。
#
# 用法: apply_finasu.sh <kernel_workspace> [cert]
#   <kernel_workspace>  含 common/ 的那一层
#   [cert]              形如 "0x02cc <sha256>"；留空则从 FinaSU 最新 Release APK 现场提取
#
# 为什么必须注入证书：FinaSU 的 Kbuild 默认信任槽（EXPECTED_SIZE/HASH）放的是上游
# KernelSU 官方管理器签名，FinaSU 自家的管理器走第二槽（EXPECTED_SIZE2/HASH2）。
# 不注入时内核只认 KernelSU 官方管理器，FinaSU 管理器显示「未安装」。
set -euo pipefail

KW="${1:?用法: apply_finasu.sh <kernel_workspace> [cert]}"
CERT="${2:-}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cd "$KW"

# 全量 clone：Kbuild 用 rev-list --count HEAD 算版本号，浅仓库会算成 30001
rm -rf KernelSU
git clone "https://github.com/LyraVoid/FinaSU.git" KernelSU

# in-tree 集成：驱动目录软链 + Makefile/Kconfig 挂载（与上游 builtin-integration 一致）
DRIVER_DIR=./common/drivers
ln -sfn "$(realpath --relative-to="$DRIVER_DIR" "$PWD/KernelSU/kernel")" "$DRIVER_DIR/kernelsu"
grep -q "obj-.*CONFIG_KSU.*kernelsu/" "$DRIVER_DIR/Makefile" || \
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$DRIVER_DIR/Makefile"
grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig" || \
  sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"

KSU_VERSION=$(expr $(git -C KernelSU rev-list --count HEAD) + 30000)
echo "FinaSU 版本: $KSU_VERSION（$(git -C KernelSU rev-parse --short HEAD)）"
# set -e 下 `[ -n "$X" ] && echo` 条件为假会让脚本退出，本地跑（没有 GITHUB_ENV）必踩
if [ -n "${GITHUB_ENV:-}" ]; then echo "KSUVER=$KSU_VERSION" >> "$GITHUB_ENV"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "ksuver=$KSU_VERSION" >> "$GITHUB_OUTPUT"; fi

# 取管理器证书
if [ -n "$CERT" ]; then
  KSU_CERT_SIZE=$(echo "$CERT" | awk '{print $1}')
  KSU_CERT_HASH=$(echo "$CERT" | awk '{print $2}')
else
  echo "未指定证书，从 FinaSU 最新 Release APK 提取..."
  CERT_TMP=$(mktemp -d)
  REL_URL=$(curl -s --fail --max-time 60 "https://api.github.com/repos/LyraVoid/FinaSU/releases/latest" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(a['browser_download_url'] for a in d.get('assets',[]) if a['name'].endswith('.apk')))" 2>/dev/null || true)
  if [ -z "$REL_URL" ]; then
    echo "ERROR: 无法获取 FinaSU 最新 Release APK；可用第二个参数手动指定 \"0xXXXX <sha256>\"" >&2
    exit 1
  fi
  curl -sL --fail --retry 3 --max-time 600 -o "$CERT_TMP/manager.apk" "$REL_URL" || {
    echo "ERROR: 下载 FinaSU Release APK 失败" >&2; exit 1; }
  CERT_INFO=$(python3 "$SCRIPT_DIR/finasu_compat/extract_manager_cert.py" "$CERT_TMP/manager.apk" | head -n1)
  KSU_CERT_SIZE=$(printf '%s' "$CERT_INFO" | awk '{print $1}')
  KSU_CERT_HASH=$(printf '%s' "$CERT_INFO" | awk '{print $2}')
  rm -rf "$CERT_TMP" 2>/dev/null || true
fi
if [ -z "$KSU_CERT_SIZE" ] || [ -z "$KSU_CERT_HASH" ]; then
  echo "ERROR: 管理器证书未获取到（格式应为 \"0xXXXX <sha256>\"）" >&2
  exit 1
fi
echo "注入管理器证书到第二信任槽: size=$KSU_CERT_SIZE sha256=$KSU_CERT_HASH"

# 锚点必须是 ccflags-y += -DEXPECTED_HASH= 那行之后：注入块要落在那段
# ifdef KSU_EXPECTED_SIZE2 之前，否则 Kbuild 不会读到这两个值
awk -v size="$KSU_CERT_SIZE" -v hash="$KSU_CERT_HASH" '
  !done && /^ccflags-y \+= -DEXPECTED_HASH=/ {
    print
    print "# injected by apply_finasu.sh: trust the official FinaSU manager via the second signature slot"
    print "KSU_EXPECTED_SIZE2 := " size
    print "KSU_EXPECTED_HASH2 := " hash
    print "KSU_SECOND_SIGNATURE_RELEASE := 1"
    done = 1
    next
  }
  { print }
' KernelSU/kernel/Kbuild > KernelSU/kernel/Kbuild.new && mv KernelSU/kernel/Kbuild.new KernelSU/kernel/Kbuild

grep -q "^KSU_EXPECTED_SIZE2 := " KernelSU/kernel/Kbuild && \
  grep -q "^KSU_EXPECTED_HASH2 := " KernelSU/kernel/Kbuild && \
  grep -q "^KSU_SECOND_SIGNATURE_RELEASE := 1" KernelSU/kernel/Kbuild || {
    echo "ERROR: Kbuild 证书注入失败（锚点 ccflags-y += -DEXPECTED_HASH= 缺失，上游结构可能已变化）" >&2
    exit 1
  }

# 管理器「内核完整版本」的 @<branch> 固定成品牌名（CI 检出是 master/@HEAD 不一致）
bash "$SCRIPT_DIR/ksu_post_setup.sh" KernelSU finasu

echo "FinaSU 集成完成"
