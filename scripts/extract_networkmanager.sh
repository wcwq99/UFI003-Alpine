#!/bin/sh -e

export BASE=${CHROOT}/newroot
export RELEASE=v3.20
# China mirror
export MIRROR=${MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine}

rm -rf ${BASE}

mkdir -p ${BASE}/etc/apk
cat << EOF > ${BASE}/etc/apk/repositories
${MIRROR}/${RELEASE}/main
${MIRROR}/${RELEASE}/community
EOF

# apk.static runs post-install scripts in a chroot; copy qemu-aarch64-static so
# binfmt_misc can find the interpreter inside the chroot.
mkdir -p ${BASE}/usr/bin
cp $(which qemu-aarch64-static) ${BASE}/usr/bin/

./apk.static add --arch aarch64 -p ${BASE} --initdb -U --allow-untrusted \
    alpine-base \
    musl-utils \
    networkmanager-cli \
    networkmanager-dnsmasq \
    networkmanager-tui \
    networkmanager-wifi \
    networkmanager-wwan \
    wpa_supplicant

mkdir -p ${BASE}/new/etc

# ensure target dirs exist in CHROOT (alpine_rootfs.sh may not have installed polkit/dbus)
mkdir -p ${CHROOT}/usr/share/dbus-1/system-services
mkdir -p ${CHROOT}/usr/share/dbus-1/system.d
mkdir -p ${CHROOT}/usr/share/polkit-1/actions
mkdir -p ${CHROOT}/usr/share/polkit-1/rules.d

cp ${BASE}/usr/share/dbus-1/system-services/*nm* ${CHROOT}/usr/share/dbus-1/system-services
cp ${BASE}/usr/share/dbus-1/system-services/*wp* ${CHROOT}/usr/share/dbus-1/system-services
cp ${BASE}/usr/share/dbus-1/system.d/nm*	 ${CHROOT}/usr/share/dbus-1/system.d
cp ${BASE}/usr/share/dbus-1/system.d/*Net*	 ${CHROOT}/usr/share/dbus-1/system.d
cp ${BASE}/usr/share/dbus-1/system.d/wpa*	 ${CHROOT}/usr/share/dbus-1/system.d
cp ${BASE}/usr/share/polkit-1/actions/*Net*	 ${CHROOT}/usr/share/polkit-1/actions
cp ${BASE}/usr/share/polkit-1/rules.d/*Net*	 ${CHROOT}/usr/share/polkit-1/rules.d

mkdir -p ${BASE}/new/etc/conf.d
mkdir -p ${BASE}/new/etc/init.d

cp ${BASE}/etc/NetworkManager    ${BASE}/new/etc -a
cp ${BASE}/etc/init.d/networkma* ${BASE}/new/etc/init.d

cp ${BASE}/etc/conf.d/wpa*    ${BASE}/new/etc/conf.d
cp ${BASE}/etc/init.d/wpa*    ${BASE}/new/etc/init.d
cp ${BASE}/etc/wpa_supplicant ${BASE}/new/etc/ -a

cat << EOF > ${BASE}/new/etc/NetworkManager/conf.d/any-user.conf
[main]
auth-polkit=false
EOF

files="
    networkmanager
    networkmanager-dispatcher
    wpa_cli
    wpa_supplicant
"
for f in ${files}; do
    sed '/^description/a \\nchroot="\/usr/local"' -i ${BASE}/new/etc/init.d/${f}
done

# mount points and update fstab
dirs="
    /dev
    /lib/modules
    /proc
    /run
    /sys
"
for d in ${dirs}; do
    mkdir -p ${BASE}/new${d}
    echo "${d}\t/usr/local${d}\tnone\tbind" >> ${CHROOT}/etc/fstab
done
echo >> ${CHROOT}/etc/fstab

mkdir -p ${BASE}/new/var
ln -s ../run ${BASE}/new/var/

# extract files running in chroot env

chroot ${BASE} ash -l -c '
files="
    /sbin/eapol_test
    /sbin/modprobe
    /sbin/wpa_cli
    /sbin/wpa_passphrase
    /sbin/wpa_supplicant
    /usr/bin/nm-online
    /usr/bin/nmcli
    /usr/bin/nmtui
    /usr/bin/nmtui-connect
    /usr/bin/nmtui-edit
    /usr/bin/nmtui-hostname
    /usr/sbin/NetworkManager
    /usr/sbin/dnsmasq
    /usr/libexec/nm-cloud-setup
    /usr/libexec/nm-daemon-helper
    /usr/libexec/nm-dhcp-helper
    /usr/libexec/nm-dispatcher
    /usr/libexec/nm-priv-helper
    /usr/lib/NetworkManager/1.46.6/libnm-wwan.so
"
for f in ${files}; do
    target_dir=/new$(dirname ${f})
    mkdir -p ${target_dir}
    cp ${f} ${target_dir}
    ldd ${f} 2>/tmp/nul | grep -o "/[^\ ]*" | while read -r lib; do
        if [ -f ${lib} ]; then
	    lib_dir=/new$(dirname ${lib})
	    mkdir -p ${lib_dir}
	    cp ${lib} ${lib_dir}
	fi
    done
done

cp /usr/lib/NetworkManager/ -a /new/usr/lib
'

cp -a ${BASE}/new/* ${CHROOT}/usr/local

# add chroot helper script
cat << EOF > ${CHROOT}/usr/local/bin/chroot.sh
#!/bin/sh
BIN=\${0##*/}

if [ "\${BIN}" = "chroot.sh" ]; then
    echo "Usage: link to this script to execute the chrooted program"
    exit 1
fi

unshare -mr chroot /usr/local \${BIN} \$@
EOF
chmod a+x ${CHROOT}/usr/local/bin/chroot.sh

# populate resolv
echo "nameserver 8.8.8.8" > ${CHROOT}/usr/local/etc/resolv.conf
