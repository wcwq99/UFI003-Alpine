#!/bin/sh -e

make -C src/qhypstub CROSS_COMPILE=aarch64-linux-gnu-

# patch to reduce mmc speed as some boards have intermittent failures when
# inititalizing the mmc (maybe due to using old/recycled flash chips)
echo 'DEFINES += USE_TARGET_HS200_CAPS=1' >> src/lk2nd/project/lk1st-msm8916.mk

# apply our boot-fastboot patch (src/lk2nd is a read-only submodule of the
# upstream msm8916-mainline repo, so the change ships as a patch here)
if [ -f patches/lk2nd-boot-fastboot.patch ]; then
    if ! patch -p1 -d src/lk2nd --dry-run < patches/lk2nd-boot-fastboot.patch >/dev/null 2>&1; then
        echo "WARNING: lk2nd patch does not apply cleanly (already applied?), skipping"
    else
        patch -p1 -d src/lk2nd < patches/lk2nd-boot-fastboot.patch
        echo "Applied lk2nd-boot-fastboot.patch"
    fi
fi

make -C src/lk2nd LK2ND_BUNDLE_DTB="msm8916-512mb-mtp.dtb" LK2ND_COMPATIBLE="yiming,uz801-v3" \
    TOOLCHAIN_PREFIX=arm-none-eabi- lk1st-msm8916

# test sign
mkdir -p files
src/qtestsign/qtestsign.py hyp src/qhypstub/qhypstub.elf \
    -o files/hyp.mbn
src/qtestsign/qtestsign.py aboot src/lk2nd/build-lk1st-msm8916/emmc_appsboot.mbn \
    -o files/aboot.mbn
