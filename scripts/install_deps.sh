#!/bin/sh -e

apt update
apt install -y \
    android-sdk-libsparse-utils \
    binfmt-support \
    device-tree-compiler \
    e2fsprogs \
    fdisk \
    fuse2fs \
    gcc-aarch64-linux-gnu \
    gcc-arm-none-eabi \
    make \
    patch \
    python3 \
    python3-cryptography \
    python3-pyasn1-modules \
    python3-pycryptodome \
    qemu-user-static \
    unzip \
    wget

# Register qemu-aarch64-static with binfmt_misc so we can chroot into the
# aarch64 rootfs on the x86_64 build host. This is REQUIRED or every chroot
# command fails with "Exec format error".
update-binfmts --enable qemu-aarch64 2>/dev/null || true
# binfmt-support may not ship a ready entry for qemu-aarch64; register manually
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo ':qemu-aarch64:M::\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' > /proc/sys/fs/binfmt_misc/register
    fi
fi
echo "binfmt qemu-aarch64 registered: $(ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | tr '\n' ' ')"
