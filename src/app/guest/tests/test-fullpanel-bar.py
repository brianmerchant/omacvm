#!/usr/bin/env python3
"""Offline transformation/geometry/migration checks for FullPanel Quickbar v2.

These do not replace an on-device Quickshell render or Swift AppKit test.
"""
import importlib.util
from math import ceil
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parent.parent / "fullpanel-bar.py"
spec = importlib.util.spec_from_file_location("fullpanel_bar", MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FullPanelBarTests(unittest.TestCase):
    def setUp(self):
        # This fixture reflects the relevant original clone anchor signatures.
        self.source = (
            'import Quickshell\nimport Quickshell.Io\nItem {\n'
            '  id: root\n'
            + mod.HOME_ANCHOR
            + mod.NOTCH_FLOOR
            + mod.OLD_HEIGHT
            + mod.HORIZONTAL_OLD
            + mod.EDGE_ANCHOR
            + '    entries: root.layoutEntries("left")\n  }\n}\n'
        )

    def test_adds_dynamic_height_bounds_and_single_widget_instance_per_side(self):
        s = mod.patch_text(self.source)
        self.assertIn(mod.MARKER, s)
        self.assertIn('function fullPanelBarHeight(s)', s)
        self.assertIn('function fullPanelBounds(s)', s)
        self.assertIn('function fullPanelSafeWidth(s, edge)', s)
        self.assertIn('root.fullPanelBarHeight(screen) > 0', s)
        self.assertIn('OMACVM_FULLPANELLEFT10', s)
        self.assertIn('OMACVM_FULLPANELRIGHT10', s)
        self.assertIn('watchChanges: true', s)
        self.assertIn('readonly property bool overflow: notchAware', s)
        self.assertIn('clip: fullPanelEdge.overflow', s)
        self.assertIn('interactive: false', s)
        self.assertIn('region: fullPanelEdge.edge', s)
        self.assertEqual(s.count('component FullPanelEdgeModules: Item'), 1)
        self.assertEqual(s.count('FullPanelEdgeModules {\n          edge: "right"'), 1)
        self.assertEqual(s.count('FullPanelEdgeModules {\n          edge: "left"'), 1)
        self.assertNotIn(mod.HORIZONTAL_OLD, s)

    def test_idempotent(self):
        once = mod.patch_text(self.source)
        self.assertEqual(once, mod.patch_text(once))

    def test_migrate_v1_without_losing_user_content_or_height_fix(self):
        orig = self.source.replace(mod.HOME_ANCHOR,
                                   mod.HOME_ANCHOR + mod.HOST_INFO_V1)
        orig = orig.replace(mod.NOTCH_FLOOR, mod.NEW_NOTCH_FLOOR)
        orig = orig.replace(mod.OLD_HEIGHT, mod.OLD_MANUAL_HEIGHT)
        orig = orig.replace('  id: root\n', '  id: root\n  property string ownerNote: "keep"\n')
        updated = mod.patch_text(orig)
        self.assertIn('ownerNote: "keep"', updated)
        self.assertIn(mod.MARKER, updated)
        self.assertNotIn(mod.V1_MARKER, updated)
        self.assertIn(mod.NEW_HEIGHT, updated)
        self.assertEqual(updated, mod.patch_text(updated))

    def test_migrate_omanotch_wrapped_height(self):
        src = self.source.replace(mod.OLD_HEIGHT, mod.OLD_OMANOTCH_HEIGHT)
        updated = mod.patch_text(src)
        self.assertIn(mod.NEW_OMANOTCH_HEIGHT, updated)
        self.assertIn('barWindow.parkedSize', updated)

    def test_bad_v1_is_not_treated_as_success(self):
        broken = self.source.replace(mod.HOME_ANCHOR,
                                     mod.HOME_ANCHOR + mod.HOST_INFO_V1[:-3])
        with self.assertRaisesRegex(ValueError, 'metadata differs'):
            mod.patch_text(broken)

    def test_bad_v2_is_not_treated_as_success(self):
        patched = mod.patch_text(self.source).replace('component FullPanelEdgeModules: Item',
                                                      'component BrokenEdge: Item')
        with self.assertRaisesRegex(ValueError, 'v2 marker'):
            mod.patch_text(patched)

    def test_rejects_upstream_changes(self):
        with self.assertRaisesRegex(ValueError, 'notchFloor'):
            mod.patch_text(self.source.replace('readonly property int notchFloor',
                                               'readonly property int notchArea'))
        with self.assertRaisesRegex(ValueError, 'bar root'):
            mod.patch_text(self.source.replace(mod.HOME_ANCHOR, ''))
        with self.assertRaisesRegex(ValueError, 'horizontal module layout'):
            mod.patch_text(self.source.replace('RightModules {', 'NewRightModules {'))

    def test_scale_geometry_and_overflow(self):
        # Host: width 1800 points, camera [790,1010], height 40 points.
        # The guest uses 3600 physical horizontal pixels, changing QScreen's
        # logical width with Hyprland scale. No second scale factor is applied.
        for scale in (1, 1.33, 1.6, 2, 3, 4):
            width = 3600 / scale
            left = 7900 * width / 18000
            right = 10100 * width / 18000
            bar = ceil(400 * width / 18000)
            self.assertAlmostEqual(left + (width - right), width - (right-left))
            self.assertGreater(left, 0)
            self.assertLess(right, width)
            self.assertGreater(bar, 0)
            right_safe = width - right - 38  # illustrative edge+gap margin
            self.assertGreater(right_safe, 0)
            # Arbitrarily wide plugin row is clipped to right safe region,
            # and arrows provide navigation independent of plugin count.
            row_width = 950
            clipped = min(right_safe, row_width)
            self.assertLessEqual(clipped, width - right)
            if scale >= 3:
                self.assertLess(right_safe, 530)

    def test_native_external_and_missing_bounds_guards(self):
        new = mod.patch_text(self.source)
        self.assertIn('env.OMACVM_FULLPANEL === 1', new)
        self.assertIn('String(s.name) !== fullPanelBuiltin', new)
        self.assertIn('strip > 1 && strip < h * 0.06', new)
        self.assertIn('if (!info.enabled || !info.left10 || !info.right10) return null', new)
        self.assertIn('left10: boundsValid ? l : 0', new)
        self.assertIn('right10: boundsValid ? r : 0', new)


if __name__ == '__main__':
    unittest.main(verbosity=2)
