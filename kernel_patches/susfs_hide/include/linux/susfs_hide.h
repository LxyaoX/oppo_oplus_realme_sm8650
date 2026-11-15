/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _LINUX_SUSFS_HIDE_H
#define _LINUX_SUSFS_HIDE_H

#include <linux/types.h>

struct vfsmount;

/*
 * 按名字隐藏内核模块：命中 /proc/modules 的行与 /proc/kallsyms 里 [name] 结尾的行。
 * /sys/module/<name> 不在这里处理，交给 SUSFS 的 sus_path 规则。
 */
#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
bool susfs_module_name_hidden(const char *name);
void susfs_module_name_hit(bool from_kallsyms);
#else
static inline bool susfs_module_name_hidden(const char *name)
{
	return false;
}

static inline void susfs_module_name_hit(bool from_kallsyms)
{
}
#endif

/*
 * 按挂载点路径前缀判定"这个挂载算我们的"，用于 hide_sus_mnts_for_non_su_procs
 * 生效时对非 su 域隐藏 /proc/self/mounts、mountinfo、mountstats 里的对应行。
 */
#ifdef CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX
bool susfs_mount_prefix_hidden(struct vfsmount *mnt);
#else
static inline bool susfs_mount_prefix_hidden(struct vfsmount *mnt)
{
	return false;
}
#endif

#endif /* _LINUX_SUSFS_HIDE_H */
