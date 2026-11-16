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
