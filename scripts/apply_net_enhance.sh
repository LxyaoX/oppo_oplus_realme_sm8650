#!/usr/bin/env bash
# 网络增强：BBRv3 源码补丁 + IPSet / Qdisc / Conntrack / TTL / WireGuard / CIFS 配置。
#
# 用法: apply_net_enhance.sh <kernel_workspace> <kmi> [default_cc]
#   <kernel_workspace>  含 common/ 的那一层
#   <kmi>               android14-6.1；对应 kernel_patches/net_enhance/0001-*-<kmi>.patch
#   [default_cc]        默认拥塞控制：bbr3（默认）/ bbr / cubic / none（none 跳过 BBRv3 补丁）
#
# 补丁来源 WildKernels/kernel_patches common/bbrv3。厂商 6.1 树上实测 dry-run rc=0，
# 部分 hunk 靠 offset/fuzz 落位（net/ipv4/Kconfig、tcp_input.c 等上下文有漂移）。
#
# BBRv3 砸不上时降级到 BBR v1 并明确告警，不让整个构建挂掉；配置部分照常写，
# 只是不写 TCP_CONG_BBR3 / DEFAULT_BBR3 / "bbr3"。
set -euo pipefail

KW="${1:?用法: apply_net_enhance.sh <kernel_workspace> <kmi> [default_cc]}"
KMI="${2:?需要 kmi，如 android14-6.1}"
DEF_CC="${3:-bbr3}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR="$SCRIPT_DIR/../kernel_patches/net_enhance"
PATCH_FILE="$PATCH_DIR/0001-net-tcp-backport-BBRv3-to-$KMI.patch"

cd "$KW"
DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
[ -f "$DEFCONFIG" ] || { echo "ERROR: 找不到 $DEFCONFIG" >&2; exit 1; }
[ -d ./common/net/ipv4 ] || { echo "ERROR: 缺少 common/net/ipv4（内核源码未解包）" >&2; exit 1; }

BBR3_OK=0
# set -e 下不能写 `[ ... ] && SKIP_BBR=1`：条件为假会让整个脚本退出
SKIP_BBR=0
if [ "$DEF_CC" = "none" ]; then
  SKIP_BBR=1
fi

# ---------- 1) BBRv3 补丁 ----------
if [ "$SKIP_BBR" = "1" ]; then
  echo "default_cc=none：跳过 BBRv3 补丁与拥塞控制配置（其余网络增强照常）"
elif [ -f "$PATCH_FILE" ]; then
  cd ./common
  if grep -q '^config TCP_CONG_BBR3' net/ipv4/Kconfig && [ -f net/ipv4/tcp_bbr3.c ]; then
    echo "[*] BBRv3 补丁此前已应用，跳过"
    BBR3_OK=1
  elif patch -p1 --dry-run --forward < "$PATCH_FILE" >/dev/null 2>&1; then
    patch -p1 --no-backup-if-mismatch --forward < "$PATCH_FILE"
    BBR3_OK=1
    echo "[+] BBRv3 补丁已应用"
  elif patch -p1 --dry-run --forward -F 3 < "$PATCH_FILE" >/dev/null 2>&1; then
    # 厂商树持续合入上游 stable 提交，Kconfig / tcp_input.c 的上下文行会漂移。
    # fuzz 3 只放宽上下文匹配，hunk 内容仍须原样落位。
    patch -p1 --no-backup-if-mismatch --forward -F 3 < "$PATCH_FILE"
    BBR3_OK=1
    echo "[+] BBRv3 补丁已应用（上下文漂移，fuzz 3）"
  else
    echo "::warning title=BBRv3 已跳过::补丁在 $KMI 上砸不上，降级 BBR v1"
    echo "NET_ENHANCE_BBR3=skipped" >> "${GITHUB_ENV:-/dev/null}"
  fi
  cd ..

  if [ "$BBR3_OK" = "1" ]; then
    # fuzz 应用可能漏掉新增文件或配置项，落地校验一次再继续
    [ -f ./common/net/ipv4/tcp_bbr3.c ] || { echo "ERROR: 补丁后缺 net/ipv4/tcp_bbr3.c" >&2; exit 1; }
    [ -f ./common/net/ipv4/tcp_plb.c ] || { echo "ERROR: 补丁后缺 net/ipv4/tcp_plb.c" >&2; exit 1; }
    grep -q '^config TCP_CONG_BBR3' ./common/net/ipv4/Kconfig || { echo "ERROR: 补丁后缺 TCP_CONG_BBR3 配置项" >&2; exit 1; }
    grep -q 'tcp_bbr3.o' ./common/net/ipv4/Makefile || { echo "ERROR: Makefile 未挂 tcp_bbr3.o" >&2; exit 1; }
  fi
else
  echo "::warning title=BBRv3 已跳过::找不到 $PATCH_FILE，降级 BBR v1"
  echo "NET_ENHANCE_BBR3=skipped" >> "${GITHUB_ENV:-/dev/null}"
fi

# ---------- 2) 配置 ----------
# 幂等写法：已有同名 key 就改，有 "# KEY is not set" 就替换，都没有才追加。
# 直接 echo 追加会在多次写入同一 symbol 时留下多条，kconfig 只认最后一条，排查时容易看错。
set_config() {
  local key="$1" value="$2"
  # 先删掉所有同名行（含 "# KEY is not set"）再写一条。多条同名 key 时 kconfig 只认
  # 最后一条，行为没错但 defconfig 看着像重复写入，排查时容易误判。
  sed -i "/^$key=/d; /^# $key is not set$/d" "$DEFCONFIG"
  echo "$key=$value" >> "$DEFCONFIG"
}

# IPSet 全家桶 + netfilter 联动
for cfg in IP_SET IP_SET_BITMAP_IP IP_SET_BITMAP_IPMAC IP_SET_BITMAP_PORT \
  IP_SET_HASH_IP IP_SET_HASH_IPMARK IP_SET_HASH_IPPORT IP_SET_HASH_IPPORTIP \
  IP_SET_HASH_IPPORTNET IP_SET_HASH_IPMAC IP_SET_HASH_MAC \
  IP_SET_HASH_NETPORTNET IP_SET_HASH_NET IP_SET_HASH_NETNET \
  IP_SET_HASH_NETPORT IP_SET_HASH_NETIFACE IP_SET_LIST_SET \
  NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_SET NETFILTER_XT_TARGET_LOG \
  NETFILTER_XT_MATCH_RECENT IP6_NF_NAT IP6_NF_TARGET_MASQUERADE; do
  set_config "CONFIG_$cfg" y
done
set_config CONFIG_IP_SET_MAX 65534

# 拥塞控制算法集（none 时只保留 CUBIC —— 它是内核必备基础算法，不能关）
if [ "$SKIP_BBR" = "1" ]; then
  set_config CONFIG_TCP_CONG_CUBIC y
else
  for cfg in TCP_CONG_ADVANCED TCP_CONG_BBR TCP_CONG_CUBIC \
    TCP_CONG_BIC TCP_CONG_WESTWOOD TCP_CONG_HTCP; do
    set_config "CONFIG_$cfg" y
  done
fi

# 流量整形 Qdisc + 连接标记 + TTL/HopLimit + WireGuard
for cfg in NET_SCH_FQ NET_SCH_FQ_CODEL NET_SCH_CAKE NET_ACT_CONNMARK \
  IP_NF_TARGET_TTL IP6_NF_TARGET_HL IP6_NF_MATCH_HL WIREGUARD; do
  set_config "CONFIG_$cfg" y
done

# CIFS 网络文件系统。NETFS_SUPPORT 是隐藏符号，由 CIFS 的 Kconfig select 带出来。
# 本仓库用 make 直接编 Image，不走 bazel，所以不需要像 AnyKernel3 那样去改
# modules.bzl 里 netfs.ko / libarc4.ko 的条目。
for cfg in CIFS NETWORK_FILESYSTEMS KEYS CIFS_XATTR CIFS_POSIX; do
  set_config "CONFIG_$cfg" y
done

# 默认拥塞控制：BBRv3 打上了就按参数选，没打上就退回 bbr / cubic。
# EFFECTIVE_CC 记录真正写进 defconfig 的值，日志按它报，不按请求值报。
EFFECTIVE_CC="$DEF_CC"
case "$DEF_CC" in
  none)
    # 用户明确关了 BBR：不动 DEFAULT_TCP_CONG，让内核走自己的默认（cubic）
    ;;
  *)
    # 只要没关 BBR，BBRv3 算法本身都要编进去（这是相对 BBR v1 的升级点），
    # 区别只在 DEFAULT_* 选谁。
    if [ "$BBR3_OK" = "1" ]; then
      set_config CONFIG_TCP_CONG_BBR3 y
    fi
    case "$DEF_CC" in
      bbr3)
        if [ "$BBR3_OK" = "1" ]; then
          set_config CONFIG_DEFAULT_BBR3 y
          set_config CONFIG_DEFAULT_TCP_CONG '"bbr3"'
        else
          EFFECTIVE_CC=bbr
          set_config CONFIG_DEFAULT_BBR y
          set_config CONFIG_DEFAULT_TCP_CONG '"bbr"'
        fi
        ;;
      bbr)
        set_config CONFIG_DEFAULT_BBR y
        set_config CONFIG_DEFAULT_TCP_CONG '"bbr"'
        ;;
      *)
        EFFECTIVE_CC=cubic
        set_config CONFIG_DEFAULT_TCP_CONG '"cubic"'
        ;;
    esac
    ;;
esac

# ---------- 3) 落盘自检 ----------
fail=0
for key in CONFIG_IP_SET CONFIG_NETFILTER_XT_SET CONFIG_NET_SCH_FQ \
           CONFIG_NET_SCH_FQ_CODEL CONFIG_NET_SCH_CAKE CONFIG_NET_ACT_CONNMARK \
           CONFIG_IP_NF_TARGET_TTL CONFIG_WIREGUARD CONFIG_CIFS; do
  grep -qx "$key=y" "$DEFCONFIG" || { echo "ERROR: $key 未落盘" >&2; fail=1; }
done
grep -qx 'CONFIG_IP_SET_MAX=65534' "$DEFCONFIG" || { echo "ERROR: CONFIG_IP_SET_MAX 未落盘" >&2; fail=1; }
[ "$fail" = "0" ] || exit 1

if [ "$SKIP_BBR" = "1" ]; then
  echo "网络增强完成：BBR 系列按 bbr_enable=false 跳过，IPSet/Qdisc/WireGuard/CIFS 已启用"
elif [ "$BBR3_OK" = "1" ] && [ "$DEF_CC" = "bbr3" ]; then
  grep -qx 'CONFIG_TCP_CONG_BBR3=y' "$DEFCONFIG" || { echo "ERROR: CONFIG_TCP_CONG_BBR3 未落盘" >&2; exit 1; }
  grep -qx 'CONFIG_DEFAULT_TCP_CONG="bbr3"' "$DEFCONFIG" || { echo "ERROR: 默认拥塞控制不是 bbr3" >&2; exit 1; }
  echo "网络增强完成：BBRv3 可用，默认 $EFFECTIVE_CC"
else
  if [ "$BBR3_OK" = "1" ]; then
    echo "网络增强完成：BBRv3 已应用，默认 $EFFECTIVE_CC"
  else
    echo "网络增强完成：BBRv3 未应用（补丁跳过），默认 $EFFECTIVE_CC"
  fi
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    if [ "$SKIP_BBR" = "1" ]; then
      echo "> ✅ **网络增强**：IPSet + Qdisc(fq/fq_codel/cake) + connmark + TTL + WireGuard + CIFS（BBR 按开关跳过）"
    elif [ "$BBR3_OK" = "1" ]; then
      echo "> ✅ **网络增强**：BBRv3 + IPSet + Qdisc(fq/fq_codel/cake) + connmark + TTL + WireGuard + CIFS"
    else
      echo "> ⚠️ **网络增强**：BBRv3 补丁未应用（降级 BBR v1），其余 IPSet/Qdisc/WireGuard/CIFS 已启用"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
