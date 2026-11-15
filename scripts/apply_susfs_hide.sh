#!/usr/bin/env bash
# 源码集成版 SUSFS 的隐藏增强：按模块名隐藏 / 按挂载前缀隐藏。
#
# 用法: apply_susfs_hide.sh <kernel_workspace>
#   <kernel_workspace>  含 common/ 的那一层
#
# 必须在 apply_susfs.sh 之后调用（要往 50 补丁写过的 fs/proc_namespace.c、fs/susfs.c 里插钩子）。
#
# 做的事：
#   1. 拷 fs/susfs_hide.c 与 include/linux/susfs_hide.h 进内核树
#   2. fs/Makefile 挂 obj-$(CONFIG_KSU_SUSFS_HIDE)
#   3. fs/Kconfig 插三个选项（总开关 + 两个子开关）
#   4. 三处钩子：/proc/modules 行过滤、/proc/kallsyms 行过滤、mounts/mountinfo/mountstats 前缀过滤
#   5. fs/susfs.c 的 SHOW_ENABLED_FEATURES 追加两个 token（cat /proc 能自查）
#   6. defconfig 写两个 =y
set -euo pipefail

KW="${1:?用法: apply_susfs_hide.sh <kernel_workspace>}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR="$SCRIPT_DIR/../kernel_patches/susfs_hide"

cd "$KW"

for f in common/fs/Makefile common/fs/Kconfig common/kernel/module/procfs.c \
         common/kernel/kallsyms.c common/fs/proc_namespace.c; do
  [ -f "$f" ] || { echo "ERROR: 缺少 $f（内核源码未解包或 SUSFS 补丁未打）" >&2; exit 1; }
done
[ -f "$SRC_DIR/fs/susfs_hide.c" ] || { echo "ERROR: 找不到 $SRC_DIR/fs/susfs_hide.c" >&2; exit 1; }

# 1) 源码就位
cp "$SRC_DIR/fs/susfs_hide.c" ./common/fs/susfs_hide.c
cp "$SRC_DIR/include/linux/susfs_hide.h" ./common/include/linux/susfs_hide.h
echo "已拷入 fs/susfs_hide.c 与 include/linux/susfs_hide.h"

# 2) fs/Makefile
if ! grep -q 'susfs_hide.o' ./common/fs/Makefile; then
  printf 'obj-$(CONFIG_KSU_SUSFS_HIDE) += susfs_hide.o\n' >> ./common/fs/Makefile
fi

# 3) fs/Kconfig：插在第一个 endmenu 之前
if ! grep -q 'config KSU_SUSFS_HIDE$' ./common/fs/Kconfig; then
  python3 - ./common/fs/Kconfig <<'PY'
import io
import sys

path = sys.argv[1]
text = io.open(path, encoding='utf-8').read()
block = """config KSU_SUSFS_HIDE
\tbool
\tdefault y if KSU_SUSFS_HIDE_MODULES || KSU_SUSFS_HIDE_MOUNT_PREFIX

config KSU_SUSFS_HIDE_MODULES
\tbool "SUSFS: hide module names from /proc/modules and /proc/kallsyms"
\tdepends on KSU_SUSFS
\tdefault y
\thelp
\t  Drop matching lines out of /proc/modules and /proc/kallsyms for the
\t  module names listed in /proc/susfs_hide_modules. /sys/module/<name>
\t  is not touched here; use a sus_path rule for that.

config KSU_SUSFS_HIDE_MOUNT_PREFIX
\tbool "SUSFS: hide mounts by path prefix"
\tdepends on KSU_SUSFS
\tdefault y
\thelp
\t  Extra filter for /proc/self/{mounts,mountinfo,mountstats} once
\t  hide_sus_mnts_for_non_su_procs is on: a mount whose mountpoint starts
\t  with one of the prefixes in /proc/susfs_hide_mounts is dropped for
\t  non-su domains.

"""
idx = text.rfind('\nendmenu')
if idx < 0:
    sys.exit('fs/Kconfig: endmenu not found')
text = text[:idx + 1] + block + text[idx + 1:]
io.open(path, 'w', encoding='utf-8', newline='').write(text)
PY
fi

# 4) 钩子插入 + 5) features token。锚点固定，插完逐条断言，插歪了直接失败
python3 - "$PWD" <<'PY'
import io
import os
import sys

root = sys.argv[1]


def patch(rel, include_anchor, include_line, hook_anchor, hook_block,
          expected_hooks, hook_count=None):
    path = '%s/%s' % (root, rel)
    text = io.open(path, encoding='utf-8').read()
    if include_line.strip() in text:
        pass
    else:
        if include_anchor not in text:
            sys.exit('%s: include anchor missing' % rel)
        text = text.replace(include_anchor, include_line + include_anchor, 1)
    have = text.count(hook_anchor)
    if have == 0:
        sys.exit('%s: hook anchor missing' % rel)
    if hook_count is not None and have != hook_count:
        sys.exit('%s: expected %d hook anchor(s), found %d' % (rel, hook_count, have))
    if hook_block not in text:
        text = text.replace(hook_anchor, hook_anchor + hook_block)
    io.open(path, 'w', encoding='utf-8', newline='').write(text)
    got = io.open(path, encoding='utf-8').read().count(hook_anchor + hook_block)
    if got != expected_hooks:
        sys.exit('%s: hook inserted %d time(s), expected %d' % (rel, got, expected_hooks))


# /proc/modules：m_show() 里跳过未成形模块之后
patch(
    'common/kernel/module/procfs.c',
    '#include "internal.h"',
    '#include <linux/susfs_hide.h>\n',
    '\tif (mod->state == MODULE_STATE_UNFORMED)\n\t\treturn 0;\n',
    """#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
\tif (susfs_module_name_hidden(mod->name)) {
\t\tsusfs_module_name_hit(false);
\t\treturn 0;
\t}
#endif
""",
    1,
)

# /proc/kallsyms：s_show() 里跳过无名符号之后。iter->module_name 为空表示内核符号，
# 函数内部已处理空串，所以不需要额外判断
patch(
    'common/kernel/kallsyms.c',
    '#include <linux/kdb.h>',
    '#include <linux/susfs_hide.h>\n',
    '\tif (!iter->name[0])\n\t\treturn 0;\n',
    """#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
\tif (susfs_module_name_hidden(iter->module_name)) {
\t\tsusfs_module_name_hit(true);
\t\treturn 0;
\t}
#endif
""",
    1,
)

# mounts / mountinfo / mountstats：三个 susfs 替代实现里同一处判据
patch(
    'common/fs/proc_namespace.c',
    '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\n#include "proc/internal.h"',
    '#include <linux/susfs_hide.h>\n',
    '\tif (r->mnt_id >= DEFAULT_KSU_MNT_ID)\n\t\treturn 0;\n',
    """#ifdef CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX
\tif (susfs_mount_prefix_hidden(mnt))
\t\treturn 0;
#endif
""",
    3,
    3,
)

# features token：让 cat 出来能确认编进去了（fs/susfs.c 是 50 补丁产物，没有就跳过）
path = '%s/common/fs/susfs.c' % root
if not os.path.exists(path):
    print('fs/susfs.c 不存在，跳过 features token 注入')
    raise SystemExit(0)
text = io.open(path, encoding='utf-8').read()
if 'CONFIG_KSU_SUSFS_HIDE_MODULES\\n' not in text:
    start = text.find('void susfs_get_enabled_features')
    if start < 0:
        sys.exit('fs/susfs.c: susfs_get_enabled_features not found')
    tail = text.find('\tinfo->err = 0;', start)
    if tail < 0:
        sys.exit('fs/susfs.c: "info->err = 0;" anchor not found')
    inject = """#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
\tinfo->err = copy_config_to_buf("CONFIG_KSU_SUSFS_HIDE_MODULES\\n", buf_ptr, &copied_size, SUSFS_ENABLED_FEATURES_SIZE);
\tif (info->err) goto out_copy_to_user;
\tbuf_ptr = info->enabled_features + copied_size;
#endif
#ifdef CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX
\tinfo->err = copy_config_to_buf("CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX\\n", buf_ptr, &copied_size, SUSFS_ENABLED_FEATURES_SIZE);
\tif (info->err) goto out_copy_to_user;
\tbuf_ptr = info->enabled_features + copied_size;
#endif
"""
    text = text[:tail] + inject + text[tail:]
    io.open(path, 'w', encoding='utf-8', newline='').write(text)
PY

# 6) defconfig
DC=./common/arch/arm64/configs/gki_defconfig
for opt in CONFIG_KSU_SUSFS_HIDE_MODULES CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX; do
  sed -i "/^${opt}=/d" "$DC"
  echo "${opt}=y" >> "$DC"
done

# 落盘自检：任何一条不满足都说明插歪或没编，别等编译期
fail=0
check() { if ! eval "$2"; then echo "ERROR: $1" >&2; fail=1; fi; }
check "fs/susfs_hide.c 缺失"            "[ -f ./common/fs/susfs_hide.c ]"
check "include/linux/susfs_hide.h 缺失" "[ -f ./common/include/linux/susfs_hide.h ]"
check "fs/Makefile 未挂 susfs_hide.o"   "grep -qF 'obj-\$(CONFIG_KSU_SUSFS_HIDE) += susfs_hide.o' ./common/fs/Makefile"
check "fs/Kconfig 缺 KSU_SUSFS_HIDE"    "grep -qx 'config KSU_SUSFS_HIDE' ./common/fs/Kconfig"
check "/proc/modules 钩子缺失"          "grep -qF 'susfs_module_name_hit(false)' ./common/kernel/module/procfs.c"
check "/proc/kallsyms 钩子缺失"         "grep -qF 'susfs_module_name_hit(true)' ./common/kernel/kallsyms.c"
check "features token 缺失"             "grep -qF 'CONFIG_KSU_SUSFS_HIDE_MODULES' ./common/fs/susfs.c"
check "defconfig 缺 HIDE_MODULES"       "grep -qx 'CONFIG_KSU_SUSFS_HIDE_MODULES=y' '$DC'"
check "defconfig 缺 HIDE_MOUNT_PREFIX"  "grep -qx 'CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX=y' '$DC'"
if [ "$(grep -c 'susfs_mount_prefix_hidden' ./common/fs/proc_namespace.c)" != "3" ]; then
  echo "ERROR: mount 前缀钩子数不为 3" >&2
  fail=1
fi
[ "$fail" = "0" ] || exit 1

echo "SUSFS 隐藏增强已就位：/proc/susfs_hide_modules、/proc/susfs_hide_mounts"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "> ✅ **SUSFS 隐藏增强**：/proc/susfs_hide_modules（模块名）、/proc/susfs_hide_mounts（挂载前缀）"
  } >> "$GITHUB_STEP_SUMMARY"
fi
