#!/bin/sh
set -eu

# Composite USB networking for the UFI003 5.15 kernel. ADB FunctionFS is not
# exposed because Alpine's android-tools package provides clients (including
# fastboot) but no adbd daemon. An unserved FunctionFS function prevents the
# complete gadget from binding.

CONFIGFS=/sys/kernel/config/usb_gadget
NAME=openstick
DIR="$CONFIGFS/$NAME"

NCM_HOST_ADDR=2a:85:da:41:eb:f9
NCM_DEV_ADDR=8a:b1:27:16:8e:a7
RNDIS_HOST_ADDR=2a:85:da:41:eb:fa
RNDIS_DEV_ADDR=8a:b1:27:16:8e:a8

cleanup_gadget() {
    [ -d "$DIR" ] || return 0
    printf '\n' > "$DIR/UDC" 2>/dev/null || true
    rm -f "$DIR/configs/c.1/ncm.1" "$DIR/configs/c.1/rndis.0" \
        "$DIR/os_desc/c.1" 2>/dev/null || true
    rmdir "$DIR/functions/ncm.1" "$DIR/functions/rndis.0" 2>/dev/null || true
    rmdir "$DIR/configs/c.1/strings/0x409" 2>/dev/null || true
    rmdir "$DIR/configs/c.1" 2>/dev/null || true
    rmdir "$DIR/strings/0x409" 2>/dev/null || true
    rmdir "$DIR" 2>/dev/null || true
    if [ -d "$DIR" ]; then
        echo "ERROR: could not clean existing USB gadget state" >&2
        return 1
    fi
}

[ -d "$CONFIGFS" ] || {
    echo "ERROR: USB gadget configfs is not mounted" >&2
    exit 1
}
cleanup_gadget

mkdir "$DIR"
mkdir -p "$DIR/functions/ncm.1" "$DIR/functions/rndis.0"

printf '0x0200\n' > "$DIR/bcdUSB"
printf '0x0104\n' > "$DIR/idProduct"
printf '0x1d6b\n' > "$DIR/idVendor"
printf '0x40\n' > "$DIR/bMaxPacketSize0"

mkdir -p "$DIR/strings/0x409"
printf '4G LTE Dongle\n' > "$DIR/strings/0x409/product"
printf 'OpenStick\n' > "$DIR/strings/0x409/manufacturer"
SERIAL=$(tr -cd 'A-Za-z0-9' < /etc/machine-id 2>/dev/null | cut -c1-32 || true)
[ -n "$SERIAL" ] || SERIAL=OpenStick-UFI003
printf '%s\n' "$SERIAL" > "$DIR/strings/0x409/serialnumber"

mkdir "$DIR/configs/c.1"
printf '0x80\n' > "$DIR/configs/c.1/bmAttributes"
printf '250\n' > "$DIR/configs/c.1/MaxPower"

printf '%s\n' "$NCM_HOST_ADDR" > "$DIR/functions/ncm.1/host_addr"
printf '%s\n' "$NCM_DEV_ADDR" > "$DIR/functions/ncm.1/dev_addr"
printf '%s\n' "$RNDIS_HOST_ADDR" > "$DIR/functions/rndis.0/host_addr"
printf '%s\n' "$RNDIS_DEV_ADDR" > "$DIR/functions/rndis.0/dev_addr"
printf '0xef\n' > "$DIR/functions/rndis.0/class"

printf 'MSFT100\n' > "$DIR/os_desc/qw_sign"
printf '0xbc\n' > "$DIR/os_desc/b_vendor_code"
printf '1\n' > "$DIR/os_desc/use"
printf 'WINNCM\n' > "$DIR/functions/ncm.1/os_desc/interface.ncm/compatible_id"
printf 'NCM\n' > "$DIR/functions/ncm.1/os_desc/interface.ncm/sub_compatible_id"
printf 'RNDIS\n' > "$DIR/functions/rndis.0/os_desc/interface.rndis/compatible_id"
printf '5162001\n' > "$DIR/functions/rndis.0/os_desc/interface.rndis/sub_compatible_id"

printf '0x0100\n' > "$DIR/bcdDevice"
printf '0x01\n' > "$DIR/bDeviceProtocol"
printf '0x02\n' > "$DIR/bDeviceSubClass"
printf '0xef\n' > "$DIR/bDeviceClass"

ln -s "$DIR/functions/ncm.1" "$DIR/configs/c.1/ncm.1"
ln -s "$DIR/functions/rndis.0" "$DIR/configs/c.1/rndis.0"
ln -s "$DIR/configs/c.1" "$DIR/os_desc/c.1"

BOUND=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    UDC_DEV=$(ls /sys/class/udc 2>/dev/null | head -1 || true)
    if [ -n "$UDC_DEV" ] && printf '%s\n' "$UDC_DEV" > "$DIR/UDC" 2>/dev/null; then
        echo "USB gadget bound to $UDC_DEV"
        BOUND=1
        break
    fi
    echo "USB gadget bind attempt $attempt failed; retrying"
    sleep 1
done

if [ "$BOUND" -ne 1 ]; then
    echo "ERROR: USB gadget could not bind to a UDC" >&2
    cleanup_gadget || true
    exit 1
fi
