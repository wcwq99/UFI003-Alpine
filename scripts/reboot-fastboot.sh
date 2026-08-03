#!/bin/sh
# Reboot device into fastboot mode by writing "bootloader\n" to the misc
# partition's boot message field. lk1st reads this on boot and enters
# fastboot instead of booting the kernel.
#
# Usage: reboot-fastboot
# After running, device reboots into fastboot (USB PID 0x0308 or similar).

set -e

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

# lk1st reads the first 32 bytes of misc as the boot message
printf 'bootloader\n' | dd of="$MISC_DEV" bs=1 count=32 conv=notrunc 2>/dev/null
sync

echo "Rebooting into fastboot..."
sync
sleep 1
reboot -f
