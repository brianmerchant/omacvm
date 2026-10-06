#!/usr/bin/env python3
"""Tests for Omanotch's display panel patch (no VM needed).

    python3 src/omanotch/guest/tests/test_display_panel.py
"""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("display_panel", str(HERE.parent / "monitor/display-panel.py"))
spec = importlib.util.spec_from_loader("display_panel", loader)
dp = importlib.util.module_from_spec(spec)
loader.exec_module(dp)

# The lines of Omarchy's Panel.qml the patch changes, with some around them.
PANEL = """import QtQuick
import Quickshell
import "Model.js" as Model

Panel {
  id: root
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  BarIconButton {
    id: button
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
  }
}
"""

MANIFEST = {"schemaVersion": 1, "id": "omarchy.monitor", "name": "Display", "kinds": ["bar-widget"],
            "entryPoints": {"barWidget": "Panel.qml"},
            "barWidget": {"displayName": "Display", "category": "System", "allowMultiple": False}}

DISPLAYS = [{"name": "Virtual-1", "enabled": True, "focused": True, "width": 3456, "height": 2160},
            {"name": "NOTCH", "enabled": True, "focused": False, "width": 3456, "height": 74}]


class Patch(unittest.TestCase):
    def test_patch(self):
        out = dp.patch(PANEL)
        self.assertIn(dp.VERSION_LINE, out)
        self.assertIn("Model.parseDisplays(root.notchFilterJson(displaysJson))", out)
        self.assertIn('text: root.notchScreenCount() > 1 ? "󰍺" : "󰍹"', out)
        self.assertNotIn("Quickshell.screens.length > 1", out)
        # The rest of the panel stays as it was.
        self.assertIn("  property int enabledDisplayCount: 0\n", out)

    def test_twice_is_once(self):
        once = dp.patch(PANEL)
        self.assertEqual(dp.patch(once), once)

    def test_changed_panel(self):
        with self.assertRaises(ValueError):
            dp.patch(PANEL.replace("Quickshell.screens.length > 1", "screens.count > 1"))
        with self.assertRaises(ValueError):
            dp.patch(PANEL.replace("  property var displays: []\n", ""))

    def test_other_version(self):
        with self.assertRaises(ValueError):
            dp.patch("// omarchy-notch-bar display panel patch v0\n" + PANEL)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class PanelCode(unittest.TestCase):
    """The patch's QML functions, run as plain JavaScript."""

    def run_js(self, screens, raw):
        helpers = dp.HELPERS
        code = ("var Quickshell = {screens: %s};\n" % json.dumps([{"name": n} for n in screens])
                + helpers + "\nconsole.log(JSON.stringify({count: notchScreenCount(), "
                "list: notchFilterJson(%s)}))\n" % json.dumps(raw))
        out = subprocess.run(["node", "-e", code], capture_output=True, text=True, check=True).stdout
        return json.loads(out)

    def test_notch_left_out(self):
        got = self.run_js(["Virtual-1", "NOTCH"], json.dumps(DISPLAYS))
        self.assertEqual(got["count"], 1)
        self.assertEqual([d["name"] for d in json.loads(got["list"])], ["Virtual-1"])

    def test_two_displays_stay(self):
        mons = DISPLAYS + [{"name": "Virtual-2", "enabled": True, "focused": False, "width": 3840, "height": 2160}]
        got = self.run_js(["Virtual-1", "NOTCH", "Virtual-2"], json.dumps(mons))
        self.assertEqual(got["count"], 2)
        self.assertEqual([d["name"] for d in json.loads(got["list"])], ["Virtual-1", "Virtual-2"])

    def test_broken_json_passes(self):
        self.assertEqual(self.run_js([], "not json")["list"], "not json")


class Clone(unittest.TestCase):
    """main(): the omanotch.monitor clone, with Omarchy's commands stubbed."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.source = self.tmp / "omarchy/shell/plugins/panels/monitor"
        self.source.mkdir(parents=True)
        (self.source / "Panel.qml").write_text(PANEL)
        (self.source / "Model.js").write_text("function parseDisplays(raw) {}\n")
        (self.source / "manifest.json").write_text(json.dumps(MANIFEST))
        self.plugins = self.tmp / "config/omarchy/plugins"
        self.plugins.mkdir(parents=True)
        self.clone = self.plugins / "omanotch.monitor"
        self.calls = []
        env = {"XDG_CONFIG_HOME": str(self.tmp / "config"), "OMARCHY_PATH": str(self.tmp / "omarchy")}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.enabled = []
        patcher = mock.patch.object(dp, "run", side_effect=self.fake_run)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_run(self, *cmd):
        self.calls.append(cmd)
        if cmd[0] == "omarchy-plugin-enable":
            self.enabled.append(cmd[1])
            return f"Enabled {cmd[1]}\n"
        if cmd[0] == "omarchy-plugin-list":
            return json.dumps([{"id": i, "enabled": True} for i in self.enabled[-1:]])
        return ""

    def main(self, *args):
        with mock.patch("builtins.print"):
            return dp.main(["display-panel.py", *args])

    def test_first_install(self):
        self.assertEqual(self.main(), 0)
        manifest = json.loads((self.clone / "manifest.json").read_text())
        self.assertEqual(manifest["id"], "omanotch.monitor")
        self.assertEqual(manifest["omarchy"]["clonedFrom"], "omarchy.monitor")
        self.assertEqual(manifest["entryPoints"], MANIFEST["entryPoints"])
        self.assertIn(dp.VERSION_LINE, (self.clone / "Panel.qml").read_text())
        self.assertTrue((self.clone / "Model.js").is_file())
        self.assertTrue((self.clone / ".source-sha256").is_file())
        self.assertEqual(self.enabled, ["omanotch.monitor"])
        self.assertFalse(list(self.plugins.glob(".*")), "no staging folder left")

    def test_refresh_quiet_when_unchanged(self):
        self.main()
        self.calls.clear()
        self.assertEqual(self.main("--refresh"), 0)
        self.assertEqual(self.calls, [])

    def test_refresh_after_omarchy_update(self):
        self.main()
        (self.source / "Panel.qml").write_text(PANEL.replace('id: root', 'id: root\n  // new'))
        self.calls.clear()
        self.main("--refresh")
        text = (self.clone / "Panel.qml").read_text()
        self.assertIn("// new", text)
        self.assertIn(dp.VERSION_LINE, text)
        self.assertIn(("omarchy-shell", "-q", "shell", "rescanPlugins"), self.calls)

    def test_refresh_makes_no_clone(self):
        self.main("--refresh")
        self.assertFalse(self.clone.exists())
        self.assertEqual(self.calls, [])

    def test_panel_no_longer_fits(self):
        self.main()
        (self.source / "Panel.qml").write_text(PANEL.replace("Quickshell.screens.length", "screens.count"))
        self.main("--refresh")
        self.assertFalse(self.clone.exists())
        self.assertEqual(self.enabled[-1], "omarchy.monitor")

    def test_omacvm_app_panel(self):
        (self.plugins / "omacvm.monitor").mkdir()
        self.main()
        self.assertFalse(self.clone.exists())
        self.assertEqual(self.calls, [])

    def test_users_own_clone(self):
        own = self.plugins / "gilles.monitor"
        own.mkdir()
        (own / "manifest.json").write_text(json.dumps({**MANIFEST, "id": "gilles.monitor",
                                                       "omarchy": {"clonedFrom": "omarchy.monitor"}}))
        self.main()
        self.assertFalse(self.clone.exists())
        self.assertEqual(self.calls, [])

    def test_remove(self):
        self.main()
        self.main("--remove")
        self.assertFalse(self.clone.exists())
        self.assertEqual(self.enabled[-1], "omarchy.monitor")

    def test_patch_file(self):
        f = self.tmp / "Panel.qml"
        f.write_text(PANEL)
        self.main("--patch", str(f))
        self.assertIn(dp.VERSION_LINE, f.read_text())


if __name__ == "__main__":
    unittest.main()
