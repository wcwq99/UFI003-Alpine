import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class RuntimeContractTests(unittest.TestCase):
    def test_usb_gadget_has_network_only_and_checked_udc_binding(self):
        script = (REPO_ROOT / "scripts" / "setup_ncm_gadget.sh").read_text()

        self.assertNotIn("functions/ffs.adb", script)
        self.assertNotIn("/usr/bin/adbd", script)
        self.assertIn("functions/ncm.1", script)
        self.assertIn("functions/rndis.0", script)
        self.assertIn('if [ "$BOUND" -ne 1 ]', script)

    def test_usb_interfaces_are_bridge_members(self):
        bridge = (REPO_ROOT / "configs" / "usb-bridge.nmconnection").read_text()
        ncm = (REPO_ROOT / "configs" / "usb.nmconnection").read_text()
        rndis = (REPO_ROOT / "configs" / "usb-rndis.nmconnection").read_text()

        self.assertIn("type=bridge", bridge)
        self.assertIn("address1=192.168.5.1/24", bridge)
        for profile in (ncm, rndis):
            self.assertIn("port-type=bridge", profile)
            self.assertIn("method=disabled", profile)
            self.assertNotIn("address1=192.168.5.1/24", profile)

    def test_known_wifi_password_is_not_exposed_by_default(self):
        hotspot = (REPO_ROOT / "configs" / "hotspot.nmconnection").read_text()

        self.assertIn("autoconnect=false", hotspot)

    def test_rootfs_has_fastboot_but_no_fake_adb_or_dead_boot_mount(self):
        script = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()

        self.assertIn("android-tools", script)
        self.assertIn("command -v fastboot", script)
        self.assertNotIn("rc-update add adbd", script)
        self.assertNotIn("/dev/mmcblk0p14", script)
        self.assertNotIn("configs/extlinux.conf", script)

    def test_reboot_fastboot_uses_a_terminated_misc_command(self):
        script = (REPO_ROOT / "scripts" / "reboot-fastboot.sh").read_text()

        self.assertIn("count=32", script)
        self.assertIn("boot-fastboot\\000", script)
        self.assertIn("seek=512", script)
        self.assertNotIn("by-partlabel/boot", script)

    def test_rootfs_does_not_ship_shared_keys_or_passwordless_root_console(self):
        script = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()

        self.assertNotIn("dropbearkey", script)
        self.assertNotIn("ttyMSM0::respawn:/bin/sh", script)
        self.assertIn("/sbin/getty -L 115200 ttyMSM0", script)
        self.assertIn('DROPBEAR_OPTS=""', script)
        self.assertNotIn("NOPASSWD", script)

    def test_rootfs_build_parameters_cannot_inject_root_shell_commands(self):
        script = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()

        self.assertIn("USER_NAME contains unsupported characters", script)
        self.assertIn("USER_PASSWORD must contain printable single-line ASCII", script)
        self.assertIn("HOST_NAME is not a valid single-label hostname", script)
        self.assertIn("echo \"root:password\" | chpasswd", script)
        self.assertNotIn("addgroup -S dnsmasq", script)

    def test_destructive_build_directories_are_guarded(self):
        rootfs = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()

        self.assertIn("validate_work_dir", rootfs)
        self.assertIn('rm -rf -- "$CHROOT"', rootfs)

    def test_networkmanager_is_not_mixed_across_alpine_releases(self):
        script = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()

        self.assertIn("networkmanager-dnsmasq", script)
        self.assertIn('PROFILE_DIR="$CHROOT/etc/NetworkManager/system-connections"', script)
        self.assertNotIn("extract_networkmanager.sh", script)
        self.assertNotIn("$CHROOT/usr/local/etc/NetworkManager", script)


if __name__ == "__main__":
    unittest.main()
