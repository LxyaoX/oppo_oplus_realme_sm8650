#!/usr/bin/env bash
# 自定义构建时间：把内核版本串里的编译时间固定成指定值（可复现构建）。
#
# 用法: apply_build_time.sh <kernel_workspace> [build_time]
#   <kernel_workspace>  含 common/ 的那一层
#   [build_time]        "Tue Dec  1 08:10:00 UTC 2026"；留空 / N / n 表示用当前时间
#
# 移植自 LxyaoX/AnyKernel3 的「设置自定义构建时间」步骤。做法有两层：
#   1. 导出 KBUILD_BUILD_TIMESTAMP（kbuild 的时间源）
#   2. 把 UTS_VERSION 硬写进 scripts/mkcompile_h 生成的 compile.h
# 厂商 OKI 树的 mkcompile_h 把 UTS_VERSION 那段删了，只留 UTS_MACHINE /
# LINUX_COMPILE_BY / HOST / COMPILER，所以这里在 heredoc 里补回一行，
# 否则 `uname -a` 的版本串里没有时间，这个开关等于没接线。
set -euo pipefail

KW="${1:?用法: apply_build_time.sh <kernel_workspace> [build_time]}"
INPUT_TIME="${2:-}"

cd "$KW"
MKCOMPILE=./common/scripts/mkcompile_h
[ -f "$MKCOMPILE" ] || { echo "ERROR: 找不到 $MKCOMPILE（内核源码未解包）" >&2; exit 1; }

# 统一空白：兼容 "Dec 03" / "Dec 3" / "Dec  3" 三种写法
INPUT_TIME="$(printf '%s' "$INPUT_TIME" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g')"

if [ -n "$INPUT_TIME" ] && [ "$INPUT_TIME" != "N" ] && [ "$INPUT_TIME" != "n" ]; then
  TIME_REGEX='^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ( ?[1-9]|0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] UTC [0-9]{4}$'
  if [[ ! "$INPUT_TIME" =~ $TIME_REGEX ]]; then
    echo "ERROR: 构建时间格式错误，必须形如 Tue Dec  1 08:10:00 UTC 2026（两位日期）" >&2
    exit 1
  fi

  # date -d 会拒绝不存在的日期（2 月 30 日），顺带规范化单空格 / 个位日期
  NORMALIZED="$(LC_ALL=C TZ=UTC date -u -d "$INPUT_TIME" +'%a %b %e %T UTC %Y' 2>/dev/null || true)"
  if [ -z "$NORMALIZED" ]; then
    echo "ERROR: 构建时间无法解析为真实 UTC 时间：$INPUT_TIME" >&2
    exit 1
  fi

  # GNU date 解析时忽略输入的星期字段，这里单独算真实星期再比对，防止写成 Feb 30 Tue 这类
  TYPED_WD="${INPUT_TIME%% *}"
  REAL_WD="$(LC_ALL=C TZ=UTC date -u -d "${INPUT_TIME#* }" +%a 2>/dev/null || true)"
  if [ -z "$REAL_WD" ] || [ "$TYPED_WD" != "$REAL_WD" ]; then
    echo "ERROR: 星期与日期不匹配，实际应为 ${REAL_WD:-未知}（参考：$NORMALIZED）" >&2
    exit 1
  fi

  DATESTR="$NORMALIZED"
  SOURCE="自定义"
else
  DATESTR="$(TZ='CST-8' date +'%a %b %d %T UTC %Y')"
  SOURCE="当前时间"
fi

echo "构建时间（$SOURCE）: $DATESTR"

# 1) kbuild 时间源。写进 GITHUB_ENV 让后续编译步骤继承；本地 builder 直接 export。
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "KBUILD_BUILD_TIMESTAMP=$DATESTR"
    echo "KBUILD_BUILD_VERSION=1"
  } >> "$GITHUB_ENV"
fi
export KBUILD_BUILD_TIMESTAMP="$DATESTR"
export KBUILD_BUILD_VERSION=1

# 本地 builder 没有 GITHUB_ENV，脚本进程内的 export 传不回父 shell，
# 落一份可 source 的环境文件给它用（CI 上这份文件没用，留着无害）
printf 'export KBUILD_BUILD_TIMESTAMP=%q\nexport KBUILD_BUILD_VERSION=1\n' "$DATESTR" > "./.build_time.env"

# 2) mkcompile_h：把 UTS_VERSION 固定成 "#1 SMP PREEMPT <time>"
python3 - "$MKCOMPILE" "$DATESTR" <<'PY'
import io
import re
import sys

path, datestr = sys.argv[1], sys.argv[2]
text = io.open(path, encoding='utf-8').read()
line = '#define UTS_VERSION\t\t"#1 SMP PREEMPT %s"' % datestr

if re.search(r'^#define UTS_VERSION', text, re.M):
    # 上游树本来就有这一行，替换即可
    text = re.sub(r'^#define UTS_VERSION.*$', line, text, count=1, flags=re.M)
    action = 'replaced'
elif '#define LINUX_COMPILER' in text:
    # 厂商树删掉了这行，补在 LINUX_COMPILER 后面（同属 compile.h 的宏，位置不影响）
    text = text.replace(
        '#define LINUX_COMPILER',
        line + '\n#define LINUX_COMPILER',
        1,
    )
    action = 'inserted'
else:
    sys.exit('mkcompile_h 里找不到 LINUX_COMPILER，无法插入 UTS_VERSION')

io.open(path, 'w', encoding='utf-8', newline='').write(text)
print('UTS_VERSION %s: %s' % (action, line))
PY

# 3) 落盘自检
grep -q '#define UTS_VERSION' "$MKCOMPILE" || { echo "ERROR: UTS_VERSION 未写入 mkcompile_h" >&2; exit 1; }
grep -qF 'SMP PREEMPT' "$MKCOMPILE" || { echo "ERROR: UTS_VERSION 内容异常" >&2; exit 1; }

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "> 🕒 **构建时间**（$SOURCE）：\`$DATESTR\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
