#!/bin/sh
# Reboot device into fastboot mode by writing "boot-fastboot" to the misc
# partition's boot message command field. The patched lk1st (see
# src/lk2nd app/aboot/recovery.c) reads this on boot and enters fastboot
# instead of booting the kernel.
#
# Usage: reboot-fastboot
# After running, device reboots into fastboot (USB PID 0x0308 or similar).

set -eu

# find misc partition by label
MISC_DEV=$(ls /dev/disk/by-partlabel/misc 2>/dev/null || true)
if [ -z "$MISC_DEV" ]; then
    # fallback: search by blkid
    MISC_DEV=$(blkid -t PARTLABEL=misc -o device 2>/dev/null | head -1)
fi
if [ -z "$MISC_DEV" ]; then
    echo "ERROR: misc partition not found" >&2
    exit 1
fi
echo "misc partition: $MISC_DEV"

# lk reads a 32-byte command from page 1 of misc. Clear the complete field so a
# previous, longer value cannot remain after the terminating NUL.
dd if=/dev/zero of="$MISC_DEV" bs=1 seek=512 count=32 conv=notrunc 2>/dev/null
printf 'boot-fastboot\000' | dd of="$MISC_DEV" bs=1 seek=512 conv=notrunc 2>/dev/null
sync

echo "Rebooting into fastboot..."
sync
sleep 1
reboot -f
