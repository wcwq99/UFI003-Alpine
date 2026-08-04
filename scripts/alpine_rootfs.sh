#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

validate_work_dir() {
    candidate=$(readlink -m -- "$1")
    case "$candidate" in
        "$ROOT_DIR"/*) ;;
        *)
            echo "ERROR: refusing build directory outside repository: $candidate" >&2
            exit 1
            ;;
    esac
    if [ "$candidate" = "$ROOT_DIR" ]; then
        echo "ERROR: refusing to use repository root as a build directory" >&2
        exit 1
    fi
    printf '%s\n' "$candidate"
}

CHROOT=$(validate_work_dir "${CHROOT:-$ROOT_DIR/rootfs}")
HOST_NAME=${HOST_NAME:-OpenStick}
RELEASE=${RELEASE:-v3.24}
PMOS_RELEASE=${PMOS_RELEASE:-v25.12}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
PMOS_MIRROR=${PMOS_MIRROR:-https://mirror.postmarketos.org/postmarketos}
APK_STATIC_URL=${APK_STATIC_URL:-https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.6/x86_64/apk.static}
APK_STATIC_SHA256=${APK_STATIC_SHA256:-f1489e05bace7d7dd0a687fcd38d50b585ac660af4231668b123649bef3718c4}
DEVICE=${DEVICE:-ufi003}
USER_NAME=${USER_NAME:-user}
USER_PASSWORD=${USER_PASSWORD:-openstick}
export CHROOT

case "$USER_NAME:$USER_PASSWORD" in
    *:*:*)
        echo "ERROR: USER_NAME and USER_PASSWORD may not contain ':'" >&2
        exit 1
        ;;
esac

rm -rf -- "$CHROOT"
mkdir -p "$CHROOT/etc/apk"
cat > "$CHROOT/etc/apk/repositories" <<EOF
$MIRROR/$RELEASE/main
$MIRROR/$RELEASE/community
@pmos $PMOS_MIRROR/$PMOS_RELEASE
EOF

cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
mkdir -p "$CHROOT/usr/bin"
QEMU_AARCH64=$(command -v qemu-aarch64-static)
cp "$QEMU_AARCH64" "$CHROOT/usr/bin/qemu-aarch64-static"

if [ ! -s apk.static ]; then
    wget -q -O apk.static.tmp "$APK_STATIC_URL"
    mv apk.static.tmp apk.static
    chmod 0755 apk.static
fi
printf '%s  %s\n' "$APK_STATIC_SHA256" apk.static | sha256sum -c -

# This is the one trust bootstrap: apk.static installs Alpine's packaged keys.
./apk.static add -p "$CHROOT" --initdb -U --arch aarch64 \
    --allow-untrusted alpine-base

# postmarketos-keys is the equivalent trust bootstrap for the pmos repository.
chroot "$CHROOT" ash -l -c '
apk add --allow-untrusted postmarketos-keys@pmos
apk add \
    android-tools \
    bridge-utils \
    chrony \
    dbus \
    dropbear \
    e2fsprogs-extra \
    eudev \
    gadget-tool \
    iptables \
    iw \
    msm-firmware-loader@pmos \
    networkmanager \
    networkmanager-cli \
    networkmanager-dnsmasq \
    networkmanager-tui \
    networkmanager-wifi \
    networkmanager-wwan \
    openrc \
    rmtfs \
    shadow \
    sudo \
    udev-init-scripts \
    udev-init-scripts-openrc \
    wireguard-tools \
    wireguard-tools-wg-quick \
    wireless-regdb
rm -f /etc/fstab
command -v fastboot >/dev/null
command -v NetworkManager >/dev/null
'

chroot "$CHROOT" ash -l -c "
adduser -D -s /bin/ash '$USER_NAME'
passwd -l root
addgroup -S dnsmasq
adduser -S -D -H -h /dev/null -s /sbin/nologin -G dnsmasq -g dnsmasq dnsmasq

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add udev-postmount default
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add local default
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown
rc-update add dropbear default
rc-update add rmtfs default
rc-update add networkmanager default
rc-update add networkmanager-dispatcher default
rc-update add wpa_supplicant default
"
printf '%s:%s\n' "$USER_NAME" "$USER_PASSWORD" | chroot "$CHROOT" chpasswd

printf '%s ALL=(ALL:ALL) ALL\n' "$USER_NAME" > "$CHROOT/etc/sudoers.d/$USER_NAME"
chmod 0440 "$CHROOT/etc/sudoers.d/$USER_NAME"

# Root SSH is disabled. Dropbear generates unique host keys on first boot.
mkdir -p "$CHROOT/etc/dropbear"
rm -f "$CHROOT"/etc/dropbear/dropbear_*_host_key
sed -i 's/^DROPBEAR_OPTS=.*/DROPBEAR_OPTS="-w"/' "$CHROOT/etc/conf.d/dropbear"

# Serial access remains available, but through a real login prompt.
sed -i '/^ttyMSM0:/d' "$CHROOT/etc/inittab"
printf 'ttyMSM0::respawn:/sbin/getty -L 115200 ttyMSM0 vt100\n' >> "$CHROOT/etc/inittab"
printf '%s\n' "$HOST_NAME" > "$CHROOT/etc/hostname"
sed -i "/localhost/ s/\$/ $HOST_NAME/" "$CHROOT/etc/hosts"

# NetworkManager and its profiles come from the same pinned Alpine release as
# the rest of the rootfs; do not splice in libraries from another release.
PROFILE_DIR="$CHROOT/etc/NetworkManager/system-connections"
mkdir -p "$PROFILE_DIR"
cp configs/*.nmconnection "$PROFILE_DIR/"
chmod 0600 "$PROFILE_DIR"/*.nmconnection

cp -a configs/templates "$CHROOT/etc/gt"
install -m 0755 scripts/setup_ncm_gadget.sh "$CHROOT/usr/local/bin/setup_ncm_gadget.sh"
install -m 0755 scripts/reboot-fastboot.sh "$CHROOT/usr/local/bin/reboot-fastboot"

cat > "$CHROOT/etc/init.d/openstick-usb" <<'EOF'
#!/sbin/openrc-run
description="OpenStick NCM/RNDIS USB network gadget"

depend() {
    need localmount
    after modules
    before networkmanager
}

start() {
    ebegin "Starting OpenStick USB network gadget"
    mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config
    modprobe libcomposite 2>/dev/null || true
    /usr/local/bin/setup_ncm_gadget.sh
    eend $?
}

stop() {
    ebegin "Stopping OpenStick USB network gadget"
    if [ -d /sys/kernel/config/usb_gadget/openstick ]; then
        printf '\n' > /sys/kernel/config/usb_gadget/openstick/UDC 2>/dev/null || true
    fi
    eend 0
}
EOF
chmod 0755 "$CHROOT/etc/init.d/openstick-usb"
chroot "$CHROOT" rc-update add openstick-usb default

cat > "$CHROOT/etc/udev/rules.d/99-nm-usb.rules" <<'EOF'
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

PREBUILT="prebuilt/$DEVICE"
if [ ! -d "$PREBUILT/modules" ] || [ ! -d "$PREBUILT/firmware" ]; then
    echo "ERROR: kernel modules or firmware are missing under $PREBUILT" >&2
    exit 1
fi
mkdir -p "$CHROOT/lib/modules" "$CHROOT/lib/firmware"
cp -a "$PREBUILT/modules/." "$CHROOT/lib/modules/"
cp -a "$PREBUILT/firmware/." "$CHROOT/lib/firmware/"
for kver_dir in "$PREBUILT"/modules/*; do
    [ -d "$kver_dir" ] || continue
    kver=${kver_dir##*/}
    chroot "$CHROOT" depmod "$kver"
done
mkdir -p "$CHROOT/etc/modules-load.d"
printf 'qcom_wcnss_pil\n' > "$CHROOT/etc/modules-load.d/wcnss.conf"

mkdir -p "$CHROOT/etc/local.d"
cat > "$CHROOT/etc/local.d/resize-rootfs.start" <<'EOF'
#!/bin/sh
ROOT_DEV=$(awk '$2 == "/" {print $1}' /proc/mounts)
if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
    resize2fs "$ROOT_DEV" >/var/log/resize-rootfs.log 2>&1 || true
    rm -f /etc/local.d/resize-rootfs.start
fi
EOF
chmod 0755 "$CHROOT/etc/local.d/resize-rootfs.start"

# Force machine-id and SSH host-key generation to be device-specific.
rm -f "$CHROOT/etc/machine-id"

rm -f alpine_rootfs.tgz
tar cpzf alpine_rootfs.tgz \
    --exclude='./root/*' \
    --exclude='./newroot' \
    --exclude='./usr/bin/qemu-aarch64-static' \
    -C "$CHROOT" .

if [ ! -s alpine_rootfs.tgz ]; then
    echo "ERROR: rootfs archive was not created" >&2
    exit 1
fi
