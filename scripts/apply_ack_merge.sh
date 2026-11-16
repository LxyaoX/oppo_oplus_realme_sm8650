#!/usr/bin/env bash
# 合并 Google ACK（kernel/common）的变更：上游优化 / bug 修复 / 每月 ASB 安全补丁。
#
# 用法:
#   apply_ack_merge.sh <kernel_workspace> [--target TAG] [--mode asb|full] [--dry-run]
#
#   --mode asb   只合并「上一份 ASB 标签 → 目标标签」这一个月的改动（默认，就是当月安全补丁）
#   --mode full  合并「厂商基线（按 Makefile SUBLEVEL 匹配的 ASB 标签）→ 目标标签」的全部改动
#                跨越几十个 LTS 版本，冲突会很多，慎用
#
# 环境变量:
#   ACK_MIRROR   默认 https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/kernel/common
#                （android.googlesource.com 在部分网络下不可达；国内镜像同样有 ASB 标签）
#   ACK_STRICT=1 有冲突时直接失败（默认只告警，把冲突清单写进报告）
#
# 合并策略（三段）：
#   1) 整份 diff 用 patch -p1 -F3 -N 打，能落的先落
#   2) 打不上的文件，如果厂商树里那份文件与 ACK 基线一致（= 厂商没动过），直接用目标版本覆盖
#   3) 剩下的才是真冲突：留 .rej + 报告，不猜
#
# 为什么不用 git merge：厂商树是 tarball（无 .git），在 1.3G/7 万文件上 git init+add 要三分钟，
# 且 Windows 侧会遇到大小写冲突路径。这里只让 ACK 侧进 git（blobless 克隆，几十 MB）。
set -uo pipefail

KW="${1:?用法: apply_ack_merge.sh <kernel_workspace> [--target TAG] [--mode asb|full]}"
shift || true
TARGET_TAG="ASB-2026-11-02_14-6.1"
MODE="asb"
DRY=0
SRC_ZIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET_TAG="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --src-zip) SRC_ZIP="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
ACK_MIRROR="${ACK_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/kernel/common}"

# 默认排除厂商重改过的热点：
#   include/trace/hooks/*  厂商自己加了一批 android_vh_* hook，ACK 的同类 DECLARE_HOOK 会撞成
#                          「redefinition of trace_android_vh_...」（实测编译失败点就在这里）
#   mm/**                  厂商 mm 补丁与 ACK 的 folio/reclaim 重构撞车；只排 vmscan.c 不够，
#                          头文件签名变了照样编译失败（too few arguments）
#   include/linux/memcontrol.h、include/linux/swap.h
#                          ASB-2026-11-02 这一批把 mem_cgroup_below_min()/below_low() 从 1 参改成
#                          2 参（多一个 target_mem_cgroup），而 mm/** 已排除、mm/vmscan.c 还是 1 参
#                          调用 → 头文件和实现代次错位，编译必然挂。头文件必须跟 mm/ 一起留在厂商版。
#   fs/f2fs/**             OPLUS 的 f2fs 带自己一套 f2fs_lock_context / f2fs_*_write_trace()；
#                          ACK 的 gc.c 补丁假设 f2fs.h 是新版签名，打上去直接
#                          「incomplete type 'struct f2fs_lock_context'」+ 两个 undeclared function
ACK_EXCLUDE="${ACK_EXCLUDE-include/trace/hooks/**,mm/**,include/linux/memcontrol.h,include/linux/swap.h,fs/f2fs/**}"

# 两种布局都认：构建工作区是 <KW>/common（GKI 形态），直接解压的源码包是 <KW> 本身
if [ -f "$KW/common/Makefile" ]; then
  COMMON="$KW/common"
elif [ -f "$KW/Makefile" ] && grep -q '^VERSION = ' "$KW/Makefile"; then
  COMMON="$KW"
else
  echo "ERROR: $KW 下找不到内核 Makefile（既不是 <KW>/common 也不是 <KW> 本身）" >&2
  exit 1
fi
SUB=$(awk '/^SUBLEVEL =/{print $3; exit}' "$COMMON/Makefile")
echo "厂商内核: 6.1.$SUB；目标标签: $TARGET_TAG；模式: $MODE"

WORK="$COMMON/.ack_merge"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"
REPO="$WORK/ack.git"
git init -q --bare "$REPO" || { echo "ERROR: git init 失败" >&2; exit 1; }
git -C "$REPO" remote add origin "$ACK_MIRROR"

fetch_tag() {  # <tag> -> 本地 ref 同名
  # 镜像走公网，本机/runner 上都出现过 TLS/502 抽风；一次失败不等于标签不存在，
  # 退避重试 4 次（5/10/15/20s），全挂才算真失败。
  local tag="$1" i
  for i in 1 2 3 4; do
    if git -C "$REPO" fetch -q --depth 1 --filter=blob:none origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null; then
      return 0
    fi
    echo "拉取 $tag 第 $i 次失败，$((i * 5))s 后重试" >&2
    sleep $((i * 5))
  done
  echo "ERROR: 拉取标签失败: $tag（镜像 $ACK_MIRROR）" >&2
  return 1
}

ls_remote_asb() {  # 列 ASB 标签；空结果多半是网络，不能当成「没有标签」
  local i out
  for i in 1 2 3 4; do
    out=$(git ls-remote --tags "$ACK_MIRROR" "refs/tags/ASB-*_14-6.1" 2>/dev/null) || out=""
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    echo "列举 ASB 标签第 $i 次为空，$((i * 5))s 后重试" >&2
    sleep $((i * 5))
  done
  echo "ERROR: 列不出 ASB 标签（镜像 $ACK_MIRROR 连不上？）" >&2
  return 1
}

# ---- 目标标签
fetch_tag "$TARGET_TAG" || exit 1
TGT_SUB=$(git -C "$REPO" cat-file -p "$TARGET_TAG:Makefile" 2>/dev/null | awk '/^SUBLEVEL =/{print $3; exit}')
echo "目标标签内核版本: 6.1.${TGT_SUB:-?}"

# ---- 选基线标签
if [ "$MODE" = "asb" ]; then
  # 「上一份 ASB」= 标签列表里排在目标前面的那个同 KMI 标签
  ALL_TAGS=$(ls_remote_asb | awk '{print $2}' | sed 's#refs/tags/##' | sort)
  BASE_TAG=$(printf '%s\n' "$ALL_TAGS" | awk -v t="$TARGET_TAG" '$0 < t {last=$0} END{print last}')
  [ -n "$BASE_TAG" ] || { echo "ERROR: 找不到 $TARGET_TAG 的上一份 ASB 标签" >&2; exit 1; }
  echo "基线标签（上一份 ASB）: $BASE_TAG"
else
  # full：按 SUBLEVEL 精确匹配厂商基线；没有就取不大于它的最近标签
  BASE_TAG=""
  EXACT=""
  for tag in $(ls_remote_asb | awk '{print $2}' | sed 's#refs/tags/##' | sort -r | head -n 24); do
    git -C "$REPO" fetch -q --depth 1 --filter=blob:none origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null || continue
    s=$(git -C "$REPO" cat-file -p "$tag:Makefile" 2>/dev/null | awk '/^SUBLEVEL =/{print $3; exit}')
    [ -z "$s" ] && continue
    if [ "$s" = "$SUB" ]; then EXACT="$tag"; break; fi
    if [ "$s" -le "$SUB" ] 2>/dev/null && [ -z "$BASE_TAG" ]; then BASE_TAG="$tag"; fi
  done
  [ -n "$EXACT" ] && BASE_TAG="$EXACT"
  [ -n "$BASE_TAG" ] || { echo "ERROR: 找不到匹配 6.1.$SUB 的 ASB 基线标签" >&2; exit 1; }
  echo "基线标签（按 SUBLEVEL 匹配）: $BASE_TAG"
fi

fetch_tag "$BASE_TAG" || exit 1

# ---- 生成 diff（blob 按需拉取）
DIFF="$WORK/ack.diff"
echo "生成 diff: $BASE_TAG -> $TARGET_TAG"
EXCL_ARGS=""
if [ -n "$ACK_EXCLUDE" ]; then
  OLDIFS=$IFS; IFS=','
  for pat in $ACK_EXCLUDE; do
    [ -n "$pat" ] && EXCL_ARGS="$EXCL_ARGS :(exclude,glob)$pat"
  done
  IFS=$OLDIFS
  echo "跳过路径: $ACK_EXCLUDE"
fi
# shellcheck disable=SC2086
git -C "$REPO" diff --no-renames "$BASE_TAG" "$TARGET_TAG" -- . $EXCL_ARGS > "$DIFF" 2>"$WORK/diff.err" || {
  echo "ERROR: git diff 失败" >&2; cat "$WORK/diff.err" >&2; exit 1; }
FILES=$(grep -c '^diff --git' "$DIFF" || true)
HUNKS=$(grep -c '^@@' "$DIFF" || true)
SIZE=$(wc -c < "$DIFF" | tr -d ' ')
echo "diff: $FILES 个文件, $HUNKS 个 hunk, $SIZE 字节"

if [ "$DRY" = "1" ]; then
  echo "dry-run：不落盘"
  exit 0
fi

# ---- 1) 先整体打
cd "$COMMON"
LOG="$WORK/apply.log"
patch -p1 -F3 -N --no-backup-if-mismatch < "$DIFF" > "$LOG" 2>&1
PATCH_RC=$?
OK_HUNKS=$(grep -c 'succeeded' "$LOG" || true)
FAIL_HUNKS=$(grep -c 'FAILED' "$LOG" || true)
echo "patch: 成功 $OK_HUNKS 个 hunk，失败 $FAIL_HUNKS 个（rc=$PATCH_RC）"

# ---- 2) 冲突文件逐个处理：厂商没动过 → 整份换成目标版本；动过 → git merge-file 三方合并
REPLACED=0
MERGED=0
REMAIN=0
: > "$WORK/report.txt"

# 从源码 zip 里取原始文件（patch 已经把能打的 hunk 落进去了，三方合并必须用原始内容）
# 只列一次 zip 目录：每个冲突文件都跑一次 unzip -Z1 会把 7 万条目重扫一遍
if [ -n "$SRC_ZIP" ] && [ -f "$SRC_ZIP" ]; then
  unzip -Z1 "$SRC_ZIP" > "$WORK/zip_entries.txt" 2>/dev/null
fi
restore_orig() {  # <path> -> 输出原始内容到 stdout
  local path="$1" entry
  # 本地 builder 是 git clone 出来的，直接问 HEAD 要原始文件，比 zip 快
  if git -C "$COMMON" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$COMMON" show "HEAD:$path" 2>/dev/null && return 0
  fi
  [ -s "$WORK/zip_entries.txt" ] || return 1
  entry=$(grep -m1 "/$path\$" "$WORK/zip_entries.txt")
  [ -n "$entry" ] || return 1
  unzip -p "$SRC_ZIP" "$entry" 2>/dev/null
}
# patch 的输出是「patching file X」后面跟若干 Hunk 行，FAILED 只标 hunk 不标文件，
# 所以要顺着读：记住当前文件，遇到 FAILED 就把它记下来
for f in $(awk '/^patching file /{file=$3} /FAILED/{if (file != "") {print file; file=""}}' "$LOG" | sort -u); do
  [ -f "$f" ] || continue
  if git -C "$REPO" cat-file -e "$BASE_TAG:$f" 2>/dev/null; then
    # 2a) 厂商没动过这个文件：直接整份换目标版本，最干净
    if git -C "$REPO" cat-file -p "$BASE_TAG:$f" 2>/dev/null | cmp -s - "$f"; then
      git -C "$REPO" cat-file -p "$TARGET_TAG:$f" > "$f" 2>/dev/null && {
        rm -f "$f.rej" 2>/dev/null
        REPLACED=$((REPLACED + 1))
        echo "replaced(pristine): $f" >> "$WORK/report.txt"
        continue
      }
    fi
    # 2b) 厂商改过：拿「原始厂商版本 / ACK 基线 / ACK 目标」做三方合并，
    #     上下文漂移这类冲突在这里能自动化掉，只有真撞车才留标记
    if restore_orig "$f" > "$WORK/ours.tmp" 2>/dev/null && [ -s "$WORK/ours.tmp" ]; then
      git -C "$REPO" cat-file -p "$BASE_TAG:$f" > "$WORK/base.tmp" 2>/dev/null
      git -C "$REPO" cat-file -p "$TARGET_TAG:$f" > "$WORK/theirs.tmp" 2>/dev/null
      if cp "$WORK/ours.tmp" "$WORK/merged.tmp" &&
         git merge-file -q "$WORK/merged.tmp" "$WORK/base.tmp" "$WORK/theirs.tmp" >/dev/null 2>&1; then
        # merge-file 返回 0 表示无冲突
        cp "$WORK/merged.tmp" "$f"
        rm -f "$f.rej" 2>/dev/null
        MERGED=$((MERGED + 1))
        echo "merged(3way): $f" >> "$WORK/report.txt"
        continue
      fi
    fi
  fi
  REMAIN=$((REMAIN + 1))
  echo "conflict: $f" >> "$WORK/report.txt"
done

echo "冲突文件处理：整file替换 $REPLACED 个；三方合并 $MERGED 个；剩余真冲突 $REMAIN 个"

# ---- 3) mm 代次一致性兜底 ----
# mm/** 被排除后，厂商 mm/ 仍是 1 参 mem_cgroup_below_*()；只要头文件被 ACK 的任一 commit 换掉，
# 编译就过不去。这里把这几份头文件无条件还原成厂商原始版本，保证「头文件 + mm/」同代次。
# 幂等：内容一样就不写，避免无意义的时间戳抖动。
MM_HEADERS="include/linux/memcontrol.h include/linux/swap.h"
RESTORED=0
for h in $MM_HEADERS; do
  [ -f "$h" ] || continue
  if restore_orig "$h" > "$WORK/hdr.tmp" 2>/dev/null && [ -s "$WORK/hdr.tmp" ]; then
    if ! cmp -s "$WORK/hdr.tmp" "$h"; then
      cp "$WORK/hdr.tmp" "$h"
      RESTORED=$((RESTORED + 1))
      echo "restore(vendor-mm-header): $h" >> "$WORK/report.txt"
    fi
  fi
done
echo "mm 头文件还原：$RESTORED 个"

# 落盘自检：厂商树是 1 参形态时，头文件必须也是 1 参，否则 mm/vmscan.c 一定编不过
if [ -f include/linux/memcontrol.h ] && grep -q 'mem_cgroup_below_min(struct mem_cgroup \*target' include/linux/memcontrol.h; then
  echo "::warning title=mm 头文件代次::include/linux/memcontrol.h 是 2 参形态；若厂商 mm/vmscan.c 仍是 1 参调用会报 too few arguments"
fi

# ---- 4) android_vh hook 引用自愈 ----
# ACK 的补丁会往文件里插 trace_android_vh_xxx() 调用，而声明在 include/trace/hooks/**——
# 那一片被整体排除（厂商自己的 hook 集合与 ACK 撞名，会 redefinition）。
# 结果就是 drivers/dma-buf/dma-buf.c:115: call to undeclared function 'trace_android_vh_dma_buf_release'。
# 处理：凡是「被 ACK 改过、又引用了本树没有声明的 hook」的文件，整份还原成厂商版本。
# 代价是少一两个 ASB 修复，收益是构建不会因为一个 hook 端掉整棵树。
HOOKS_DIR=include/trace/hooks
if [ -d "$HOOKS_DIR" ]; then
  # 改动过的文件 = patch 打进去的 + 整份替换/三方合并的
  {
    awk '/^patching file /{print $3}' "$LOG"
    awk -F': ' '/^(merged|replaced|restore)\(/{print $2}' "$WORK/report.txt"
  } | sort -u > "$WORK/modified.txt"
  REVERTED=0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    grep -qo 'trace_android_vh_[a-zA-Z0-9_]*' "$f" || continue
    MISS=""
    for h in $(grep -o 'trace_android_vh_[a-zA-Z0-9_]*' "$f" | sort -u); do
      grep -rq "$h" "$HOOKS_DIR" 2>/dev/null || MISS="$MISS $h"
    done
    [ -n "$MISS" ] || continue
    if restore_orig "$f" > "$WORK/rev.tmp" 2>/dev/null && [ -s "$WORK/rev.tmp" ]; then
      cp "$WORK/rev.tmp" "$f"
      rm -f "$f.rej" 2>/dev/null
      REVERTED=$((REVERTED + 1))
      echo "revert(hook-undeclared): $f ->$MISS" >> "$WORK/report.txt"
      echo "还原(缺 hook 声明): $f$MISS"
    else
      echo "::warning title=ACK hook 冲突::$f 引用了未声明的 hook（$MISS），且拿不到原始版本，可能编译失败"
    fi
  done < "$WORK/modified.txt"
  echo "hook 引用自愈：还原 $REVERTED 个文件"

  # ---- 5) 悬空 tracepoint 导出清理 ----
  # drivers/android/vendor_hooks.c 里每行 EXPORT_TRACEPOINT_SYMBOL_GPL(x) 都会展开成
  # __tracepoint_x / __traceiter_x / __SCK__tp_func_x 三个引用。ACK 会给它加新 hook 的导出，
  # 而 DECLARE_HOOK 在 include/trace/hooks/**（已排除）→ 编译直接
  # 「use of undeclared identifier '__traceiter_android_vh_adjust_nr_reclaimed'」。
  # 处理：删掉那些「本树没有任何 hook 头声明过」的导出行，只保留厂商真实存在的那批。
  EXPORT_STRIPPED=0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    grep -q 'EXPORT_TRACEPOINT_SYMBOL' "$f" || continue
    BEFORE=$(wc -l < "$f")
    for name in $(grep -o 'EXPORT_TRACEPOINT_SYMBOL[A-Z_]*(\([a-zA-Z0-9_]*\))' "$f" \
                  | sed 's/.*(\(.*\))/\1/' | sort -u); do
      grep -rq "$name" "$HOOKS_DIR" 2>/dev/null && continue
      sed -i "/EXPORT_TRACEPOINT_SYMBOL[A-Z_]*(\($name\))/d" "$f"
      echo "strip(export-undeclared): $f -> $name" >> "$WORK/report.txt"
      echo "删除悬空导出: $f -> $name"
    done
    AFTER=$(wc -l < "$f")
    [ "$AFTER" != "$BEFORE" ] && EXPORT_STRIPPED=$((EXPORT_STRIPPED + 1))
  done < "$WORK/modified.txt"
  echo "悬空 tracepoint 导出清理：$EXPORT_STRIPPED 个文件"
fi

# 统计剩余 .rej
REJS=$(find . -name '*.rej' -newer "$WORK/apply.log" 2>/dev/null | wc -l | tr -d ' ')
echo "剩余 .rej: $REJS" | tee -a "$WORK/report.txt"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "ACK_MERGE_TARGET=$TARGET_TAG"
    echo "ACK_MERGE_BASE=$BASE_TAG"
    echo "ACK_MERGE_FILES=$FILES"
    echo "ACK_MERGE_REMAIN=$REMAIN"
  } >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "> **ACK 合并**：$BASE_TAG → $TARGET_TAG，$FILES 个文件 / $HUNKS 个 hunk"
    echo "> 干净落盘 $OK_HUNKS 个 hunk；整份替换 $REPLACED 个；三方合并 $MERGED 个；剩余真冲突 $REMAIN 个"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$REMAIN" -gt 0 ] && [ "${ACK_STRICT:-0}" = "1" ]; then
  echo "::error::ACK 合并仍有 $REMAIN 个文件冲突（ACK_STRICT=1）"
  exit 1
fi
if [ "$REMAIN" -gt 0 ]; then
  echo "::warning title=ACK 合并存在冲突::剩余 $REMAIN 个文件需要人工处理，清单见 $WORK/report.txt"
fi
exit 0
