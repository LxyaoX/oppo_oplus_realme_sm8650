# 欧加真 SM8650/MT6989/MT6897 系列通用6.1内核自动化编译脚本
[![STAR](https://img.shields.io/github/stars/cctv18/oppo_oplus_realme_sm8650?style=flat&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyByb2xlPSJpbWciIHZpZXdCb3g9IjAgMCAyNCAyNCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU%2BR2l0SHViPC90aXRsZT48cGF0aCBkPSJNMTIgLjI5N2MtNi42MyAwLTEyIDUuMzczLTEyIDEyIDAgNS4zMDMgMy40MzggOS44IDguMjA1IDExLjM4NS42LjExMy44Mi0uMjU4LjgyLS41NzcgMC0uMjg1LS4wMS0xLjA0LS4wMTUtMi4wNC0zLjMzOC43MjQtNC4wNDItMS42MS00LjA0Mi0xLjYxQzQuNDIyIDE4LjA3IDMuNjMzIDE3LjcgMy42MzMgMTcuN2MtMS4wODctLjc0NC4wODQtLjcyOS4wODQtLjcyOSAxLjIwNS4wODQgMS44MzggMS4yMzYgMS44MzggMS4yMzYgMS4wNyAxLjgzNSAyLjgwOSAxLjMwNSAzLjQ5NS45OTguMTA4LS43NzYuNDE3LTEuMzA1Ljc2LTEuNjA1LTIuNjY1LS4zLTUuNDY2LTEuMzMyLTUuNDY2LTUuOTMgMC0xLjMxLjQ2NS0yLjM4IDEuMjM1LTMuMjItLjEzNS0uMzAzLS41NC0xLjUyMy4xMDUtMy4xNzYgMCAwIDEuMDA1LS4zMjIgMy4zIDEuMjMuOTYtLjI2NyAxLjk4LS4zOTkgMy0uNDA1IDEuMDIuMDA2IDIuMDQuMTM4IDMgLjQwNSAyLjI4LTEuNTUyIDMuMjg1LTEuMjMgMy4yODUtMS4yMy42NDUgMS42NTMuMjQgMi44NzMuMTIgMy4xNzYuNzY1Ljg0IDEuMjMgMS45MSAxLjIzIDMuMjIgMCA0LjYxLTIuODA1IDUuNjI1LTUuNDc1IDUuOTIuNDIuMzYuODEgMS4wOTYuODEgMi4yMiAwIDEuNjA2LS4wMTUgMi44OTYtLjAxNSAzLjI4NiAwIC4zMTUuMjEuNjkuODI1LjU3QzIwLjU2NSAyMi4wOTIgMjQgMTcuNTkyIDI0IDEyLjI5N2MwLTYuNjI3LTUuMzczLTEyLTEyLTEyIiBmaWxsPSIjZmZmZmZmIj48L3BhdGg%2BPC9zdmc%2B)](https://github.com/cctv18/oppo_oplus_realme_sm8650/stargazers)
[![FORK](https://img.shields.io/github/forks/cctv18/oppo_oplus_realme_sm8650?style=flat&logo=greasyfork&color=%2394E61A)](https://github.com/cctv18/oppo_oplus_realme_sm8650/forks)
[![COOLAPK](https://img.shields.io/badge/cctv18_2-cctv18_2?style=flat&logo=android&logoColor=FF4500&label=%E9%85%B7%E5%AE%89&color=FF4500)](http://www.coolapk.com/u/22650293)
[![DISCUSSION](https://img.shields.io/badge/%E8%AE%A8%E8%AE%BA%E5%8C%BA-discussions?logo=livechat&logoColor=FFBBFF&color=3399ff)](https://github.com/cctv18/oppo_oplus_realme_sm8650/discussions)

<img alt="Endpoint Badge" src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fcctv18%2Fkernel-workshop%2Frefs%2Fheads%2Fhotfix%2Fnotice.json">

##### 
一个更方便、快捷的自动化OPPO/一加/真我系列骁龙8Gen3(SM8650)/天玑9400e(MT6989)/天玑8350(MT6897)机型的通用内核编译脚本。
##### 
这个项目的初衷是解决以下问题：
- 绿厂官方摆烂，代码开源开一半，导致部分内核代码无法通过已有的配置xml正常编译，甚至没有编译配置xml；
- 官方使用的 Bazel 编译器过于不稳定且低效，容易出现各种各样莫名其妙的错误，且全网几乎找不到任何有效解决方法，对于新手极不友好；
- 由于绿厂魔改内核f2fs代码，导致欧加真机型刷入GKI内核后不清空data分区就无法正常开机。
## 本项目的主要内容(及计划)
- 提供 OKI（官方源码）/ GKI（谷歌通用内核源码）双编译模式，OKI保留官方驱动/调度，GKI兼容性更强（无需相同内核小版本即可刷入）；
- 为 GKI 移植官方内核的f2fs源码，使 GKI 内核可以和官方 OKI 内核一样，刷入后可保留数据正常开机，不需要清空data ~~（新建文件夹）~~；
- 改用 LLVM/Clang 20 进行编译，并排除了官方源码中不必要的 vendor 源码参与，大幅优化编译流程，对比原 bazel 编译器缩短了近2/3的编译时间（原版官方编译器每次约需要超过1h才能完成编译），提高了编译过程的稳定性，输出日志更便于维护调试；
- 修复官方代码部分bug/未及时更新的补丁，并计划引入风驰内核支持；
- 提供 Github Action 在线编译/shell本地编译双版本脚本。
## 已实现：
- [x] 欧加真 SM8650 通用OKI内核（基于一加12 6.1.57/6.1.75/6.1.118 官方内核源码，其他同内核版本非SM8650机型可自行测试，部分机型可完全兼容）
- [x] 欧加真 MT6989 通用OKI内核（基于一加Ace5竞速版 6.1.115 官方内核源码，其他同内核版本非MT6989机型可自行测试，部分机型可完全兼容）
- [x] 欧加真 MT6897 通用OKI内核（基于一加平板 6.1.128 官方内核源码，其他同内核版本非MT6897机型可自行测试，部分机型可完全兼容）
- [x] ReSukiSU/SukiSU Ultra/KernelSU Next/FinaSU/原版KernelSU多版本KSU可选
- [x] 引入独家设计的 [ccache-ECS](https://github.com/cctv18/ccache-ECS) 缓存及大量编译流程优化，编译时间可稳定在约6min *(首次编译时会拉取公共预置ccache，从第二次开始没有大量配置改动的情况下，单次编译时间约6min；距离上一次调用两周未调用后缓存会被自动清除，此时编译会自动重建缓存)*
- [x] 引入O2编译优化，改善内核运行性能
- [x] ~~可选manual/kprobes/syscall钩子模式(kprobes钩子模式下支持切换至sus su模式)~~ 由于最新版KSU已更新inline hook，故旧版manual/syscall钩子已作废
- [x] lz4 1.10.0 & zstd 1.5.7 算法更新&优化补丁(来自[@ferstar](https://github.com/ferstar), 移植by [@Xiaomichael](https://github.com/Xiaomichael))
- [x] 可选加入 BBR/Brutal 及一系列 tcp 拥塞控制算法
- [x] 三星SSG IO调度器移植（目前已知仅在一加12上会导致无法正常启动，原因尚不明确，待进一步研究修复）
- [x] 加入一些网络功能拓展配置选项（用于为ipset及需要iptables等高级网络功能内核支持的程序提供支持）
- [x] Droidspaces 容器化支持（比传统 Docker/LXC 更轻量化，便于移植的完整 Linux 环境容器实现）
- [x] 添加了对[Mountify](https://github.com/backslashxx/mountify)模块的支持
- [x] 加入 ReKernel-X 支持（Binder / 信号 / 网络钩子），与 Freezer、NoActive 等软件配合降低功耗
- [x] FinaSU SUSFS Inline 后端（`CONFIG_KSU_HOOK_SUSFS_INLINE`，内核树直调入口替代 tracepoint/dispatcher/kprobe）
- [x] SUSFS 隐藏增强（`/proc/susfs_hide_modules` 模块名、`/proc/susfs_hide_mounts` 挂载前缀）
- [x] 网络全家桶（`net_opt` 五档：none / bbr / bbr-default / full / full-bbr3，含 BBRv3、IPSet、Qdisc、WireGuard、CIFS，从 AnyKernel3 移植）
- [x] 自定义构建时间（`build_time`，固定 `UTS_VERSION` 与 `KBUILD_BUILD_TIMESTAMP`，从 AnyKernel3 移植）
- [x] CVE-2026-43499 / CVE-2026-53163 rtmutex 修复链（从 AnyKernel3 移植，含 scoped_guard 兼容回移，工作流与本地脚本均可开关）
- [x] 加入内核防格基带保护(By [@showdo](https://github.com/showdo))，有效防止恶意格机脚本/程序对系统分区数据的破坏
## 维护
工作流是按版本参数生成的，**不要手改 `.github/workflows/fastbuild_6.1.*.yml`**（7 份只差版本号/源码包/机型，手改必漂移）：

```bash
# 改版本参数（源码包、机型、BPF 开关）或改公共步骤，都只动这两处：
#   data/builds.json            每版本参数
#   templates/fastbuild.yml.in  公共步骤（全部 7 个版本共用）
python3 scripts/sync_workflows.py            # 重新生成
python3 scripts/sync_workflows.py --check    # 只校验有没有漂移，漂移退出码 1

# 新增一个内核小版本：往 data/builds.json 加一条，跑一次 sync
```

补丁/集成逻辑在 `scripts/`（`apply_rekernel_x.sh`、`apply_susfs.sh`、`apply_susfs_inline.sh`、`apply_susfs_hide.sh`、`apply_net_enhance.sh`、`apply_build_time.sh`、`apply_finasu.sh`、`security_patch/`），
CI 与本地 `local/builder_*.sh` 调的是同一份，不要在 workflow 里内联重写。

**runner 钉在 `ubuntu-24.04`**（`renovate.json` 里已禁掉 runner 升级）：26.04 的 clang 把
`tools/lib/bpf/libbpf.c` 等老代码的 `-Wincompatible-pointer-types-discards-qualifiers`
当成错误（libbpf 的 Makefile 硬写 `override CFLAGS += -Werror`，`EXTRA_CFLAGS` 压不住），
构建会挂在 `tools/bpf/resolve_btfids`。`scripts/patch_toolchain_compat.sh` 已经修了已知那处，
真要升 runner 先把 tools 全量编译跑一遍。

## SUSFS Inline 后端（FinaSU）
`ksu_type=finasu` 且开启 susfs 时，默认走 FinaSU 的 Inline 后端（`CONFIG_KSU_HOOK_SUSFS_INLINE=y`）：syscall 由内核树里的直调入口处理，不注册通用 sys_enter tracepoint、dispatcher 和替换式 kprobe。开关是工作流的 `susfs_inline` 输入（本地 builder 问 `USE_SUSFS_INLINE`），关掉即回到 FinaSU 默认的 Tracepoint 后端。

依赖链是硬的，缺一环就编不过或静默回退：

| 环节 | 谁提供 | 缺了会怎样 |
|---|---|---|
| 内核树 12 个 `ksu_handle_*` 调用点 | `scripts/apply_susfs.sh`（ShirkNeko 50 补丁，`#ifdef CONFIG_KSU_SUSFS` 包裹） | 链接期 undefined symbol |
| 驱动侧同名入口 | FinaSU `kernel/extension/susfs.c`（`CONFIG_KSU_HOOK_SUSFS_INLINE` 分支） | 同上 |
| `KSU_SUSFS=y` + `KSU=y` | `scripts/apply_susfs_inline.sh` 兜底 | kconfig 把 inline 静默降级成 not set，后端实际还是 tracepoint |
| preinit 头文件 | `CONFIG_HEADERS_INSTALL=y`（finasu 自动改写） | `fs/exec.c` 的两个 preinit 入口缺失，检查直接失败 |

## SUSFS 隐藏增强（模块名 / 挂载前缀）
源码集成版（`CONFIG_KSU_SUSFS=y`）原本只有按 inode / `mnt_id` 标记的隐藏。按**模块名**和按**挂载前缀**
归类这两个能力只存在于 SUSFS-LKM（靠 kprobe / inline patch 实现），源码集成版没有。本仓库把这两个能力
补进内核树，接口格式与 LKM 一致：

```sh
# 模块名：从 /proc/modules 去掉该行，并过滤 /proc/kallsyms 里 [name] 结尾的行
echo "add mysusfs"            > /proc/susfs_hide_modules
echo "set mysusfs gadget"     > /proc/susfs_hide_modules   # 整份替换
echo "del mysusfs"            > /proc/susfs_hide_modules
echo clear                    > /proc/susfs_hide_modules
cat /proc/susfs_hide_modules  # 命中计数 + 当前名单

# 挂载前缀：决定 hide_sus_mnts_for_non_su_procs 生效时哪些挂载行对非 su 域不可见
echo "add /data/adb/"         > /proc/susfs_hide_mounts
echo "set /data/adb/ /data/local/tmp/" > /proc/susfs_hide_mounts
echo reset                    > /proc/susfs_hide_mounts   # 回到默认的两个前缀
echo clear                    > /proc/susfs_hide_mounts
cat /proc/susfs_hide_mounts
```

| 项 | 说明 |
|---|---|
| 编译开关 | `CONFIG_KSU_SUSFS_HIDE_MODULES`、`CONFIG_KSU_SUSFS_HIDE_MOUNT_PREFIX`（都 `depends on KSU_SUSFS`，默认 y） |
| 钩子位置 | `kernel/module/procfs.c:m_show`、`kernel/kallsyms.c:s_show`、`fs/proc_namespace.c` 三个 `susfs_show_*` |
| `/sys/module/<名字>` | 不在本功能内，用已有的 sus_path 规则隐藏（`ksu_susfs add_sus_path /sys/module/<名字>`） |
| 挂载前缀生效条件 | `hide_sus_mnts_for_non_su_procs` 打开时才对非 su 域隐藏；su 域本来读的是原始实现 |
| 性能 | 前缀判定每个挂载行一次 `d_path()`（栈上 512B），前缀表为空时直接返回；模块名判定每个模块一行一次 strcmp |
| 已知边界 | `/proc/modules` 只过滤行；别的模块 used-by 列里仍会带出被隐藏的名字 |

**管理器的 SUSFS 开关为什么还是灰的**：FinaSU 的 `ksud` 判定这两个能力时写死了 `implementation == "lkm"`
（`userspace/ksud/src/susfs/mod.rs:152` 的 `proc()`，以及 `:780` 的单元测试 `assert!(!builtin_capabilities.supported.contains(&"hidden_modules"))`），
而 `libksud.so` 随管理器 APK 分发、不在内核构建范围内。内核侧提供 `/proc` 节点后功能本身可用，
命令行/模块脚本直接写即可。反过来把内核伪装成 lkm 会连累 `full_clone`、`avc_spoof` 和整个页面变只读，不做。

## 网络全家桶（BBRv3 / Qdisc / WireGuard / CIFS）
从 AnyKernel3 移植。原来的三个开关（`bbr_enable` / `better_net` / `net_enhance`）已合并成一个 `net_opt`：

| `net_opt` | BBR | IPSet + nf | Qdisc / WireGuard / CIFS | 默认拥塞控制 |
|---|---|---|---|---|
| `none` | — | — | — | 内核默认 |
| `bbr` | BBR v1 | ✓ | — | `cubic` |
| `bbr-default` | BBR v1 | ✓ | — | `bbr` |
| `full`（默认） | BBRv3 | ✓ | ✓ | `cubic` |
| `full-bbr3` | BBRv3 | ✓ | ✓ | `bbr3` |

本地 builder 问 `网络功能(n/b/d/f/3)`，默认 `f`（full）。

| 块 | 内容 | 来源 |
|---|---|---|
| BBRv3 | `net/ipv4/tcp_bbr3.c` + `tcp_plb.c`（PLB 保护性负载均衡），`TCP_CONG_BBR3` / `DEFAULT_BBR3` | WildKernels/kernel_patches `common/bbrv3/0001-*-android14-6.1.patch` |
| IPSet | 16 种集合类型 + `IP_SET_MAX=65534` + netfilter 联动（addrtype / set / log / recent） | 与 `better_net` 同源，脚本里幂等重写 |
| Qdisc | `fq` / `fq_codel` / `cake` + `NET_ACT_CONNMARK` | AnyKernel3 |
| TTL/HopLimit | `IP_NF_TARGET_TTL` / `IP6_NF_TARGET_HL` / `IP6_NF_MATCH_HL` | AnyKernel3 |
| WireGuard | `CONFIG_WIREGUARD=y` | AnyKernel3 |
| CIFS | `CIFS` + `XATTR` / `POSIX` + `KEYS` + `NETWORK_FILESYSTEMS` | AnyKernel3 |

**BBR 版本从 v1 升到 v3**：`full` / `full-bbr3` 会把 BBRv3 算法编进去（`TCP_CONG_BBR3=y`），
`full-bbr3` 同时把默认算法设成 `bbr3`；`bbr` / `bbr-default` 走内核自带的 BBR v1。

补丁在厂商 6.1 树上实测 `patch -p1 --dry-run` rc=0，`net/ipv4/Kconfig`、`tcp_input.c` 等若干 hunk 靠 offset/fuzz 落位（LTS 合入上游 stable 会让上下文漂移）。砸不上时降级 BBR v1 并打 `::warning`，其余配置照常写，不挂掉整个构建。

与 AnyKernel3 的两点差异：
- CIFS=y 后 AnyKernel3 要去改 `modules.bzl`（bazel 模块清单会因为 netfs.ko 被内建而校验失败）；本仓库用 `make Image`，无此清单，不用改。
- 5.10 才需要的 `sysctl_add_proc_dou8vec_minmax` 前置补丁与 `add_tcp_snd_cwnd.py` 兼容脚本没搬：6.1 的 `include/net/tcp.h` 已有 `tcp_snd_cwnd()` accessors，厂商树实测 6 处。

## 自定义构建时间
从 AnyKernel3 移植。输入 `build_time`（默认空 = 当前时间），格式必须是 `Tue Dec  1 08:10:00 UTC 2026`：

```bash
gh workflow run "6.1.118 欧加真OKI内核快速构建" -R LxyaoX/oppo_oplus_realme_sm8650 \
  -f build_time="Tue Dec  1 08:10:00 UTC 2026"
```

脚本 `scripts/apply_build_time.sh` 做三件事：

1. 校验格式（星期与日期必须对得上，`date -d` 拒绝 2 月 30 日这类不存在的日期）
2. 导出 `KBUILD_BUILD_TIMESTAMP` / `KBUILD_BUILD_VERSION=1`
3. 往 `scripts/mkcompile_h` 的 heredoc 里写 `#define UTS_VERSION "#1 SMP PREEMPT <time>"`

第 3 步是必须的：厂商 OKI 树的 `mkcompile_h` 把上游那段 `UTS_VERSION` 删了，只留
`UTS_MACHINE` / `LINUX_COMPILE_BY` / `HOST` / `COMPILER`。只设 `KBUILD_BUILD_TIMESTAMP`
的话版本串里根本没有时间，开关等于没接线。脚本检测到没有这行就补一行，已有则替换。

本地 builder 问 `自定义构建时间`，脚本另落一份 `kernel_workspace/.build_time.env` 给父 shell
`source`（脚本进程内的 `export` 传不回去）。

## 待实现：
- [ ] zram内置化，无需外置zram.ko挂载 ~~（有了新版 lz4&zstd 补丁真的还有必要吗）~~
- [ ] Nethunter 网卡监听模式支持
- [ ] kexec 内核热切换支持
- [ ] 欧加真 6.1 通用 GKI内核（移植一加f2fs源码，实现免清data刷入）
- 更多优化与特性移植……
##### 
##### 
##### 
## 鸣谢
- ReSukiSU：[ReSukiSU/ReSukiSU](https://github.com/ReSukiSU/ReSukiSU)
- Sukisu Ultra：[SukiSU-Ultra/SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)
- susfs4ksu：[ShirkNeko/susfs4ksu](https://github.com/ShirkNeko/susfs4ksu)
- SukiSU内核补丁：[SukiSU-Ultra/SukiSU_patch](https://github.com/SukiSU-Ultra/SukiSU_patch)
- pershoot维护的KernelSU Next分支：[pershoot/KernelSU-Next](https://github.com/pershoot/KernelSU-Next)
- 手动钩子等补丁：[WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches)
- 原版KernelSU: [tiann/KernelSU](https://github.com/tiann/KernelSU)
- 内核防格基带保护模块：[vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)
- GKI 内核构建脚本：(待定)
- ~~本地化内核构建脚本（已失效）：[Suxiaoqinx/kernel_manifest_OnePlus_Sukisu_Ultra](https://github.com/Suxiaoqinx/kernel_manifest_OnePlus_Sukisu_Ultra)~~

<!-- 这是一个访客统计，用来看看我的项目主页有多少人访问过 -->
<div align="center">
  <img width="0" height="0" src="https://count.getloli.com/get/@:cctv18" />
</div>

