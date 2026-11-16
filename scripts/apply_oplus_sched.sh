#!/usr/bin/env bash
# 打开 OPLUS 的调度栈（风驰/SCX 在 6.1 上的内核侧底座）。
#
# 用法: apply_oplus_sched.sh <kernel_workspace>
#   <kernel_workspace>  含 common/ 的那一层（defconfig 在 common/arch/arm64/configs/ 下）
#
# 为什么需要这一步：
#   GKI 的 gki_defconfig 只带了 CONFIG_OPLUS_SCHED_TUNE=y，OPLUS 那套调度功能全是
#   tristate 且 default n（kernel/oplus_cpu/sched/Kconfig），所以 make gki_defconfig 出来的
#   .config 里 SCHED_ASSIST / FRAME_BOOST / EAS_OPT / QOS_SCHED 全是 is not set。
#   结果：Image 里没有 oplus_task_struct 这套钩子，ROM 自带的 vendor 模块
#   oplus_bsp_sched_ext.ko（DDK 模块，提供 /proc/hmbird_sched/*）挂不上去，
#   用户看到的「SCX 风驰调速器」就消失了。
#
# 这里只做「补配置」，不改代码：
#   - 符号必须在树的 Kconfig 里真实存在才写，避免 unknown symbol 噪声
#   - 幂等：先删同名行再写，重复跑不会堆叠
#   - SCHED_CLASS_EXT 一并钉住（sched_ext 调度类本体，风驰依赖它）
set -euo pipefail

KW="${1:?用法: apply_oplus_sched.sh <kernel_workspace>}"
KCONFIG="$KW/common/kernel/oplus_cpu/sched/Kconfig"
DC="$(ls "$KW"/common/arch/arm64/configs/gki_defconfig 2>/dev/null | head -n1)"

if [ -z "$DC" ] || [ ! -f "$DC" ]; then
  echo "ERROR: 找不到 gki_defconfig（$KW/common/arch/arm64/configs/）" >&2
  exit 1
fi
if [ ! -f "$KCONFIG" ]; then
  echo "该内核树没有 kernel/oplus_cpu/sched/Kconfig（非 OPLUS 树），跳过调度栈配置"
  exit 0
fi

# 依赖顺序：SCHED_ASSIST 在前，其余依赖它的在后
WANT="
CONFIG_SCHED_CLASS_EXT
CONFIG_OPLUS_FEATURE_SCHED_ASSIST
CONFIG_OPLUS_FEATURE_TASK_SCHED
CONFIG_OPLUS_FEATURE_TASK_LOAD
CONFIG_OPLUS_FEATURE_TASK_CPUSTATS
CONFIG_OPLUS_FEATURE_CPU_JANKINFO
CONFIG_OPLUS_PERF_SCHEDINFO
CONFIG_OPLUS_FEATURE_FRAME_BOOST
CONFIG_OPLUS_FEATURE_EAS_OPT
CONFIG_OPLUS_FEATURE_QOS_SCHED
CONFIG_OPLUS_FEATURE_LOADBALANCE
CONFIG_OPLUS_FEATURE_PIPELINE
CONFIG_OPLUS_FEATURE_SCHED_SPREAD
CONFIG_OPLUS_FEATURE_TICK_GRAN
CONFIG_OPLUS_SCHED_TUNE
"

# 树里定义过的符号才算数：Kconfig 全文拼起来搜，省得逐个文件 path 猜
ALL_KCONFIG="$(cat "$KW"/common/kernel/oplus_cpu/sched/Kconfig \
                "$KW"/common/kernel/oplus_cpu/Kconfig 2>/dev/null; \
              grep -rh "^config " "$KW"/common/kernel/oplus_cpu 2>/dev/null | awk '{print $2}')"

set_config() {
  local key="$1"
  # 先删同名行（含 "# KEY is not set"），再写一条：kconfig 只认最后一条，
  # 但留着旧行会让人以为没生效
  sed -i "/^$key=/d; /^# $key is not set$/d" "$DC"
  echo "$key=y" >> "$DC"
}

ADDED=0
SKIPPED=""
for sym in $WANT; do
  bare="${sym#CONFIG_}"
  if printf '%s\n' "$ALL_KCONFIG" | grep -qx "$bare"; then
    set_config "$sym"
    ADDED=$((ADDED + 1))
  else
    SKIPPED="$SKIPPED $bare"
  fi
done

echo "OPLUS 调度栈：写入 $ADDED 个配置项"
[ -n "$SKIPPED" ] && echo "该树未定义、已跳过：$SKIPPED"

# ---- trace 头：让 make 构建也能解析 TRACE_INCLUDE_PATH ----
# 厂商的 trace 头只在 CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y 时才把 TRACE_INCLUDE_PATH 指成 "."，
# 否则 include/trace/define_trace.h 会去找 <trace/events/<name>.h>——那是 bazel DDK 的生成物，
# make 构建里根本不存在，于是 fatal error: 'trace/events/trace_sched_assist.h' file not found。
# 这里把那层 #ifdef 打开（等价于 DDK 的生成结果），让头文件在同目录自解析。
# 只改「#ifdef CONFIG_OPLUS_SYSTEM_KERNEL_QCOM 紧跟 #define TRACE_INCLUDE_PATH」这一处，
# 其它同名 ifdef（平台代码里的真实分支）一律不动。
TRACE_FIXED=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  grep -q 'define[[:space:]]*TRACE_INCLUDE_FILE' "$h" || continue
  awk '
    /^#ifdef[ \t]+CONFIG_OPLUS_SYSTEM_KERNEL_QCOM[ \t]*$/ {
      if ((getline nxt) > 0) {
        if (nxt ~ /^#define[ \t]+TRACE_INCLUDE_PATH/) {
          print "#if 1 /* make 构建没有 DDK 生成的 trace 头，TRACE_INCLUDE_PATH 固定同目录 */"
          print nxt
          next
        }
        print $0
        print nxt
        next
      }
    }
    { print }
  ' "$h" > "$h.tmp" && mv "$h.tmp" "$h"
  TRACE_FIXED=$((TRACE_FIXED + 1))
done <<EOF
$(grep -rl 'define[[:space:]]*TRACE_INCLUDE_FILE' "$KW"/common/kernel/oplus_cpu --include='*.h' 2>/dev/null)
EOF
echo "trace 头 TRACE_INCLUDE_PATH 解锁：$TRACE_FIXED 个"

# 校验：sched_assist 的 trace 头必须已经能在同目录解析
SA_TRACE="$KW/common/kernel/oplus_cpu/sched/sched_assist/trace_sched_assist.h"
if [ -f "$SA_TRACE" ]; then
  awk '/^#if 1 .*TRACE_INCLUDE_PATH/{f=1} /^#define[ \t]+TRACE_INCLUDE_PATH/{if (f) ok=1} END{exit ok?0:1}' "$SA_TRACE" \
    || { echo "ERROR: $SA_TRACE 的 TRACE_INCLUDE_PATH 仍未解锁，sched_assist 会编不过" >&2; exit 1; }
fi


# 注意：这里写的是 CONFIG_OPLUS_FEATURE_SCHED_ASSIST 这一族 tristate，打开即参与 make 编译
# （kernel/oplus_cpu/sched/Makefile 里是 obj-$(CONFIG_...)，没得选）。原先它会因为缺
# trace/events/trace_sched_assist.h 直接编译失败，上面的 TRACE_INCLUDE_PATH 解锁就是为这个。
# 关掉本步骤（oplus_sched=false）时这些符号保持原厂的 is not set，sched_assist 不进 make。

# 落盘自检：至少这几个必须进去，否则风驰的底座就是空的
for sym in CONFIG_SCHED_CLASS_EXT CONFIG_OPLUS_FEATURE_SCHED_ASSIST \
           CONFIG_OPLUS_FEATURE_FRAME_BOOST CONFIG_OPLUS_FEATURE_EAS_OPT; do
  grep -qx "$sym=y" "$DC" || { echo "ERROR: defconfig 缺 $sym=y" >&2; exit 1; }
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "> ✅ **OPLUS 调度栈**：sched_ext + sched_assist / frame_boost / eas_opt / qos_sched 已写入 defconfig"
  } >> "$GITHUB_STEP_SUMMARY"
fi
