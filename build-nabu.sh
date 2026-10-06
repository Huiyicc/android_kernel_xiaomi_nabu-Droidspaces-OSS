#!/bin/bash
# CosmicFresh nabu 内核一键编译脚本
# 用法:
#   ./build-nabu.sh              # 完整流程：defconfig -> 编译 -> 打包 AnyKernel zip
#   ./build-nabu.sh -k           # 跳过编译（沿用 out/ 已有产物）仅重新打包
#   ./build-nabu.sh -c           # 清理 out/ 后全量重编
#   ./build-nabu.sh -v <ver>     # 指定版本号（默认 R6，如 -v R7）
#   ./build-nabu.sh -h           # 帮助
#
# 依赖: build-shit/ 下的 Eva GCC 工具链（首次运行自动下载），python3, zip
# KernelSU 集成依赖 ../KernelSU-Next 仓库（legacy 分支），缺 symlink 时自动重建
set -e

cd "$(dirname "$0")"
ROOT=$(pwd)

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---- 参数解析 ----
KV="R6"; SKIP_BUILD=0; DO_CLEAN=0
while getopts "kcv:h" opt; do
    case $opt in
        k) SKIP_BUILD=1 ;;
        c) DO_CLEAN=1 ;;
        v) KV="$OPTARG" ;;
        h|*) usage ;;
    esac
done

# ---- 工具链 ----
TOOLCHAIN=$ROOT/build-shit
if [ ! -d "$TOOLCHAIN/gcc-arm64/bin" ]; then
    echo "==> 首次运行：下载 Eva GCC 工具链到 build-shit/ ..."
    mkdir -p "$TOOLCHAIN" && cd "$TOOLCHAIN"
    [ -d gcc-arm64 ] || git clone https://github.com/KenHV/gcc-arm64.git --single-branch -b master --depth=1
    [ -d gcc-arm   ] || git clone https://github.com/KenHV/gcc-arm.git   --single-branch -b master --depth=1
    cd "$ROOT"
fi
export PATH="$TOOLCHAIN/gcc-arm64/bin:$TOOLCHAIN/gcc-arm/bin:$PATH"
command -v aarch64-elf-gcc >/dev/null || { echo "E: 工具链不可用"; exit 1; }

# ---- KernelSU symlink 检查 ----
# drivers/kernelsu -> ../../KernelSU-Next/kernel（仓库外，git 不跟踪）
if [ ! -e drivers/kernelsu/core/init.c ]; then
    echo "W: drivers/kernelsu 失效，重建 symlink ..."
    ln -sfn ../../KernelSU-Next/kernel drivers/kernelsu
    [ -e drivers/kernelsu/core/init.c ] || { echo "E: KernelSU-Next 仓库不在 ../KernelSU-Next，请先执行: git clone https://github.com/Huiyicc/KernelSU-Next -b legacy ../KernelSU-Next"; exit 1; }
fi

# ---- 环境变量 ----
export KBUILD_BUILD_USER=Const KBUILD_BUILD_HOST=Coccinelle ARCH=arm64
JOBS=$(($(nproc)+1))
MAKE_ARGS=(
    O=out -j$JOBS
    CROSS_COMPILE=aarch64-elf- CROSS_COMPILE_ARM32=arm-eabi-
    HOSTCC=gcc HOSTCXX=aarch64-elf-g++
    CC=aarch64-elf-gcc LD=ld.lld
    LOCALVERSION="-CosmicFresh-$KV"
)

# ---- 可选清理 ----
if [ $DO_CLEAN -eq 1 ]; then
    echo "==> 清理 out/"
    rm -rf out
fi

if [ $SKIP_BUILD -eq 0 ]; then
    # KernelSU Kbuild 会在解析时给 fs/namespace.c 打 path_umount backport。
    # 如果源码已含补丁则 touch 无害；如果这是全新 clone（补丁未打），首次
    # defconfig+编译时 Kbuild 自动打上，但 namespace.o 可能没随之重编——
    # 链接报 "undefined symbol: path_umount" 时再跑一次本脚本即可。
    echo "==> defconfig"
    make "${MAKE_ARGS[@]}" nabu_defconfig
    echo "==> 编译（-j$JOBS）"
    if ! make "${MAKE_ARGS[@]}" > /tmp/nabu-build.log 2>&1; then
        echo "E: 编译失败，最后 30 行日志："
        tail -30 /tmp/nabu-build.log
        exit 1
    fi
    grep -qE "error:" /tmp/nabu-build.log && { echo "E: 日志中有 error"; grep -E "error:" /tmp/nabu-build.log | head; exit 1; }
    echo "（完整日志: /tmp/nabu-build.log）"
fi

IMAGE=out/arch/arm64/boot/Image
[ -f "$IMAGE" ] || { echo "E: 未找到 $IMAGE"; exit 1; }
strings "$IMAGE" | grep -m1 "Linux version"

# ---- 打包 ----
echo "==> 打包 AnyKernel zip"
cd CosmicFresh
cp ../out/arch/arm64/boot/Image .
cp ../out/arch/arm64/boot/dtbo.img .
cp ../out/arch/arm64/boot/dtb.img dtb
KSU_TAG=""; grep -q "^CONFIG_KSU=y" ../out/.config && KSU_TAG="-ksu"
OUT_ZIP="CosmicFresh-$KV-nabu$KSU_TAG.zip"
zip -r9 "$OUT_ZIP" META-INF version anykernel.sh tools Image dtb dtbo.img >/dev/null
rm -rf Image dtb dtbo.img
echo "============================================================"
echo " 完成: CosmicFresh/$OUT_ZIP"
echo " 通过 TWRP/自定义 recovery 刷入（A/B 分区自动处理）"
echo "============================================================"
