#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

LK2ND_COMPATIBLE=${LK2ND_COMPATIBLE:-zhihe,various}
LK2ND_DTB=${LK2ND_DTB:-msm8916-512mb-mtp.dtb}
PATCH_FILE=patches/lk2nd-boot-fastboot.patch
PROJECT_FILE=src/lk2nd/project/lk1st-msm8916.mk
HS200_DEFINE='DEFINES += USE_TARGET_HS200_CAPS=1'

for directory in src/qhypstub src/qtestsign src/lk2nd; do
    if [ ! -d "$directory" ]; then
        echo "ERROR: missing submodule $directory; run git submodule update --init --recursive" >&2
        exit 1
    fi
done

make -C src/qhypstub CROSS_COMPILE=aarch64-linux-gnu-

# Some recycled eMMC parts are unreliable at the default high-speed setting.
# Keep this idempotent so repeated local builds do not mutate the submodule.
grep -qxF "$HS200_DEFINE" "$PROJECT_FILE" || printf '%s\n' "$HS200_DEFINE" >> "$PROJECT_FILE"

if patch -p1 -d src/lk2nd --forward --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
    patch -p1 -d src/lk2nd --forward < "$PATCH_FILE"
elif patch -p1 -d src/lk2nd --reverse --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
    echo "lk2nd boot-fastboot patch already applied"
else
    echo "ERROR: $PATCH_FILE does not apply to the pinned lk2nd submodule" >&2
    exit 1
fi

# lk1st is the final aboot implementation. zhihe,various covers UFI003_MB and
# related MSM8916 modem sticks while the boot image supplies its exact DTB.
make -C src/lk2nd \
    LK2ND_BUNDLE_DTB="$LK2ND_DTB" \
    LK2ND_COMPATIBLE="$LK2ND_COMPATIBLE" \
    TOOLCHAIN_PREFIX=arm-none-eabi- \
    lk1st-msm8916

# A normal lk2nd boot image is shipped only as a temporary maintenance image.
# The Windows flasher uses it to dump device-specific calibration partitions
# before changing GPT, then restores the real boot image.
make -C src/lk2nd \
    LK2ND_BUNDLE_DTB="$LK2ND_DTB" \
    TOOLCHAIN_PREFIX=arm-none-eabi- \
    lk2nd-msm8916

mkdir -p files
src/qtestsign/qtestsign.py hyp src/qhypstub/qhypstub.elf -o files/hyp.mbn
src/qtestsign/qtestsign.py aboot \
    src/lk2nd/build-lk1st-msm8916/emmc_appsboot.mbn \
    -o files/aboot.mbn
cp src/lk2nd/build-lk2nd-msm8916/lk2nd.img files/lk2nd.img

for output in files/hyp.mbn files/aboot.mbn files/lk2nd.img; do
    if [ ! -s "$output" ]; then
        echo "ERROR: expected build output is missing: $output" >&2
        exit 1
    fi
done
