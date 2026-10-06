# CosmicFresh nabu 内核自编译指南

小米平板 5（nabu / hanoi）社区维护内核，基于 Xiaomi sm8150 4.14.325 源码。

- 已合并 [Droidspaces](../Droidspaces-OSS/Documentation/zh-CN/Kernel-Configuration.md) 容器支持配置（namespaces/cgroups/网络全套）
- 已集成 [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)（legacy 分支，Manual Hook 模式）

## 快速开始

```bash
./build-nabu.sh          # 一键：下载工具链 → defconfig → 编译 → 打包 zip
./build-nabu.sh -v R7    # 指定版本号
./build-nabu.sh -c       # 清理后全量重编
./build-nabu.sh -k       # 只重新打包（不重编）
```

产物：`CosmicFresh/CosmicFresh-<版本>-nabu[-ksu].zip`（AnyKernel3 格式，TWRP/自定义 recovery 刷入，A/B 分区自动处理）。

## 环境要求

- Linux x86_64（WSL2 可用），约 8GB 内存、15GB 磁盘
- `gcc bison flex zip cpio perl python3 libelf-dev libssl-dev`（Ubuntu: `sudo apt install build-essential bison flex zip cpio perl python3 libelf-dev libssl-dev`）
- 工具链：[KenHV Eva GCC](https://github.com/KenHV/gcc-arm64)（脚本自动下载到 `build-shit/`，内含 lld 18）

## KernelSU 集成说明

本仓库通过 symlink 引用外部 KernelSU-Next 仓库（git 不跟踪，脚本自动重建）：

```bash
# 前置：把 KernelSU-Next（legacy 分支）clone 到与本仓库平级
git clone https://github.com/KernelSU-Next/KernelSU-Next -b legacy ../KernelSU-Next
ln -sf ../../KernelSU-Next/kernel drivers/kernelsu   # 脚本也会自动做
```

### Manual Hook 模式

本内核 `CONFIG_MODULES` 关闭 → kprobes 不可用；4.14 无 pt_regs syscall ABI → syscall table hook 不可用。
因此使用 `CONFIG_KSU_MANUAL_HOOK`，手动 hook 已打在内核源码（均用 `#ifdef CONFIG_KSU_MANUAL_HOOK` 包裹）：

| 文件 | Hook 函数 | 作用 |
|------|-----------|------|
| `fs/exec.c` `do_execveat_common` | `ksu_handle_execveat` | su→ksud 重定向、ksud/zygote 识别 |
| `fs/open.c` `faccessat` | `ksu_handle_faccessat` | su 访问检查重定向 |
| `fs/stat.c` `newfstatat` | `ksu_handle_stat` | su stat 重定向 |
| `kernel/sys.c` `setresuid` | `ksu_handle_setresuid` | 识别 manager/授权 uid、安装 ioctl fd、umount |
| `kernel/reboot.c` `reboot` | `ksu_handle_sys_reboot` | supercall 通道（Kbuild 以此判定集成成功） |

### UAPI 版本 pin（重要）

`KernelSU-Next/uapi/supercall.h` 中 `KERNEL_SU_UAPI_VERSION` 已从 5 **pin 回 4**，配套 v3.4.0 release 的 manager APK（versionCode 33294）。
若换用更新版本的 manager/ksud（UAPI 5），把该值改回 5 重编即可。

### KSU Kbuild 自动 backport

编译时 KernelSU 的 Kbuild 会自动给内核源码打以下 backport（已提交进本仓库，无需手动处理）：
- `fs/namespace.c`：`can_umount`/`path_umount`（5.9+ API）
- `fs/internal.h`：对应声明
- `include/linux/seccomp.h`：`filter_count` 字段
- `security/selinux/*`：`selinux_cred()`/`selinux_inode()` inline 化

⚠️ 坑：全新 clone 后首次编译，backport 在 Kbuild 解析时才写入 `fs/namespace.c`，`out/fs/namespace.o` 可能未随之重编，链接报 `undefined symbol: path_umount`。**再跑一次 `./build-nabu.sh` 即可**（第二次 make 会检测到源码变化重编）。

## 已知定制点（相对上游）

1. `scripts/Makefile.lib` `cmd_mkdtimg` 用 python3（原 python2）；`scripts/dtc/libfdt/mkdtboimg.py` 已做 py3 兼容（xrange/bytes/bytearray）
2. `init/Kconfig`：删除 `CFS_BANDWIDTH` 的 `depends on !SCHED_WALT`（fair.c 自带两者共存实现，Droidspaces 需要 CFS_BANDWIDTH）
3. `kernel/cgroup/cgroup.c`：Droidspaces non-GKI 补丁 02（NOPREFIX 挂载下创建带子系统前缀的 kernfs 链接）
4. `nabu_defconfig`：Droidspaces 全套选项 + `CONFIG_KSU=y`
5. `security/commoncap.c` 中 `ANDROID_PARANOID_NETWORK` 的 `#ifdef` 悬空无定义（等效关闭），Droidspaces 要求即此

## 刷入与验证

```bash
# recovery 刷 zip，或：
adb reboot bootloader && fastboot flash boot_ab Image   # 需自行打包 boot.img

# 开机后验证：
adb shell uname -r                    # 4.14.325-CosmicFresh-...-R6
adb shell dmesg | grep -iE "kernelsu|ksu_"   # KSU 初始化日志
adb shell su -c id                    # manager 授权 shell 后应输出 uid=0
```

KernelSU Manager 使用 v3.4.0 release APK（`KernelSU_Next_v3.4.0_33294-release.apk`），首次打开需在 SuperUser 页授权。
