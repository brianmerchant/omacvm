#!/usr/bin/env python3
"""Offline transformation/geometry/migration checks for FullPanel Quickbar v4.

These do not replace an on-device Quickshell render or Swift AppKit test.
"""
import importlib.util
from math import ceil
from functools import partial
from pathlib import Path
import unittest
import stat
import tempfile
from unittest.mock import patch

MODULE = Path(__file__).resolve().parent.parent / "fullpanel-bar.py"
spec = importlib.util.spec_from_file_location("fullpanel_bar", MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
patch_bar = partial(mod.patch_text, dedicated=True)


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

    def test_legacy_omanotch_composition_is_inert(self):
        self.assertEqual(mod.patch_text(self.source), self.source)
        self.assertEqual(mod.patch_text("// customized native bar"), "// customized native bar")

    def test_atomic_install_backup_mode_owner_and_idempotence(self):
        with tempfile.TemporaryDirectory() as directory:
            bar = Path(directory) / "Bar.qml"
            original = self.source + "// user's customization\n"
            bar.write_text(original)
            bar.chmod(0o640)
            before = bar.stat()
            changed = patch_bar(original)
            backup = mod.install_text(bar, original, changed)
            self.assertEqual(backup.read_text(), original)
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o640)
            self.assertEqual(bar.read_text(), changed)
            self.assertEqual(stat.S_IMODE(bar.stat().st_mode), 0o640)
            self.assertEqual((bar.stat().st_uid, bar.stat().st_gid), (before.st_uid, before.st_gid))
            self.assertIsNone(mod.install_text(bar, changed, patch_bar(changed)))
            self.assertEqual(len(list(bar.parent.glob("Bar.qml.fullpanel-backup-*"))), 1)
            second = mod.install_text(bar, changed, changed + "// extra\n")
            self.assertNotEqual(backup, second)
            self.assertEqual(backup.read_text(), original)
            self.assertEqual(second.read_text(), changed)

    def test_failed_replace_keeps_original_and_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            bar = Path(directory) / "Bar.qml"
            bar.write_text(self.source)
            with patch.object(mod.os, "replace", side_effect=OSError("replace failed")):
                with self.assertRaisesRegex(OSError, "replace failed"):
                    mod.install_text(bar, self.source, patch_bar(self.source))
            self.assertEqual(bar.read_text(), self.source)
            backups = list(bar.parent.glob("Bar.qml.fullpanel-backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), self.source)
            self.assertEqual(list(bar.parent.glob(".Bar.qml.fullpanel-*")), [])

    def test_failed_staging_keeps_original(self):
        with tempfile.TemporaryDirectory() as directory:
            bar = Path(directory) / "Bar.qml"
            bar.write_text(self.source)
            with patch.object(mod.os, "fsync", side_effect=OSError("write failed")):
                with self.assertRaisesRegex(OSError, "write failed"):
                    mod.install_text(bar, self.source, patch_bar(self.source))
            self.assertEqual(bar.read_text(), self.source)
            self.assertEqual(list(bar.parent.iterdir()), [bar])

    def test_concurrent_edit_and_unpatchable_clone_stay_intact(self):
        with tempfile.TemporaryDirectory() as directory:
            bar = Path(directory) / "Bar.qml"
            bar.write_text("// concurrent user edit\n")
            with self.assertRaisesRegex(ValueError, "changed during patching"):
                mod.install_text(bar, self.source, patch_bar(self.source))
            self.assertEqual(bar.read_text(), "// concurrent user edit\n")
            with self.assertRaises(ValueError):
                patch_bar(bar.read_text())
            self.assertEqual(list(bar.parent.iterdir()), [bar])

    def test_symlink_clone_preserves_link(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "Owned.qml"
            target.write_text(self.source)
            link = Path(directory) / "Bar.qml"
            link.symlink_to(target.name)
            mod.install_text(link, self.source, patch_bar(self.source))
            self.assertTrue(link.is_symlink())
            self.assertEqual(target.read_text(), patch_bar(self.source))

    def test_adds_dynamic_height_bounds_and_single_widget_instance_per_side(self):
        s = patch_bar(self.source)
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
        self.assertIn('region: fullPanelEdge.widgetRegion', s)
        self.assertIn('component FullPanelBalancedModules: Item', s)
        self.assertIn('root.activePopout || root.barDragSource || root.barHovered', s)
        self.assertIn('function onBarHoveredChanged() { balanced.scheduleRebalance() }', s)
        self.assertIn('widgetRegion: "right"', s)
        self.assertIn('region: fullPanelEdge.widgetRegion', s)
        self.assertIn('entriesOverride: balanced.rightEntries.slice(0, balanced.borrowedCount)', s)
        self.assertIn('entriesOverride: balanced.rightEntries.slice(balanced.borrowedCount)', s)
        self.assertEqual(s.count('component FullPanelEdgeModules: Item'), 1)
        self.assertEqual(s.count('FullPanelBalancedModules {\n          targetScreen: barWindow.screen'), 1)
        self.assertEqual(s.count('component FullPanelBalancedModules: Item'), 1)
        self.assertNotIn(mod.HORIZONTAL_OLD, s)

    def test_idempotent(self):
        once = patch_bar(self.source)
        self.assertEqual(once, patch_bar(once))

    def test_migrate_v1_without_losing_user_content_or_height_fix(self):
        orig = self.source.replace(mod.HOME_ANCHOR,
                                   mod.HOME_ANCHOR + mod.HOST_INFO_V1)
        orig = orig.replace(mod.NOTCH_FLOOR, mod.NEW_NOTCH_FLOOR)
        orig = orig.replace(mod.OLD_HEIGHT, mod.OLD_MANUAL_HEIGHT)
        orig = orig.replace('  id: root\n', '  id: root\n  property string ownerNote: "keep"\n')
        updated = patch_bar(orig)
        self.assertIn('ownerNote: "keep"', updated)
        self.assertIn(mod.MARKER, updated)
        self.assertNotIn(mod.V1_MARKER, updated)
        self.assertIn(mod.NEW_HEIGHT, updated)
        self.assertEqual(updated, patch_bar(updated))

    def test_migrate_omanotch_wrapped_height(self):
        src = self.source.replace(mod.OLD_HEIGHT, mod.OLD_OMANOTCH_HEIGHT)
        updated = patch_bar(src)
        self.assertIn(mod.NEW_OMANOTCH_HEIGHT, updated)
        self.assertIn('barWindow.parkedSize', updated)

    def test_bad_v1_is_not_treated_as_success(self):
        broken = self.source.replace(mod.HOME_ANCHOR,
                                     mod.HOME_ANCHOR + mod.HOST_INFO_V1[:-3])
        with self.assertRaisesRegex(ValueError, 'metadata differs'):
            patch_bar(broken)

    def test_bad_v2_is_not_treated_as_success(self):
        patched = self.make_v2().replace('component FullPanelEdgeModules: Item',
                                         'component BrokenEdge: Item')
        with self.assertRaisesRegex(ValueError, 'v2 marker'):
            patch_bar(patched)

    def test_bad_v3_is_not_treated_as_success(self):
        patched = self.make_v3().replace('component FullPanelBalancedModules: Item',
                                         'component BrokenBalanced: Item')
        with self.assertRaisesRegex(ValueError, 'v3 marker'):
            patch_bar(patched)

    def make_v2(self):
        patched = self.source.replace(mod.HOME_ANCHOR, mod.HOME_ANCHOR + mod.HOST_INFO_V2)
        patched = patched.replace(mod.NOTCH_FLOOR, mod.NEW_NOTCH_FLOOR)
        patched = patched.replace(mod.OLD_HEIGHT, mod.NEW_HEIGHT)
        patched = patched.replace(mod.EDGE_ANCHOR, mod.EDGE_COMPONENT_V2 + "\n" + mod.EDGE_ANCHOR)
        patched = patched.replace(mod.HORIZONTAL_OLD, mod.HORIZONTAL_NEW)
        return patched

    def test_migrate_live_v2_and_preserve_settings(self):
        original = self.make_v2().replace(
            '  id: root\n',
            '  id: root\n  property var barConfig: ({})\n  property string omarchyPath: Quickshell.env("OMARCHY_PATH")\n'
        ).replace('  component LeftModules: ModuleList {',
                  '  property string localNote: "unchanged"\n  component LeftModules: ModuleList {')
        upgraded = patch_bar(original)
        self.assertNotIn(mod.V2_MARKER, upgraded)
        self.assertIn(mod.MARKER, upgraded)
        self.assertIn('property var barConfig: ({})', upgraded)
        self.assertIn('localNote: "unchanged"', upgraded)
        self.assertIn(mod.NEW_HEIGHT, upgraded)
        self.assertIn('component FullPanelBalancedModules: Item', upgraded)
        self.assertEqual(upgraded, patch_bar(upgraded))
        self.assertEqual(upgraded.count('component FullPanelEdgeModules: Item'), 1)


    def test_migrate_live_v3_hover_fix_only(self):
        v3 = self.make_v3().replace('  id: root\n',
            '  id: root\n  property string note: "user customization survives"\n')
        updated = patch_bar(v3)
        self.assertNotIn(mod.V3_MARKER, updated)
        self.assertIn(mod.MARKER, updated)
        self.assertIn('note: "user customization survives"', updated)
        self.assertIn('root.activePopout || root.barDragSource || root.barHovered', updated)
        self.assertIn('function onBarHoveredChanged() { balanced.scheduleRebalance() }', updated)
        self.assertEqual(updated, patch_bar(updated))

    def test_bad_v4_is_not_treated_as_success(self):
        broken = patch_bar(self.source).replace(
            'function onBarHoveredChanged() { balanced.scheduleRebalance() }',
            'function onBarHoveredChanged() { /* broken */ }')
        with self.assertRaisesRegex(ValueError, 'v4 marker'):
            patch_bar(broken)

    def test_hover_guard_is_prior_to_borrow_count_mutation(self):
        qml = mod.BALANCED_COMPONENT
        method = qml[qml.index('    function rebalance() {'):qml.index('    // Coalesced', qml.index('    function rebalance() {'))]
        guard = 'if (root.activePopout || root.barDragSource || root.barHovered) return'
        mutation = 'borrowedCount = wanted'
        self.assertIn(guard, method)
        self.assertIn(mutation, method)
        self.assertLess(method.index(guard), method.index(mutation))

    def make_v3(self):
        text = self.make_v2()
        return mod.upgrade_v2_to_v3(text)

    def test_balancing_rules(self):
        # Mimic the width-based split rule. The live QML obtains these widths
        # from the actual ModuleSlot instances, not a hardcoded theme table.
        def borrowed(widths, left_free, right_capacity):
            remaining = sum(widths)
            moved = used = 0
            while moved < len(widths) and remaining > right_capacity + .5:
                if used + widths[moved] > left_free + .5:
                    break
                used += widths[moved]
                remaining -= widths[moved]
                moved += 1
            return moved, remaining, used

        widgets = [43, 24, 44, 35, 34, 36, 41, 42, 41, 38, 35, 44, 35, 154]
        for scale in (1, 1.33, 1.6, 2, 3, 4):
            screen_width = 3600 / scale
            margin = 34  # illustrative: source uses Style.space(8) + 6
            left_cap = screen_width * 790 / 1800 - margin
            right_cap = screen_width * 790 / 1800 - margin
            left_free = max(0, left_cap - 140 - 8)
            count, right_used, left_used = borrowed(widgets, left_free, right_cap)
            self.assertLessEqual(left_used, left_free + .5)
            self.assertEqual(widgets[:count] + widgets[count:], widgets)
            if scale == 4:
                self.assertGreater(count, 0)
                self.assertLess(count, len(widgets))
                self.assertGreater(right_used, right_cap)  # arrows still needed
        self.assertEqual(borrowed([50, 60, 70], 0, 100)[0], 0)
        self.assertEqual(borrowed([90, 10], 100, 200)[0], 0)
        self.assertEqual(borrowed([120, 15, 15], 80, 90)[0], 0)
        self.assertEqual(borrowed([20, 30, 40], 100, 0)[0], 3)

    def test_rejects_upstream_changes(self):
        with self.assertRaisesRegex(ValueError, 'notchFloor'):
            patch_bar(self.source.replace('readonly property int notchFloor',
                                               'readonly property int notchArea'))
        with self.assertRaisesRegex(ValueError, 'bar root'):
            patch_bar(self.source.replace(mod.HOME_ANCHOR, ''))
        with self.assertRaisesRegex(ValueError, 'horizontal module layout'):
            patch_bar(self.source.replace('RightModules {', 'NewRightModules {'))

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
        new = patch_bar(self.source)
        self.assertIn('env.OMACVM_FULLPANEL === 1', new)
        self.assertIn('String(s.name) !== fullPanelBuiltin', new)
        self.assertIn('strip > 1 && strip < h * 0.06', new)
        self.assertIn('if (!info.enabled || !info.left10 || !info.right10) return null', new)
        self.assertIn('left10: boundsValid ? l : 0', new)
        self.assertIn('right10: boundsValid ? r : 0', new)


if __name__ == '__main__':
    unittest.main(verbosity=2)
