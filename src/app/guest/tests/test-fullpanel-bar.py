#!/usr/bin/env python3
"""Offline unit/safety checks for the FullPanel QML transformation."""
import importlib.util
import pathlib
import tempfile
import unittest

MODULE = pathlib.Path(__file__).resolve().parent.parent / 'fullpanel-bar.py'
spec = importlib.util.spec_from_file_location('fullpanel_bar', MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FullPanelBarTests(unittest.TestCase):
    def setUp(self):
        self.source = '''import Quickshell
import Quickshell.Io
Item {
  id: root
  property string home: Quickshell.env("HOME")
'''+mod.NOTCH_FLOOR+'''    implicitHeight: root.vertical ? 0 : Math.max(root.barSize, notchFloor)
}
'''

    def test_adds_dynamic_height_without_touching_other_bar_settings(self):
        s = mod.patch_text(self.source)
        self.assertIn(mod.MARKER, s)
        self.assertIn('function fullPanelBarHeight(s)', s)
        self.assertIn('root.fullPanelBarHeight(screen)', s)
        self.assertIn('root.appleSiliconHost', s)
        self.assertIn('watchChanges: true', s)
        self.assertIn('OMACVM_FULLPANELWIDTH10', s)
        self.assertIn('OMACVM_FULLPANELBAR10', s)
        self.assertIn('return Math.ceil(logical)', s)
        self.assertIn('implicitHeight: root.vertical ? 0 : Math.max(root.barSize, notchFloor)', s)

    def test_idempotent(self):
        once = mod.patch_text(self.source)
        self.assertEqual(once, mod.patch_text(once))

    def test_rejects_upstream_notch_floor_change(self):
        with self.assertRaisesRegex(ValueError, 'notchFloor'):
            mod.patch_text(self.source.replace('readonly property int notchFloor', 'readonly property int macNotch'))

    def test_rejects_missing_anchor_without_partial_write(self):
        with self.assertRaisesRegex(ValueError, 'bar root'):
            mod.patch_text(self.source.replace(mod.HOME_ANCHOR, ''))

    def test_expected_scale_heights_on_verified_guest(self):
        # QScreen.width is logical; 3600 physical guest pixels / Hyprland
        # scale. Mac width=1800 points, menu-bar height=38 points.
        # This mirrors QML's width-ratio calculation, not font scaling.
        from math import ceil
        for scale, logical in [(1, 76), (1.25, 61), (1.6, 48),
                               (2, 38), (3, 26), (4, 19)]:
            qscreen_width = 3600 / scale
            got = ceil(380 * qscreen_width / 18000)
            self.assertEqual(got, logical, f"scale {scale}")

    def test_native_no_flag_and_external_screen_guard(self):
        new = mod.patch_text(self.source)
        self.assertIn('env.OMACVM_FULLPANEL === 1', new)
        self.assertIn('String(s.name) !== fullPanelBuiltin', new)
        self.assertIn('strip > 1 && strip < h * 0.06', new)


if __name__ == '__main__':
    unittest.main(verbosity=2)
