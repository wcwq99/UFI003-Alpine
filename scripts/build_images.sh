#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

DEVICE=${DEVICE:-ufi003}
PREBUILT="prebuilt/$DEVICE"
RAW_IMAGE="$ROOT_DIR/rootfs.raw"
MOUNT_DIR="$ROOT_DIR/mnt"
MOUNTED=0

unmount_rootfs() {
    [ "$MOUNTED" -eq 1 ] || return 0
    sync
    if command -v fusermount3 >/dev/null 2>&1; then
        fusermount3 -u "$MOUNT_DIR" 2>/dev/null || umount "$MOUNT_DIR"
    elif command -v fusermount >/dev/null 2>&1; then
        fusermount -u "$MOUNT_DIR" 2>/dev/null || umount "$MOUNT_DIR"
    else
        umount "$MOUNT_DIR"
    fi
    MOUNTED=0
}

cleanup() {
    unmount_rootfs || true
    rm -f -- "$RAW_IMAGE"
}
trap cleanup EXIT INT TERM

if [ ! -s alpine_rootfs.tgz ]; then
    echo "ERROR: alpine_rootfs.tgz is missing; run alpine_rootfs.sh first" >&2
    exit 1
fi
if [ ! -s "$PREBUILT/boot.img" ]; then
    echo "ERROR: matched UFI003 boot image is missing: $PREBUILT/boot.img" >&2
    exit 1
fi

mkdir -p files "$MOUNT_DIR"
cp "$PREBUILT/boot.img" files/boot.bin

# 1.5 GiB fits the supported UFI003 storage profile and remains sparse on disk.
rm -f -- "$RAW_IMAGE"
truncate -s 1610612736 "$RAW_IMAGE"
mkfs.ext4 -F -L rootfs "$RAW_IMAGE"

if command -v fuse2fs >/dev/null 2>&1; then
    fuse2fs -o fakeroot "$RAW_IMAGE" "$MOUNT_DIR"
else
    mount -o loop "$RAW_IMAGE" "$MOUNT_DIR"
fi
MOUNTED=1

tar xpf alpine_rootfs.tgz -C "$MOUNT_DIR" \
    --exclude='./root/*' \
    --exclude='./dev/*'
unmount_rootfs

e2fsck -fn "$RAW_IMAGE"
img2simg "$RAW_IMAGE" files/alpine_rootfs.bin
if [ ! -s files/alpine_rootfs.bin ]; then
    echo "ERROR: sparse rootfs image was not created" >&2
    exit 1
fi
