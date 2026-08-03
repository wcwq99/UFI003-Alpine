#!/bin/sh -e

# Sets up a composite USB gadget exposing both NCM and RNDIS network interfaces.
# NCM is preferred by Linux/macOS; RNDIS is needed for older Windows auto-detect.
# Both share the same usb0 interface and MAC, the host picks whichever it prefers.

CONFIGFS="/sys/kernel/config/usb_gadget"
NAME="openstick"

DIR="${CONFIGFS}/${NAME}"

NCM_HOST_ADDR="2a:85:da:41:eb:f9"
NCM_DEV_ADDR="8a:b1:27:16:8e:a7"
RNDIS_HOST_ADDR="2a:85:da:41:eb:fa"
RNDIS_DEV_ADDR="8a:b1:27:16:8e:a8"

[ -d "${CONFIGFS}" ] || { echo "USB Gadget configfs entry missing!"; exit 1; }
[ -d "${DIR}" ] && { echo "USB Gadget already configured"; exit 0; }

# create gadget entry
mkdir -p "${DIR}/functions/ncm.1" "${DIR}/functions/rndis.0"

# setup
echo "0x0200"        > "${DIR}/bcdUSB"          # USB 2.0
echo "0x0104"        > "${DIR}/idProduct"       # Multifunction Composite Gadget
echo "0x1d6b"        > "${DIR}/idVendor"        # Linux Foundation
echo "0x40"          > "${DIR}/bMaxPacketSize0" # 64 bytes

mkdir -p "${DIR}/strings/0x409"
echo "4G LTE Dongle" > "${DIR}/strings/0x409/product"
echo "Openstick"     > "${DIR}/strings/0x409/manufacturer"
echo "0123456789"    > "${DIR}/strings/0x409/serialnumber"

# setup config
mkdir "${DIR}/configs/c.1"

echo "0x80" > "${DIR}/configs/c.1/bmAttributes" # bus powered
echo "250"  > "${DIR}/configs/c.1/MaxPower"     # 500 mA

# setup NCM
echo "${NCM_HOST_ADDR}" > "${DIR}/functions/ncm.1/host_addr"
echo "${NCM_DEV_ADDR}"  > "${DIR}/functions/ncm.1/dev_addr"

# setup RNDIS (different MAC to avoid conflict)
echo "${RNDIS_HOST_ADDR}" > "${DIR}/functions/rndis.0/host_addr"
echo "${RNDIS_DEV_ADDR}"  > "${DIR}/functions/rndis.0/dev_addr"
# RNDIS uses a different interface class so Windows auto-binds usbnet/rndis
echo "0xef" > "${DIR}/functions/rndis.0/bInterfaceClass"

# Enable use of OS descriptors
# This enables windows 10/11 to auto load drivers
echo "MSFT100" > "${DIR}/os_desc/qw_sign"
echo "0xbc"    > "${DIR}/os_desc/b_vendor_code"
echo "1"       > "${DIR}/os_desc/use"

# gt templates cannot set these values
echo "WINNCM"  > "${DIR}/functions/ncm.1/os_desc/interface.ncm/compatible_id"
echo "NCM"     > "${DIR}/functions/ncm.1/os_desc/interface.ncm/sub_compatible_id"

# RNDIS OS descriptor (so Windows loads RNDIS driver automatically)
echo "RNDIS"   > "${DIR}/functions/rndis.0/os_desc/interface.rndis/compatible_id"
echo "5162001" > "${DIR}/functions/rndis.0/os_desc/interface.rndis/sub_compatible_id"

# Windows extension to use IAD (Interface Association Descriptor)
echo "0x0100" > "${DIR}/bcdDevice"
echo "0x01"   > "${DIR}/bDeviceProtocol"
echo "0x02"   > "${DIR}/bDeviceSubClass"
echo "0xef"   > "${DIR}/bDeviceClass"

# activate both functions
ln -s "${DIR}/functions/ncm.1"    "${DIR}/configs/c.1"
ln -s "${DIR}/functions/rndis.0" "${DIR}/configs/c.1"
ln -s "${DIR}/configs/c.1" "${DIR}/os_desc"
echo $(ls /sys/class/udc) > "${DIR}/UDC"
