#!/bin/sh -e

export CHROOT=${CHROOT=$(pwd)/rootfs}
export HOST_NAME=${HOST_NAME=OpenStick}
export RELEASE=${RELEASE=v3.24}
export PMOS_RELEASE=${PMOS_RELEASE=v25.12}
# China mirrors for faster download
export MIRROR=${MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine}
export PMOS_MIRROR=${PMOS_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/postmarketOS}
export APK_STATIC_URL=https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.6/x86_64/apk.static
export DEVICE=${DEVICE=ufi003}
export ROOT_PASSWORD=${ROOT_PASSWORD=password}

rm -rf ${CHROOT}

mkdir -p ${CHROOT}/etc/apk
cat << EOF >  ${CHROOT}/etc/apk/repositories
${MIRROR}/${RELEASE}/main
${MIRROR}/${RELEASE}/community
@pmos ${PMOS_MIRROR}/${PMOS_RELEASE}
EOF

cp /etc/resolv.conf ${CHROOT}/etc/

mkdir -p ${CHROOT}/usr/bin
cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

[ -e apk.static ] || { wget -q ${APK_STATIC_URL}; chmod a+x apk.static; }

./apk.static add -p ${CHROOT} --initdb -U --arch aarch64 --allow-untrusted alpine-base

# install apps
# NOTE: do NOT install linux-postmarketos-qcom-msm8916@pmos -- we use the prebuilt
# 5.15 kernel from the UFI003 boot.img, and the matching modules come from prebuilt/.
# Also skip modemmanager (no SIM card needed).
chroot ${CHROOT} ash -l -c "
apk add --allow-untrusted postmarketos-keys@pmos
apk add \
    android-tools \
    bridge-utils \
    chrony \
    dropbear \
    dbus \
    e2fsprogs-extra \
    eudev \
    gadget-tool \
    iptables \
    msm-firmware-loader@pmos \
    openrc \
    rmtfs \
    shadow \
    sudo \
    udev-init-scripts \
    udev-init-scripts-openrc \
    wireguard-tools \
    wireguard-tools-wg-quick \
    wireless-regdb \
    iw

# clear
rm /etc/fstab
"

# extract NetworkManager from previous alpine version (v3.20)
sh scripts/extract_networkmanager.sh

# setup alpine
chroot ${CHROOT} ash -l -c "
# set root password
echo 'root:${ROOT_PASSWORD}' | chpasswd

# create user (no password, sudo only). adduser -D = no password, disabled.
adduser -D -s /bin/ash user

# update users used by chrooted apps
addgroup -S dnsmasq
adduser -S -D -H -h /dev/null -s /sbin/nologin -G dnsmasq -g dnsmasq dnsmasq

# sync
ln /etc/group    /usr/local/etc
ln /etc/passwd   /usr/local/etc
ln /etc/hostname /usr/local/etc

ln -sf /usr/local/etc/resolv.conf /etc

# add symlinks
for a in nm-online nmcli nmtui nmtui-connect nmtui-edit nmtui-hostname; do
    ln -s /usr/local/bin/chroot.sh /usr/bin/${a};
done

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
# adbd OpenRC service comes from the android-tools package; enable it so ADB
# starts at boot. The setup_ncm_gadget.sh udev rule also starts adbd as a
# fallback when the USB gadget is configured.
rc-update add adbd default 2>/dev/null || true
rc-update add wpa_supplicant default
"
echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > ${CHROOT}/etc/sudoers.d/user

# SSH: dropbear is the default SSH server on Alpine; it allows root login if
# root has a password (set above). No sshd_config changes needed.
# Pre-generate dropbear host keys on the build host so first boot doesn't block
# on entropy (dropbear openrc would generate them otherwise).
mkdir -p ${CHROOT}/etc/dropbear
for keytype in rsa ecdsa ed25519; do
    keyfile=${CHROOT}/etc/dropbear/dropbear_${keytype}_host_key
    [ -f "$keyfile" ] || dropbearkey -t $keytype -f "$keyfile" 2>/dev/null || \
        echo "warning: dropbearkey $keytype failed (will generate on first boot)"
done

# add udev rules
cat << EOF > ${CHROOT}/etc/udev/rules.d/10-udc.rules
ACTION=="add", SUBSYSTEM=="udc", RUN+="/sbin/modprobe libcomposite", RUN+="/usr/local/bin/setup_ncm_gadget.sh"
EOF

cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# enable autologin on console
sed -i '/^tty/ s/^/#/' ${CHROOT}/etc/inittab
echo 'ttyMSM0::respawn:/bin/sh' >> ${CHROOT}/etc/inittab

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/usr/local/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/usr/local/etc/NetworkManager/system-connections/*
ln -s ../usr/local/etc/NetworkManager ${CHROOT}/etc/NetworkManager

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
mkdir -p ${CHROOT}/boot/dtbs/qcom
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# update fstab
echo "/dev/mmcblk0p14\t/boot\text2\tdefaults\t0 2" >> ${CHROOT}/etc/fstab

# copy gadget-tool templates and script
cp -a configs/templates ${CHROOT}/etc/gt
cp scripts/setup_ncm_gadget.sh ${CHROOT}/usr/local/bin
cp scripts/reboot-fastboot.sh ${CHROOT}/usr/local/bin

# === device-specific: copy prebuilt kernel modules + WiFi firmware ===
PREBUILT=prebuilt/${DEVICE}
if [ -d "${PREBUILT}" ]; then
    echo "Installing prebuilt kernel modules and firmware from ${PREBUILT}"

    # kernel modules -- directory name MUST match the kernel version string
    if [ -d "${PREBUILT}/modules" ]; then
        mkdir -p ${CHROOT}/lib/modules
        cp -a ${PREBUILT}/modules/* ${CHROOT}/lib/modules/
        # run depmod in chroot (use the modules' kernel version)
        for kver in $(ls ${PREBUILT}/modules); do
            chroot ${CHROOT} depmod ${kver} 2>/dev/null || \
                echo "warning: depmod failed for ${kver} (will run on first boot)"
        done
    fi

    # WiFi firmware
    if [ -d "${PREBUILT}/firmware" ]; then
        mkdir -p ${CHROOT}/lib/firmware
        cp -a ${PREBUILT}/firmware/. ${CHROOT}/lib/firmware/
    fi

    # auto-load qcom_wcnss_pil (WiFi driver)
    mkdir -p ${CHROOT}/etc/modules-load.d
    echo "qcom_wcnss_pil" > ${CHROOT}/etc/modules-load.d/wcnss.conf
fi

# first-boot resize2fs via local.d (rc-update add local default above)
mkdir -p ${CHROOT}/etc/local.d
cat << 'EOF' > ${CHROOT}/etc/local.d/resize-rootfs.start
#!/bin/sh
# Resize the rootfs partition to fill the disk on first boot.
ROOT_DEV=$(awk '$2 == "/" {print $1}' /proc/mounts)
if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
    PART=$(echo "$ROOT_DEV" | sed 's/.*p\([0-9]\+\)$/\1/')
    DISK=$(echo "$ROOT_DEV" | sed 's/p[0-9]\+$//')
    if [ -b "$DISK" ] && command -v growpart >/dev/null 2>&1; then
        growpart $DISK $PART 2>/dev/null || true
    fi
    resize2fs "$ROOT_DEV" 2>/dev/null || true
    # disable this script after first run
    rc-update del local default 2>/dev/null || true
    rm -f /etc/local.d/resize-rootfs.start
fi
EOF
chmod +x ${CHROOT}/etc/local.d/resize-rootfs.start

# backup rootfs
rm -f alpine_rootfs.tgz
tar cpzf alpine_rootfs.tgz \
    --exclude="root/*" \
    --exclude="newroot" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -C rootfs .
