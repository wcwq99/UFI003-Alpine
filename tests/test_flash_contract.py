import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class FlashContractTests(unittest.TestCase):
    def setUp(self):
        self.script = (REPO_ROOT / "flash-alpine.ps1").read_text()
        self.wrapper = (REPO_ROOT / "flash-alpine.bat").read_text()

    def test_full_flash_backs_up_calibration_before_gpt(self):
        for partition in ("cdt", "sec", "fsc", "fsg", "modemst1", "modemst2"):
            self.assertIn(f'"{partition}"', self.script)
        self.assertIn('Invoke-Fastboot @("oem", "dump", $Partition)', self.script)
        self.assertIn('Invoke-Fastboot @("get_staged", $Destination)', self.script)
        self.assertLess(
            self.script.index("Backup-CalibrationPartitions"),
            self.script.index('Invoke-Fastboot @("flash", "partition"'),
        )

    def test_modes_and_generated_aboot_are_explicit(self):
        self.assertIn('ValidateSet("SystemOnly", "Full")', self.script)
        self.assertIn('"aboot.mbn"', self.script)
        self.assertNotIn('"aboot.bin"', self.script)
        self.assertIn('Invoke-Fastboot @("-S", "200m", "flash", "rootfs"', self.script)

    def test_fastboot_wait_is_implemented_without_invalid_command(self):
        self.assertIn("Wait-OneFastbootDevice", self.script)
        self.assertIn("Expected exactly one fastboot device", self.script)
        self.assertNotIn("wait-for-devices", self.script)

    def test_fastboot_commands_use_device_serial(self):
        self.assertIn("$script:DeviceSerial", self.script)
        self.assertIn('@("-s", $script:DeviceSerial)', self.script)

    def test_paths_and_hashes_are_fail_closed(self):
        self.assertIn("$PSScriptRoot", self.script)
        self.assertIn("SHA256SUMS", self.script)
        self.assertIn("Get-FileHash", self.script)
        self.assertIn("ConfirmFullFlash", self.script)

    def test_batch_file_is_only_a_powershell_launcher(self):
        self.assertIn("%~dp0flash-alpine.ps1", self.wrapper)
        self.assertNotIn("fastboot flash", self.wrapper.lower())


if __name__ == "__main__":
    unittest.main()
