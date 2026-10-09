#!/usr/bin/env python3
"""Standalone Omanotch bar updates must be backup-safe without FullPanel."""
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "bar/apply-patch.py"
spec = importlib.util.spec_from_file_location("omanotch_bar_patch", MODULE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StandaloneWriteTests(unittest.TestCase):
    def test_backup_mode_symlink_idempotence(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "actual.qml"
            target.write_text("original\n")
            target.chmod(0o640)
            link = Path(directory) / "Bar.qml"
            link.symlink_to(target.name)
            with patch.object(module, "fullpanel_module", return_value=None):
                module.write_patch(link, "original\n", "changed\n")
                module.write_patch(link, "changed\n", "changed\n")
            self.assertTrue(link.is_symlink())
            self.assertEqual(target.read_text(), "changed\n")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
            backups = list(Path(directory).glob("actual.qml.omanotch-backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), "original\n")

    def test_failed_replace_preserves_clone_and_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "Bar.qml"
            target.write_text("original\n")
            with (patch.object(module, "fullpanel_module", return_value=None),
                  patch.object(module.os, "replace", side_effect=OSError("simulated failure"))):
                with self.assertRaisesRegex(OSError, "simulated failure"):
                    module.write_patch(target, "original\n", "changed\n")
            self.assertEqual(target.read_text(), "original\n")
            self.assertEqual(len(list(target.parent.glob("Bar.qml.omanotch-backup-*"))), 1)
            self.assertEqual(list(target.parent.glob(".Bar.qml.omanotch-*")), [])

    def test_concurrent_edit_is_rejected_without_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "Bar.qml"
            target.write_text("user edit\n")
            with patch.object(module, "fullpanel_module", return_value=None):
                with self.assertRaises(ValueError):
                    module.write_patch(target, "outdated\n", "patched\n")
            self.assertEqual(target.read_text(), "user edit\n")
            self.assertEqual(len(list(target.parent.iterdir())), 1)


if __name__ == "__main__":
    unittest.main()
