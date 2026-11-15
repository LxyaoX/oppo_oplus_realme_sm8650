// SPDX-License-Identifier: GPL-2.0-only
/*
 * susfs_hide.c - 源码集成版 SUSFS：按名字隐藏内核模块、按挂载前缀隐藏挂载
 *
 * 上游分流：
 *   - ShirkNeko/susfs4ksu 的 50 补丁（源码集成版）只覆盖按 inode / mnt_id 标记的隐藏；
 *   - 按"模块名"与"挂载前缀"归类的两个能力只存在于 SUSFS-LKM
 *     （inforcqb/susfs4ksu-for-lkm），靠 kprobe / inline patch 实现。
 * 本文件把这两个能力做进内核树，接口格式与 LKM 保持一致，userspace 直接写
 * /proc 节点即可，不依赖 LKM 的 hook 框架。
 *
 * 边界（写在这里，免得后面误判）：
 *   - /proc/modules 只做行级过滤。别的模块 used-by 列里仍会带出被隐藏的名字。
 *   - /sys/module/<name> 不在这里处理，用已有的 sus_path 规则隐藏即可。
 *   - 挂载前缀只在 hide_sus_mnts_for_non_su_procs 生效时起作用（和 sus_mount 同一
 *     个出口），su 域本来就不走 susfs_show_* 那三个函数。
 *   - 前缀判定用 d_path()，每个挂载行一次路径拼接；前缀表为空时直接返回，零开销。
 */
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/dcache.h>
#include <linux/mount.h>
#include <linux/fs.h>
#include <linux/atomic.h>
#include <linux/limits.h>
#include <linux/susfs_hide.h>

#define SUSFS_HIDE_MAX_MODULES		16
#define SUSFS_HIDE_MAX_PREFIXES		64
#define SUSFS_HIDE_MODULE_NAME_LEN	64
#define SUSFS_HIDE_PREFIX_LEN		256
#define SUSFS_HIDE_WRITE_BUF		4096

static DEFINE_MUTEX(susfs_hide_lock);

#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
static char *hidden_module_names[SUSFS_HIDE_MAX_MODULES];
static int hidden_module_count;
static atomic_long_t module_line_hits = ATOMIC_LONG_INIT(0);
static atomic_long_t kallsyms_line_hits = ATOMIC_LONG_INIT(0);
#endif

#ifdef CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX
static char *hidden_mount_prefixes[SUSFS_HIDE_MAX_PREFIXES];
static int hidden_mount_prefix_count;
static atomic_long_t mount_line_hits = ATOMIC_LONG_INIT(0);

/* 与 SUSFS-LKM 的默认前缀一致：模块自己会往这两处挂 */
static const char *const susfs_hide_default_prefixes[] = {
	"/data/adb/",
	"/data/local/tmp/",
};
#endif

#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
/*
 * 模块名规则和内核 modpost 一致：字母、数字、下划线，长度 1..63。
 * 非法名字直接拒绝，免得写进表里之后永远匹配不上。
 */
static bool susfs_hide_valid_module_name(const char *name)
{
	size_t len;
	size_t i;

	if (!name || !name[0])
		return false;
	len = strlen(name);
	if (len >= SUSFS_HIDE_MODULE_NAME_LEN)
		return false;
	for (i = 0; i < len; i++) {
		char c = name[i];

		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		      (c >= '0' && c <= '9') || c == '_'))
			return false;
	}
	return true;
}

bool susfs_module_name_hidden(const char *name)
{
	int i;
	bool hit = false;

	if (!name || !name[0])
		return false;
	if (!READ_ONCE(hidden_module_count))
		return false;

	mutex_lock(&susfs_hide_lock);
	for (i = 0; i < hidden_module_count; i++) {
		if (!strcmp(hidden_module_names[i], name)) {
			hit = true;
			break;
		}
	}
	mutex_unlock(&susfs_hide_lock);
	return hit;
}
EXPORT_SYMBOL_GPL(susfs_module_name_hidden);

/* 计数分两条：/proc/modules 与 /proc/kallsyms 的命中量分开看才知道钩子挂没挂上 */
void susfs_module_name_hit(bool from_kallsyms)
{
	if (from_kallsyms)
		atomic_long_inc(&kallsyms_line_hits);
	else
		atomic_long_inc(&module_line_hits);
}
EXPORT_SYMBOL_GPL(susfs_module_name_hit);

static void susfs_hide_modules_clear_locked(void)
{
	int i;

	for (i = 0; i < hidden_module_count; i++) {
		kfree(hidden_module_names[i]);
		hidden_module_names[i] = NULL;
	}
	hidden_module_count = 0;
}

static int susfs_hide_modules_show(struct seq_file *m, void *v)
{
	int i;

	mutex_lock(&susfs_hide_lock);
	seq_printf(m, "hide_modules: %d/%d name(s), /proc/modules lines removed=%ld, kallsyms lines removed=%ld\n",
		   hidden_module_count, SUSFS_HIDE_MAX_MODULES,
		   atomic_long_read(&module_line_hits),
		   atomic_long_read(&kallsyms_line_hits));
	seq_puts(m, "names:");
	for (i = 0; i < hidden_module_count; i++)
		seq_printf(m, " %s", hidden_module_names[i]);
	seq_putc(m, '\n');
	mutex_unlock(&susfs_hide_lock);
	return 0;
}

static int susfs_hide_modules_open(struct inode *inode, struct file *file)
{
	return single_open(file, susfs_hide_modules_show, NULL);
}

/*
 * add <name> / del <name> / set <name>… / clear
 * set 是整份替换：先解析到临时表，全部合法才提交，中途失败不动现有表。
 */
static ssize_t susfs_hide_modules_write(struct file *file, const char __user *ubuf,
					size_t count, loff_t *ppos)
{
	char *buf;
	char *cursor;
	char *cmd;
	char *tmp[SUSFS_HIDE_MAX_MODULES] = { 0 };
	int tmp_count = 0;
	int i;
	ssize_t ret = count;

	if (!count || count > SUSFS_HIDE_WRITE_BUF)
		return -EINVAL;

	buf = memdup_user_nul(ubuf, count);
	if (IS_ERR(buf))
		return PTR_ERR(buf);

	cursor = strim(buf);
	cmd = strsep(&cursor, " \t");
	if (!cmd || !cmd[0]) {
		ret = -EINVAL;
		goto out;
	}

	if (!strcmp(cmd, "clear")) {
		mutex_lock(&susfs_hide_lock);
		susfs_hide_modules_clear_locked();
		mutex_unlock(&susfs_hide_lock);
		goto out;
	}

	if (!strcmp(cmd, "add") || !strcmp(cmd, "del")) {
		char *name = cursor ? strim(cursor) : NULL;

		if (!susfs_hide_valid_module_name(name)) {
			ret = -EINVAL;
			goto out;
		}

		mutex_lock(&susfs_hide_lock);
		if (!strcmp(cmd, "add")) {
			bool exists = false;

			for (i = 0; i < hidden_module_count; i++) {
				if (!strcmp(hidden_module_names[i], name)) {
					exists = true;
					break;
				}
			}
			if (exists) {
				ret = -EEXIST;
			} else if (hidden_module_count >= SUSFS_HIDE_MAX_MODULES) {
				ret = -ENOSPC;
			} else {
				hidden_module_names[hidden_module_count] = kstrdup(name, GFP_KERNEL);
				if (!hidden_module_names[hidden_module_count])
					ret = -ENOMEM;
				else
					hidden_module_count++;
			}
		} else {
			bool found = false;

			for (i = 0; i < hidden_module_count; i++) {
				if (!strcmp(hidden_module_names[i], name)) {
					kfree(hidden_module_names[i]);
					hidden_module_names[i] =
						hidden_module_names[hidden_module_count - 1];
					hidden_module_names[hidden_module_count - 1] = NULL;
					hidden_module_count--;
					found = true;
					break;
				}
			}
			if (!found)
				ret = -ENOENT;
		}
		mutex_unlock(&susfs_hide_lock);
		goto out;
	}

	if (!strcmp(cmd, "set")) {
		while (cursor && *cursor) {
			char *name = strsep(&cursor, " \t\n");

			if (!name || !name[0])
				continue;
			if (!susfs_hide_valid_module_name(name)) {
				ret = -EINVAL;
				goto free_tmp;
			}
			if (tmp_count >= SUSFS_HIDE_MAX_MODULES) {
				ret = -ENOSPC;
				goto free_tmp;
			}
			tmp[tmp_count] = kstrdup(name, GFP_KERNEL);
			if (!tmp[tmp_count]) {
				ret = -ENOMEM;
				goto free_tmp;
			}
			tmp_count++;
		}

		mutex_lock(&susfs_hide_lock);
		susfs_hide_modules_clear_locked();
		for (i = 0; i < tmp_count; i++) {
			hidden_module_names[i] = tmp[i];
			tmp[i] = NULL;
		}
		hidden_module_count = tmp_count;
		mutex_unlock(&susfs_hide_lock);
		goto out;
	}

	ret = -EINVAL;

free_tmp:
	for (i = 0; i < SUSFS_HIDE_MAX_MODULES; i++)
		kfree(tmp[i]);
out:
	kfree(buf);
	return ret;
}

static const struct proc_ops susfs_hide_modules_proc_ops = {
	.proc_open	= susfs_hide_modules_open,
	.proc_read	= seq_read,
	.proc_write	= susfs_hide_modules_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};
#endif /* CONFIG_KSU_SUSFS_HIDE_MODULES */

#ifdef CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX
static void susfs_hide_prefixes_clear_locked(void)
{
	int i;

	for (i = 0; i < hidden_mount_prefix_count; i++) {
		kfree(hidden_mount_prefixes[i]);
		hidden_mount_prefixes[i] = NULL;
	}
	hidden_mount_prefix_count = 0;
}

static int susfs_hide_add_prefix_locked(const char *prefix)
{
	int i;

	for (i = 0; i < hidden_mount_prefix_count; i++) {
		if (!strcmp(hidden_mount_prefixes[i], prefix))
			return -EEXIST;
	}
	if (hidden_mount_prefix_count >= SUSFS_HIDE_MAX_PREFIXES)
		return -ENOSPC;

	hidden_mount_prefixes[hidden_mount_prefix_count] = kstrdup(prefix, GFP_KERNEL);
	if (!hidden_mount_prefixes[hidden_mount_prefix_count])
		return -ENOMEM;
	hidden_mount_prefix_count++;
	return 0;
}

/*
 * 前缀必须是绝对路径；末尾斜杠决定匹配粒度，所以这里原样保存不补斜杠，
 * 与 LKM 的行为一致（"/data/adb/" 匹配子路径，"/data/adb" 也匹配自身）。
 */
static bool susfs_hide_valid_prefix(const char *prefix)
{
	size_t len;

	if (!prefix || prefix[0] != '/')
		return false;
	len = strlen(prefix);
	if (len >= SUSFS_HIDE_PREFIX_LEN)
		return false;
	return true;
}

static int susfs_hide_prefixes_show(struct seq_file *m, void *v)
{
	int i;

	mutex_lock(&susfs_hide_lock);
	seq_printf(m, "mount prefixes: %d/%d, hidden lines=%ld\n",
		   hidden_mount_prefix_count, SUSFS_HIDE_MAX_PREFIXES,
		   atomic_long_read(&mount_line_hits));
	seq_puts(m, "prefixes:");
	for (i = 0; i < hidden_mount_prefix_count; i++)
		seq_printf(m, " %s", hidden_mount_prefixes[i]);
	seq_putc(m, '\n');
	mutex_unlock(&susfs_hide_lock);
	return 0;
}

static int susfs_hide_prefixes_open(struct inode *inode, struct file *file)
{
	return single_open(file, susfs_hide_prefixes_show, NULL);
}

static void susfs_hide_prefixes_reset_locked(void)
{
	size_t i;

	susfs_hide_prefixes_clear_locked();
	for (i = 0; i < ARRAY_SIZE(susfs_hide_default_prefixes); i++)
		(void)susfs_hide_add_prefix_locked(susfs_hide_default_prefixes[i]);
}

/* add <prefix> / del <prefix> / set <prefix>… / reset / clear */
static ssize_t susfs_hide_prefixes_write(struct file *file, const char __user *ubuf,
					 size_t count, loff_t *ppos)
{
	char *buf;
	char *cursor;
	char *cmd;
	char *tmp[SUSFS_HIDE_MAX_PREFIXES] = { 0 };
	int tmp_count = 0;
	int i;
	ssize_t ret = count;

	if (!count || count > SUSFS_HIDE_WRITE_BUF)
		return -EINVAL;

	buf = memdup_user_nul(ubuf, count);
	if (IS_ERR(buf))
		return PTR_ERR(buf);

	cursor = strim(buf);
	cmd = strsep(&cursor, " \t");
	if (!cmd || !cmd[0]) {
		ret = -EINVAL;
		goto out;
	}

	if (!strcmp(cmd, "clear")) {
		mutex_lock(&susfs_hide_lock);
		susfs_hide_prefixes_clear_locked();
		mutex_unlock(&susfs_hide_lock);
		goto out;
	}

	if (!strcmp(cmd, "reset")) {
		mutex_lock(&susfs_hide_lock);
		susfs_hide_prefixes_reset_locked();
		mutex_unlock(&susfs_hide_lock);
		goto out;
	}

	if (!strcmp(cmd, "add") || !strcmp(cmd, "del")) {
		char *prefix = cursor ? strim(cursor) : NULL;

		if (!susfs_hide_valid_prefix(prefix)) {
			ret = -EINVAL;
			goto out;
		}

		mutex_lock(&susfs_hide_lock);
		if (!strcmp(cmd, "add")) {
			ssize_t rc = susfs_hide_add_prefix_locked(prefix);

			if (rc)
				ret = rc;
		} else {
			bool found = false;

			for (i = 0; i < hidden_mount_prefix_count; i++) {
				if (!strcmp(hidden_mount_prefixes[i], prefix)) {
					kfree(hidden_mount_prefixes[i]);
					hidden_mount_prefixes[i] =
						hidden_mount_prefixes[hidden_mount_prefix_count - 1];
					hidden_mount_prefixes[hidden_mount_prefix_count - 1] = NULL;
					hidden_mount_prefix_count--;
					found = true;
					break;
				}
			}
			if (!found)
				ret = -ENOENT;
		}
		mutex_unlock(&susfs_hide_lock);
		goto out;
	}

	if (!strcmp(cmd, "set")) {
		while (cursor && *cursor) {
			char *prefix = strsep(&cursor, " \t\n");

			if (!prefix || !prefix[0])
				continue;
			if (!susfs_hide_valid_prefix(prefix)) {
				ret = -EINVAL;
				goto free_tmp;
			}
			if (tmp_count >= SUSFS_HIDE_MAX_PREFIXES) {
				ret = -ENOSPC;
				goto free_tmp;
			}
			tmp[tmp_count] = kstrdup(prefix, GFP_KERNEL);
			if (!tmp[tmp_count]) {
				ret = -ENOMEM;
				goto free_tmp;
			}
			tmp_count++;
		}

		mutex_lock(&susfs_hide_lock);
		susfs_hide_prefixes_clear_locked();
		for (i = 0; i < tmp_count; i++) {
			hidden_mount_prefixes[i] = tmp[i];
			tmp[i] = NULL;
		}
		hidden_mount_prefix_count = tmp_count;
		mutex_unlock(&susfs_hide_lock);
		goto out;
	}

	ret = -EINVAL;

free_tmp:
	for (i = 0; i < SUSFS_HIDE_MAX_PREFIXES; i++)
		kfree(tmp[i]);
out:
	kfree(buf);
	return ret;
}

static const struct proc_ops susfs_hide_prefixes_proc_ops = {
	.proc_open	= susfs_hide_prefixes_open,
	.proc_read	= seq_read,
	.proc_write	= susfs_hide_prefixes_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/*
 * 用 d_path 拿到挂载点绝对路径再比前缀。d_path 只拿 rename_lock 的 seqlock，不睡眠；
 * buffer 放栈上（512B）而不是每次 kmalloc：/proc/self/mounts 一次要过几百个挂载，
 * 每个都分配一次会把这条读路径的成本抬上去。路径超过 buffer 时 d_path 返回
 * -ENAMETOOLONG，按"没命中"处理（挂载点路径极少超过 256 字节）。
 */
bool susfs_mount_prefix_hidden(struct vfsmount *mnt)
{
	struct path path;
	char buf[SUSFS_HIDE_PREFIX_LEN * 2];
	char *p;
	int i;
	bool hidden = false;

	if (!mnt || !READ_ONCE(hidden_mount_prefix_count))
		return false;

	path.mnt = mnt;
	path.dentry = mnt->mnt_root;
	p = d_path(&path, buf, sizeof(buf));
	if (IS_ERR(p))
		return false;

	mutex_lock(&susfs_hide_lock);
	for (i = 0; i < hidden_mount_prefix_count; i++) {
		size_t len = strlen(hidden_mount_prefixes[i]);

		if (!strncmp(p, hidden_mount_prefixes[i], len)) {
			hidden = true;
			break;
		}
	}
	mutex_unlock(&susfs_hide_lock);

	if (hidden)
		atomic_long_inc(&mount_line_hits);
	return hidden;
}
EXPORT_SYMBOL_GPL(susfs_mount_prefix_hidden);
#endif /* CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX */

static int __init susfs_hide_init(void)
{
#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
	if (!proc_create("susfs_hide_modules", 0600, NULL, &susfs_hide_modules_proc_ops))
		pr_warn("susfs_hide: /proc/susfs_hide_modules 创建失败\n");
	else
		pr_info("susfs_hide: /proc/susfs_hide_modules 就绪\n");
#endif
#ifdef CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX
	mutex_lock(&susfs_hide_lock);
	susfs_hide_prefixes_reset_locked();
	mutex_unlock(&susfs_hide_lock);
	if (!proc_create("susfs_hide_mounts", 0600, NULL, &susfs_hide_prefixes_proc_ops))
		pr_warn("susfs_hide: /proc/susfs_hide_mounts 创建失败\n");
	else
		pr_info("susfs_hide: /proc/susfs_hide_mounts 就绪（默认前缀 /data/adb/ /data/local/tmp/）\n");
#endif
	return 0;
}

static void __exit susfs_hide_exit(void)
{
#ifdef CONFIG_KSU_SUSFS_HIDE_MODULES
	remove_proc_entry("susfs_hide_modules", NULL);
	mutex_lock(&susfs_hide_lock);
	susfs_hide_modules_clear_locked();
	mutex_unlock(&susfs_hide_lock);
#endif
#ifdef CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX
	remove_proc_entry("susfs_hide_mounts", NULL);
	mutex_lock(&susfs_hide_lock);
	susfs_hide_prefixes_clear_locked();
	mutex_unlock(&susfs_hide_lock);
#endif
}

/*
 * 用 late_initcall 而不是等 SUSFS 驱动来调：/proc 节点属于内核侧基础设施，
 * 驱动没起来也应该在（hidemod 这类工具不依赖 KSU 是否就绪）。
 */
late_initcall(susfs_hide_init);
module_exit(susfs_hide_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("SUSFS hidden modules / mount prefixes");
