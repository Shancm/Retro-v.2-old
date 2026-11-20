#!/usr/bin/env python3
"""Static regression tests for Retro OS live-boot full persistence."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FullPersistenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        engine = (ROOT / "scripts/01_engine_setup.sh").read_text()
        match = re.search(
            r"install_persistence_helper\(\) \{.*?<<'PERSISTENCE_EOF'\n(.*?)\nPERSISTENCE_EOF",
            engine,
            re.S,
        )
        if not match:
            raise AssertionError("Could not find embedded retro-persistence-setup helper")
        cls.helper = match.group(1)
        cls.build = (ROOT / "build.sh").read_text()
        cls.workflow = (ROOT / ".github/workflows/build-iso.yml").read_text()

    def test_full_union_persistence_configuration(self):
        self.assertIn("printf '/ union\\n'", self.helper)
        self.assertIn('label=persistence, / union', self.helper)

    def test_helper_only_accepts_existing_ext_partition(self):
        self.assertIn('[[ "$(lsblk -dnro TYPE -- "${device}")" == "part" ]]', self.helper)
        self.assertIn("ext2|ext3|ext4", self.helper)
        self.assertIn("It never creates partitions, formats filesystems", self.helper)

    def test_helper_protects_efi_partition(self):
        self.assertIn("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", self.helper)
        self.assertIn("EFI/Boot must remain untouched", self.helper)

    def test_helper_refuses_mounted_and_system_disk_partitions(self):
        self.assertIn("findmnt -rn -S", self.helper)
        self.assertIn("lsblk -s -nrpo NAME", self.helper)
        self.assertIn("currently running system disk", self.helper)

    def test_helper_does_not_silently_change_existing_label(self):
        self.assertIn("Refusing to change existing filesystem label", self.helper)
        self.assertIn('[[ "${current_label}" != "persistence" ]]', self.helper)

    def test_bios_and_uefi_persistence_boot_entries_exist(self):
        self.assertRegex(self.build, r"LABEL persistence[\\s\\S]{0,220}persistence quiet")
        self.assertRegex(self.build, r'menuentry "Retro OS Live - Persistence[\\s\\S]{0,220}persistence quiet')

    def test_live_boot_engine_is_installed(self):
        self.assertRegex(self.engine_source(), r"retro_apt_install initramfs-tools live-boot live-config")

    def engine_source(self):
        return (ROOT / "scripts/01_engine_setup.sh").read_text()


if __name__ == "__main__":
    unittest.main()
