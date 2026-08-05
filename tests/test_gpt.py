import shutil
import tempfile
import unittest
import uuid
from pathlib import Path

from scripts import gpt


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_GPT = REPO_ROOT / "prebuilt" / "ufi003" / "gpt_both0.bin"


class GptMutationTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.gpt_path = Path(self.temp_dir.name) / "gpt_both0.bin"
        shutil.copyfile(SOURCE_GPT, self.gpt_path)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_add_misc_preserves_existing_layout_and_repairs_crcs(self):
        before = gpt.read_image(self.gpt_path)
        before_entries = {
            part.name: (part.type_guid, part.unique_guid, part.first_lba, part.last_lba)
            for part in before.partitions
        }

        changed = gpt.add_misc_partition(self.gpt_path)

        self.assertTrue(changed)
        after = gpt.read_image(self.gpt_path)
        gpt.validate_image(after)
        after_entries = {part.name: part for part in after.partitions}

        for name, expected in before_entries.items():
            actual = after_entries[name]
            self.assertEqual(
                (actual.type_guid, actual.unique_guid, actual.first_lba, actual.last_lba),
                expected,
            )

        misc = after_entries["misc"]
        self.assertNotEqual(misc.unique_guid, uuid.UUID(int=0))
        self.assertEqual(misc.first_lba, before_entries["fsg"][3] + 1)
        self.assertLess(misc.last_lba, before_entries["aboot"][2])
        self.assertEqual(misc.last_lba - misc.first_lba + 1, 2048)
        self.assertEqual(after.primary_table, after.backup_table)

    def test_add_misc_is_idempotent(self):
        self.assertTrue(gpt.add_misc_partition(self.gpt_path))
        first = self.gpt_path.read_bytes()

        self.assertFalse(gpt.add_misc_partition(self.gpt_path))

        self.assertEqual(self.gpt_path.read_bytes(), first)

    def test_validate_rejects_partition_table_crc_corruption(self):
        data = bytearray(self.gpt_path.read_bytes())
        data[2 * gpt.LBA_SIZE] ^= 0x01
        self.gpt_path.write_bytes(data)

        with self.assertRaisesRegex(gpt.GptError, "partition table CRC"):
            gpt.read_image(self.gpt_path)

    def test_normalize_fixes_backup_lba_and_last_usable(self):
        before = gpt.read_image(self.gpt_path)
        self.assertEqual(before.primary_header.backup_lba, 0,
                         "fixture should have zero backup_lba (fastboot format)")
        self.assertEqual(before.primary_header.last_usable_lba, 0,
                         "fixture should have zero last_usable")

        changed = gpt.normalize_image(self.gpt_path)
        self.assertTrue(changed, "normalize should report a change")

        after = gpt.read_image(self.gpt_path)
        expected_backup = after.backup_header.offset // gpt.LBA_SIZE
        self.assertEqual(after.primary_header.backup_lba, expected_backup)
        self.assertEqual(after.primary_header.last_usable_lba, expected_backup - 1)
        self.assertEqual(after.backup_header.current_lba, expected_backup)
        self.assertEqual(after.backup_header.last_usable_lba, expected_backup - 1)

    def test_normalize_is_idempotent(self):
        self.assertTrue(gpt.normalize_image(self.gpt_path))
        first = self.gpt_path.read_bytes()
        self.assertFalse(gpt.normalize_image(self.gpt_path))
        self.assertEqual(self.gpt_path.read_bytes(), first)


if __name__ == "__main__":
    unittest.main()
