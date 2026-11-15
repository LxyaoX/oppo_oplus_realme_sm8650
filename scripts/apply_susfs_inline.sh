#!/usr/bin/env bash
# 打开 FinaSU 的 SUSFS Inline 后端（CONFIG_KSU_HOOK_SUSFS_INLINE）。
#
# 用法: apply_susfs_inline.sh <kernel_workspace>
#   <kernel_workspace>  含 common/ 与 KernelSU/ 的那一层
#
# 必须在两件事之后调用，否则必然失败：
#   1) apply_finasu.sh        —— 驱动源码已在 <kw>/KernelSU，工具脚本才存在
#   2) apply_susfs.sh         —— 50 补丁已把 ksu_handle_* 调用点写进内核树
#
# Inline 语义（FinaSU 侧，kernel/Kconfig）：
#   depends on ARM64 && KSU=y && KSU_SUSFS
#   开启后不注册通用 sys_enter tracepoint / dispatcher / kprobe，改用内核树里的直调入口；
#   Kbuild 在 drivers/kernelsu 解析期会跑 kernel/tools/check_susfs_inline.sh 校验实际源码，
#   缺入口直接 $(error)，不会静默回退到 Tracepoint。这里提前跑一遍，报错更清楚。
set -euo pipefail

KW="${1:?用法: apply_susfs_inline.sh <kernel_workspace>}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cd "$KW"

DC="./common/arch/arm64/configs/gki_defconfig"
CHECK="./KernelSU/kernel/tools/check_susfs_inline.sh"

[ -f "$DC" ] || { echo "ERROR: 找不到 $DC" >&2; exit 1; }
[ -f "$CHECK" ] || { echo "ERROR: 找不到 $CHECK（FinaSU 驱动未集成？）" >&2; exit 1; }
[ -d "./common/fs" ] || { echo "ERROR: 内核树缺少 common/fs（源码未解包？）" >&2; exit 1; }

# 上游脚本从 tar/git 来可能丢可执行位，Kbuild 里是 $(shell ...) 直接跑，先补上
chmod +x "$CHECK" 2>/dev/null || true

# 1) 校验内核树真有 inline 调用点。12 个入口缺一个，链接期就是 undefined symbol，
#    这里先给出「缺哪个文件哪个符号」，比等到 ld.lld 快得多。
echo "校验内核树的 SUSFS Inline 调用点..."
if ! bash "$CHECK" "$(cd ./common && pwd)"; then
  echo "ERROR: 内核树缺少 SUSFS Inline 调用点，先把 SUSFS 补丁打全（apply_susfs.sh）" >&2
  exit 1
fi

# 2) defconfig 改 choice。KSU_HOOK_TRACEPOINT 与 KSU_HOOK_SUSFS_INLINE 在同一个 choice 里，
#    两条都 =y 时 kconfig 会保留先声明的 TRACEPOINT 并打 override 警告 —— 必须删干净。
sed -i '/^CONFIG_KSU_HOOK_TRACEPOINT=y$/d' "$DC"
sed -i '/^# CONFIG_KSU_HOOK_TRACEPOINT is not set$/d' "$DC"
sed -i '/^CONFIG_KSU_HOOK_SUSFS_INLINE=/d' "$DC"
echo "CONFIG_KSU_HOOK_SUSFS_INLINE=y" >> "$DC"

# 3) 依赖兜底：KSU_SUSFS 被显式写成 n 时 inline 的 depends 不成立，kconfig 会把
#    CONFIG_KSU_HOOK_SUSFS_INLINE 静默降级成 not set，构建仍然通过但后端没生效。
if grep -q '^CONFIG_KSU_SUSFS=' "$DC"; then
  if ! grep -qx 'CONFIG_KSU_SUSFS=y' "$DC"; then
    sed -i 's/^CONFIG_KSU_SUSFS=.*/CONFIG_KSU_SUSFS=y/' "$DC"
    echo "注意: CONFIG_KSU_SUSFS 原为非 y，已改为 y（inline 的硬依赖）"
  fi
else
  echo "CONFIG_KSU_SUSFS=y" >> "$DC"
fi
grep -qx 'CONFIG_KSU=y' "$DC" || echo "CONFIG_KSU=y" >> "$DC"

# 4) 落盘自检：任何一条不满足就是没生效，宁可在这里失败
[ "$(grep -c '^CONFIG_KSU_HOOK_SUSFS_INLINE=y$' "$DC")" = "1" ] || {
  echo "ERROR: CONFIG_KSU_HOOK_SUSFS_INLINE=y 未落盘或重复" >&2; exit 1; }
[ "$(grep -c 'KSU_HOOK_TRACEPOINT' "$DC")" = "0" ] || {
  echo "ERROR: defconfig 仍残留 KSU_HOOK_TRACEPOINT" >&2; exit 1; }
grep -qx 'CONFIG_KSU_SUSFS=y' "$DC" || { echo "ERROR: CONFIG_KSU_SUSFS 不是 y" >&2; exit 1; }
grep -qx 'CONFIG_KSU=y' "$DC" || { echo "ERROR: CONFIG_KSU 不是 y" >&2; exit 1; }

# inline 要求 preinit 两侧一致：fs/exec.c 的 ksu_setup_preinit_file 调用在 #ifndef
# KSU_NO_PREINIT 里，驱动侧头文件缺失时会把 preinit.o 摘掉，这里顺带确认没被摘
if ! grep -q 'ksu_setup_preinit_file' ./common/fs/exec.c; then
  echo "ERROR: fs/exec.c 缺 ksu_setup_preinit_file（preinit 未启用或补丁不全）" >&2
  exit 1
fi

echo "SUSFS Inline 后端已启用（CONFIG_KSU_HOOK_SUSFS_INLINE=y，TRACEPOINT 已移除）"

if [ -n "${GITHUB_ENV:-}" ]; then echo "SUSFS_INLINE=true" >> "$GITHUB_ENV"; fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "> ✅ **SUSFS Inline 后端**已启用：syscall 走内核树直调入口，不注册 tracepoint/dispatcher/kprobe"
  } >> "$GITHUB_STEP_SUMMARY"
fi
