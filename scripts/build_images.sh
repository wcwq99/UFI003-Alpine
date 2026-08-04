#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
DEVICE=${DEVICE=ufi003}
PREBUILT=prebuilt/${DEVICE}

# package rootfs
rm -f rootfs.raw
mkdir -p files mnt

# CRITICAL: do NOT regenerate boot.img. The boot.img from the original flashing
# pack is paired with the prebuilt kernel modules we copied into the rootfs.
# Regenerating boot.img would mismatch the kernel and break module loading.
# Just copy the original boot.img verbatim to files/boot.bin
BOOT_SRC="${PREBUILT}/boot.img"
if [ -f "${BOOT_SRC}" ]; then
    cp "${BOOT_SRC}" files/boot.bin
    echo "Using original boot.img from flashing pack: ${BOOT_SRC}"
else
    echo "ERROR: boot.img not found at ${BOOT_SRC}" >&2
    exit 1
fi

# create root img (ext4, 1.5GB to match the original partition size)
truncate -s 1610612736 rootfs.raw
mkfs.ext4 -F rootfs.raw
mkdir -p mnt
# Use fuse2fs if available (works in containers without /dev/loop*),
# otherwise fall back to a loop mount.
if command -v fuse2fs >/dev/null 2>&1; then
    fuse2fs -o fakeroot rootfs.raw mnt
    tar xpf alpine_rootfs.tgz -C mnt --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'
    umount mnt
else
    mount -o loop rootfs.raw mnt
    tar xpf alpine_rootfs.tgz -C mnt --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'
    umount mnt
fi

# create sparse android image (fastboot flash -S 200m compatible)
img2simg rootfs.raw files/alpine_rootfs.bin

# clean up
rm -f rootfs.raw boot.raw
