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

    def test_rootfs_has_fastboot_but_no_fake_adb_or_dead_boot_mount(self):
        script = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()

        self.assertIn("android-tools", script)
        self.assertIn("command -v fastboot", script)
        self.assertNotIn("rc-update add adbd", script)
        self.assertNotIn("/dev/mmcblk0p14", script)
        self.assertNotIn("configs/extlinux.conf", script)

    def test_rootfs_does_not_ship_shared_keys_or_passwordless_root_console(self):
        script = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()

        self.assertNotIn("dropbearkey", script)
        self.assertNotIn("ttyMSM0::respawn:/bin/sh", script)
        self.assertIn("/sbin/getty -L 115200 ttyMSM0", script)
        self.assertIn('DROPBEAR_OPTS="-w"', script)
        self.assertNotIn("NOPASSWD", script)

    def test_destructive_build_directories_are_guarded(self):
        rootfs = (REPO_ROOT / "scripts" / "alpine_rootfs.sh").read_text()
        networkmanager = (
            REPO_ROOT / "scripts" / "extract_networkmanager.sh"
        ).read_text()

        self.assertIn("validate_work_dir", rootfs)
        self.assertIn('rm -rf -- "$CHROOT"', rootfs)
        self.assertIn("validate_work_dir", networkmanager)
        self.assertIn('rm -rf -- "$BASE"', networkmanager)


if __name__ == "__main__":
    unittest.main()
