import shutil
import struct
import tempfile
import unittest
from pathlib import Path

from scripts import gpt
from scripts import validate_artifacts


REPO_ROOT = Path(__file__).resolve().parents[1]


class BuildContractTests(unittest.TestCase):
    def test_generated_bootloader_is_not_overwritten(self):
        build = (REPO_ROOT / "scripts" / "build_hyp_aboot.sh").read_text()
        extract = (REPO_ROOT / "scripts" / "extract_fw.sh").read_text()

        self.assertIn("files/aboot.mbn", build)
        self.assertIn("files/lk2nd.img", build)
        self.assertIn("lk2nd-msm8916", build)
        self.assertNotIn("aboot.bin hyp.mbn", extract)
        self.assertIn("scripts/gpt.py add-misc", extract)


class ArtifactValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.artifacts = Path(self.temp_dir.name)

        copies = {
            "gpt_both0.bin": "gpt_both0.bin",
            "hyp.mbn": "hyp.mbn",
            "rpm.mbn": "rpm.mbn",
            "sbl1.mbn": "sbl1.mbn",
            "tz.mbn": "tz.mbn",
            "boot.bin": "boot.img",
        }
        prebuilt = REPO_ROOT / "prebuilt" / "ufi003"
        for destination, source in copies.items():
            shutil.copyfile(prebuilt / source, self.artifacts / destination)
        gpt.add_misc_partition(self.artifacts / "gpt_both0.bin")

        # Structural stand-ins for outputs that are only available after the
        # cross-compiled build. Their formats are still validated here.
        shutil.copyfile(prebuilt / "aboot.bin", self.artifacts / "aboot.mbn")
        shutil.copyfile(prebuilt / "boot.img", self.artifacts / "lk2nd.img")
        sparse_header = struct.pack(
            "<IHHHHIIII", 0xED26FF3A, 1, 0, 28, 12, 4096, 1, 1, 0
        )
        dont_care_chunk = struct.pack("<HHII", 0xCAC3, 0, 1, 12)
        (self.artifacts / "alpine_rootfs.bin").write_bytes(
            sparse_header + dont_care_chunk
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_valid_matched_bundle_passes(self):
        report = validate_artifacts.validate_directory(self.artifacts)
        self.assertEqual(report["rootfs_partition"], "rootfs")
        self.assertEqual(report["root_partuuid"], report["gpt_rootfs_guid"])

    def test_mismatched_boot_root_partuuid_is_rejected(self):
        boot = self.artifacts / "boot.bin"
        data = boot.read_bytes()
        expected = b"a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"
        self.assertIn(expected, data[:2048])
        boot.write_bytes(data.replace(expected, b"0" * 36, 1))

        with self.assertRaisesRegex(validate_artifacts.ArtifactError, "PARTUUID"):
            validate_artifacts.validate_directory(self.artifacts)


if __name__ == "__main__":
    unittest.main()
