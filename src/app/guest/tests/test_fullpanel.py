#!/usr/bin/env python3
"""Offline installation/boot switching fixtures. No VM or real service calls."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fullpanel", HERE / "fullpanel.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
layout = runpy.run_path(str(HERE / "fullpanel-bar.py"))


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())


def snapshot(folder):
    return {str(p.relative_to(folder)): p.read_bytes() for p in folder.rglob("*") if p.is_file()}


class Guest(mod.FullPanel):
    def __init__(self, *args):
        super().__init__(*args)
        self.commands = []
        self.running = False
        self.units = {u: "enabled" for u in mod.UNITS}
        self.before_masks = {}
        self.active = set()
        self.fail = None
        self.defer_stop = False
        self.unmanaged = False
        self.active_bar = None
        self.graphical_session_active = False
        self.activate_session_on_reload = False

    def activate_graphical_session(self):
        # Target wants are started once. Reloading/unmasking afterwards does
        # not retry a service whose startup opportunity passed while masked.
        if self.graphical_session_active:
            return
        self.graphical_session_active = True
        for unit in mod.UNITS:
            if self.units[unit] in ("enabled", "enabled-runtime"):
                self.command("systemctl", "--user", "start", "--no-block", unit)

    def command(self, *args, required=True):
        self.commands.append(args)
        result, output, error = 0, "", ""
        if args[0] == "omarchy-shell":
            if args[-1] == "listPlugins":
                selected = self.active_bar or json.loads(self.config.read_bytes())["bar"].get("id", "omarchy.bar")
                output = json.dumps([{"id": selected, "active": True, "kinds": ["bar"]}])
            else:
                result = 0 if self.running else 1
        elif args[0] == "omarchy-plugin-validate":
            manifest = json.loads((Path(args[1]) / "manifest.json").read_text())
            assert manifest["id"] == mod.PLUGIN
            assert manifest["kinds"] == ["bar"]
            assert manifest["omarchy"] == {"clonedFrom": "omarchy.bar"}
            assert (Path(args[1]) / "BarModel.js").is_file()
        elif args[0] == "systemctl":
            verb = args[2]
            if verb == "is-enabled":
                output = self.units[args[-1]]
                result = 1 if output in ("disabled", "missing", "masked", "masked-runtime") else 0
            elif verb == "is-active":
                result = 0 if args[-1] in self.active else 3
            elif verb == "show":
                pid = 100 if args[-1] in self.active else 0
                if "--property=LoadState" in args:
                    output = "not-found" if self.units[args[-1]] == "missing" else "masked" if self.units[args[-1]] in ("masked", "masked-runtime") else "loaded"
                elif "--property=ControlPID" in args:
                    output = f"MainPID={pid}\nControlPID=0\n"
                else:
                    output = str(pid)
                if self.units[args[-1]] == "missing":
                    result = 1
                    if "--property=LoadState" not in args:
                        output = ""
            elif verb == "daemon-reload":
                for unit in mod.UNITS:
                    if (self.mask_dir / unit).is_symlink():
                        if self.units[unit] != "masked-runtime":
                            self.before_masks[unit] = self.units[unit]
                        self.units[unit] = "masked-runtime"
                    elif self.units[unit] == "masked-runtime" and unit in self.before_masks:
                        self.units[unit] = self.before_masks.pop(unit)
                if self.activate_session_on_reload:
                    self.activate_graphical_session()
            else:
                for unit in (a for a in args[3:] if a in mod.UNITS):
                    if verb == "stop":
                        # A runtime mask can exist even when the service
                        # was never installed. systemd rejects stopping that
                        # unloaded unit; masking must not hide its absence.
                        if self.before_masks.get(unit, self.units[unit]) == "missing" and unit not in self.active:
                            result = 5
                            error = f"Failed to stop {unit}: Unit {unit} not loaded."
                            continue
                        if not self.defer_stop:
                            self.active.discard(unit)
                    elif verb == "kill":
                        if self.fail != "kill":
                            self.active.discard(unit)
                    elif verb == "start":
                        if self.units[unit] in ("missing", "masked", "masked-runtime"):
                            result = 1
                        elif unit == "notchcast.service":
                            self.active.add(unit)
                        # The install unit is oneshot/conditional; a normal
                        # start completes without a persistent process.
                    else:
                        raise AssertionError(args)
        elif args[0] == "pgrep":
            result = 0 if self.unmanaged else 1
        else:
            raise AssertionError(args)
        if self.fail and self.fail in args:
            result = 1
        if required and result:
            raise ValueError("mock command failed: " + " ".join(args))
        return subprocess.CompletedProcess(args, result, output, error)


class FullPanelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.guest = Guest(root / "home", root / "omarchy", root / "run",
                           root / "host.env", HERE / "fullpanel-bar.py")
        self.g = self.guest
        # Linux pidfds are mocked by readable, closable descriptors. No real
        # process or service is signalled on the machine running these tests.
        pidfds = patch.object(mod.os, "pidfd_open", side_effect=lambda pid: os.open(os.devnull, os.O_RDONLY), create=True)
        pidfds.start()
        self.addCleanup(pidfds.stop)
        self.source = (self.g.omarchy / "shell/plugins/bar")
        source_qml = ('import Quickshell\nimport Quickshell.Io\nItem {\n  id: root\n'
                      '  required property var barConfig\n'
                      '  required property var barWidgetRegistry\n'
                      '  required property string omarchyPath\n'
                      + layout["HOME_ANCHOR"] + layout["NOTCH_FLOOR"]
                      + layout["OLD_HEIGHT"] + layout["HORIZONTAL_OLD"]
                      + layout["EDGE_ANCHOR"]
                      + '    entries: root.layoutEntries("left")\n  }\n'
                      '  Variants { model: Quickshell.screens }\n}\n')
        write(self.source / "Bar.qml", source_qml)
        write(self.source / "BarModel.js", "// stock bar model\n")
        self.manifest = {"schemaVersion": 1, "id": "omarchy.bar", "name": "Bar",
                         "version": "1.0.0", "kinds": ["bar"], "entryPoints": {"bar": "Bar.qml"}}
        write(self.source / "manifest.json", mod.encoded(self.manifest))
        self.native = {"version": 1, "bar": {"id": "fixture.bar", "position": "top",
                       "transparent": True, "layout": {"left": [{"id": "custom.widget"}],
                       "center": [], "right": [{"id": "omacvm.wifi"}]}},
                       "idle": {"lock": 750}, "plugins": [{"id": "custom.panel", "config": {"x": 1}}]}
        self.original = json.dumps(self.native, separators=(",", ":")).encode() + b"\n"
        write(self.g.config, self.original)
        self.native_plugin = self.g.plugin.parent / "fixture.bar"
        manifest = copy.deepcopy(self.manifest)
        manifest["id"] = "fixture.bar"
        manifest["omarchy"] = {"clonedFrom": "omarchy.bar"}
        write(self.native_plugin / "manifest.json", mod.encoded(manifest))
        write(self.native_plugin / "Bar.qml", "// Omanotch working bar; user customizations\n")
        write(self.native_plugin / "Bar.qml.before-notchbar", "// original backup\n")
        write(self.g.home / ".config/hypr/notchbar.lua", "-- original Omanotch integration\n")
        write(self.g.home / ".config/hypr/omacvm_fullpanel.lua", (HERE / "omacvm_fullpanel.lua").read_bytes())
        write(self.g.home / ".config/hypr/hyprland.lua", 'require("hypr.notchbar")\nrequire("hypr.omacvm_fullpanel")\n')
        write(self.g.home / ".config/systemd/user/notchcast.service", "[Service]\nExecStart=notchcast\n")
        write(self.g.home / ".config/omarchy/plugins/custom.panel/Panel.qml", "// unrelated panel\n")
        self.protected = {p: p.read_bytes() for p in self.g.home.rglob("*") if p.is_file() and p not in (self.g.config, self.g.home / ".config/hypr/hyprland.lua")}
        self.stock = snapshot(self.g.omarchy)
        self.mode(False)

    def mode(self, fullpanel):
        write(self.g.host, "OMACVM_NOTCHPOINTER=1\n" + ("OMACVM_FULLPANEL=1\n" if fullpanel else ""))

    def assert_protected(self):
        for path, contents in self.protected.items():
            self.assertEqual(path.read_bytes(), contents, str(path))
        self.assertEqual(snapshot(self.g.omarchy), self.stock)

    def selected(self):
        return json.loads(self.g.config.read_bytes())["bar"].get("id", "omarchy.bar")

    def test_A_B_existing_omanotch_install_disabled_is_inert(self):
        self.g.install()
        self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertFalse(self.g.state.exists())
        self.assertFalse(self.g.options.exists())
        self.assertFalse(any(c[0] == "systemctl" for c in self.g.commands))
        self.assert_protected()

    def test_C_D_E_select_restore_repeat_no_second_shell(self):
        for _ in range(5):
            self.mode(True)
            self.g.prepare()
            self.assertEqual(self.selected(), mod.PLUGIN)
            self.assertEqual(set(self.g.units.values()), {"masked-runtime"})
            first = self.g.config.read_bytes()
            self.g.prepare()
            self.assertEqual(self.g.config.read_bytes(), first)
            self.mode(False)
            self.g.prepare()
            self.assertEqual(self.g.config.read_bytes(), self.original)
            self.assertEqual(set(self.g.units.values()), {"enabled"})
            self.assert_protected()
        self.assertFalse(any("quickshell" in c or "omarchy-restart-shell" in c for c in self.g.commands))
        bar = (self.g.plugin / "Bar.qml").read_text()
        self.assertEqual(bar.count(layout["MARKER"]), 1)
        self.assertIn('!String(s.name).startsWith("NOTCH")', bar)
        self.assertNotIn('target: "notchbar"', bar)

    def test_F_install_update_is_idempotent_and_only_owns_dedicated_plugin(self):
        self.g.install()
        before = snapshot(self.g.plugin)
        stat = self.g.plugin.stat()
        self.g.install()
        self.assertEqual(snapshot(self.g.plugin), before)
        self.assertEqual(self.g.plugin.stat().st_ino, stat.st_ino)
        write(self.source / "BarModel.js", "// updated stock model\n")
        self.g.install()
        self.assertEqual((self.g.plugin / "BarModel.js").read_text(), "// updated stock model\n")
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertEqual(sorted(p.name for p in self.g.plugin.parent.iterdir()),
                         ["custom.panel", "fixture.bar", mod.PLUGIN])
        for path, contents in self.protected.items():
            self.assertEqual(path.read_bytes(), contents)

    def test_G_custom_native_bar_and_separate_fullpanel_preferences(self):
        self.mode(True)
        self.g.prepare()
        changed = json.loads(self.g.config.read_bytes())
        changed["idle"]["lock"] = 900
        changed["plugins"].append({"id": "user.new-panel"})
        changed["bar"]["transparent"] = False
        write(self.g.config, mod.encoded(changed))
        self.mode(False)
        self.g.prepare()
        restored = json.loads(self.g.config.read_bytes())
        self.assertEqual(restored["bar"], self.native["bar"])
        self.assertEqual(restored["idle"], changed["idle"])
        self.assertEqual(restored["plugins"], changed["plugins"])
        self.mode(True)
        self.g.prepare()
        self.assertFalse(json.loads(self.g.config.read_bytes())["bar"]["transparent"])
        self.assert_protected()

    def test_H_failed_build_validation_publish_and_selection_keep_native(self):
        self.mode(True)
        self.fail_install("omarchy-plugin-validate")
        self.g.fail = None
        with patch.object(mod.os, "replace", side_effect=OSError("publish failed")):
            with self.assertRaises(OSError):
                self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.g.install()
        replace = mod.atomic
        def fail_config(path, *args):
            if path == self.g.config:
                raise OSError("config write failed")
            return replace(path, *args)
        self.g.active.add("notchcast.service")
        with patch.object(mod, "atomic", side_effect=fail_config):
            with self.assertRaises(OSError):
                self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertIn("notchcast.service", self.g.active)
        self.assertEqual(set(self.g.units.values()), {"enabled"})
        self.assert_protected()

    def fail_install(self, command):
        self.g.fail = command
        with self.assertRaises(ValueError):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertEqual(set(self.g.units.values()), {"enabled"})
        self.assert_protected()

    def test_H_mask_failure_rolls_back_and_never_selects_fullpanel(self):
        self.mode(True)
        self.g.active.add("notchcast.service")
        self.fail_install("stop")
        self.assertIn("notchcast.service", self.g.active)
        self.assertFalse(self.g.masks.exists())

    def test_I_fresh_install_defaults_and_first_native_omanotch_login(self):
        self.g.config.unlink()
        defaults = copy.deepcopy(self.native)
        defaults["bar"].pop("id")
        write(self.g.omarchy / "config/omarchy/shell.json", mod.encoded(defaults))
        self.g.install()  # Same action the supported app guest installer runs.
        self.assertFalse(self.g.config.exists())
        self.mode(True)
        self.g.prepare()
        self.assertEqual(self.selected(), mod.PLUGIN)
        self.mode(False)
        self.g.prepare()
        self.assertFalse(self.g.config.exists())  # Original default selection.
        write(self.g.config, self.original)  # Omanotch's normal first-login install.
        self.mode(True)
        self.g.prepare()
        self.mode(False)
        self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)

    def test_fresh_fullpanel_first_login_preserves_queued_widget_placements(self):
        self.g.config.unlink()
        defaults = copy.deepcopy(self.native)
        defaults["bar"].pop("id")
        write(self.g.omarchy / "config/omarchy/shell.json", mod.encoded(defaults))
        self.mode(True)
        self.g.prepare()
        config = json.loads(self.g.config.read_bytes())
        config["bar"]["layout"]["right"].append({"id": "omacvm.control"})
        write(self.g.config, mod.encoded(config))
        self.mode(False)
        self.g.prepare()
        restored = json.loads(self.g.config.read_bytes())
        self.assertNotIn("id", restored["bar"])
        self.assertEqual(restored["bar"]["layout"], config["bar"]["layout"])

    def test_failed_update_at_next_boot_keeps_validated_fullpanel_and_masks(self):
        self.mode(True)
        self.g.prepare()
        before = snapshot(self.g.plugin)
        fullpanel = self.g.config.read_bytes()
        self.g.masks.unlink()  # /run is empty again after a reboot.
        for unit in mod.UNITS:
            (self.g.mask_dir / unit).unlink()
        self.g.units = {u: "enabled" for u in mod.UNITS}
        write(self.source / "Bar.qml", "// incompatible upstream\n")
        with patch("sys.stderr"):
            self.g.prepare()
        self.assertEqual(snapshot(self.g.plugin), before)
        self.assertEqual(self.g.config.read_bytes(), fullpanel)
        self.assertEqual(set(self.g.units.values()), {"masked-runtime"})

    def test_existing_plugin_failed_publish_restores_previous_directory(self):
        self.g.install()
        before = snapshot(self.g.plugin)
        write(self.source / "BarModel.js", "// update\n")
        replace = mod.os.replace
        def fail_stage(source, target):
            if Path(source).name == mod.PLUGIN and Path(target) == self.g.plugin:
                raise OSError("publish failed")
            return replace(source, target)
        with patch.object(mod.os, "replace", side_effect=fail_stage):
            with self.assertRaises(OSError):
                self.g.install()
        self.assertEqual(snapshot(self.g.plugin), before)
        self.assertEqual(self.g.config.read_bytes(), self.original)

    def test_supported_installer_wires_hook_once_with_mocked_guest_commands(self):
        # Run the actual small installer. Every privileged command is mocked
        # and redirects system destinations beneath this temporary fixture.
        root = self.g.home.parent
        bin_dir = root / "bin"
        bin_dir.mkdir()
        header = "#!" + sys.executable + "\n"
        scripts = {
            "getent": 'import os\nprint("fixture:x:1000:1000::" + os.environ["FIX_HOME"] + ":/bin/bash")\n',
            "id": 'print("1000")\n',
            "chown": 'pass\n',
            "omarchy-shell": 'import sys\nsys.exit(1)\n',
            "omarchy-plugin-validate": 'import json,sys,pathlib\np=pathlib.Path(sys.argv[1])\nassert json.loads((p/"manifest.json").read_text())["id"] == "omacvm.fullpanel.bar"\nassert (p/"Bar.qml").is_file()\n',
            "install": '''import os, pathlib, shutil, sys
args = sys.argv[1:]; paths = []; directory = False
i = 0
while i < len(args):
    a = args[i]
    if a in ("-o", "-g", "-m"): i += 2; continue
    if a.startswith("-"):
        directory = directory or a == "-d"
    else: paths.append(a)
    i += 1
def dest(text):
    p = pathlib.Path(text)
    if text.startswith("/usr/"): p = pathlib.Path(os.environ["FIX_ROOT"]) / text.lstrip("/")
    assert p.is_relative_to(pathlib.Path(os.environ["FIX_ROOT"]))
    return p
if directory:
    for text in paths: dest(text).mkdir(parents=True, exist_ok=True)
else:
    target = dest(paths[-1]); target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(paths[0], target)
''',
            "runuser": '''import importlib.util, os, pathlib, sys
assert sys.argv[1:4] == ["-u", "fixture", "--"]
assert "exec /usr/local/bin/omacvm-fullpanel install" in sys.argv[-1]
root = pathlib.Path(os.environ["FIX_ROOT"])
spec = importlib.util.spec_from_file_location("installed_fullpanel", root / "usr/local/bin/omacvm-fullpanel")
# Installed executable has no .py suffix.
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("installed_fullpanel", str(root / "usr/local/bin/omacvm-fullpanel"))
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
if os.environ.get("FAIL_INSTALL"): sys.exit(1)
mod.FullPanel(pathlib.Path(os.environ["FIX_HOME"]), root / "omarchy", root / "run",
              root / "host.env", root / "usr/local/lib/omacvm/fullpanel-bar.py").install()
''',
        }
        for name, body in scripts.items():
            write(bin_dir / name, header + body)
            (bin_dir / name).chmod(0o755)
        hypr = self.g.home / ".config/hypr/hyprland.lua"
        write(hypr, '-- user config\nrequire("hypr.notchbar")\n')
        env = dict(os.environ, FIX_ROOT=str(root), FIX_HOME=str(self.g.home), TMPDIR=str(root),
                   PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], PYTHONDONTWRITEBYTECODE="1")
        for _ in range(2):
            result = subprocess.run(["/bin/bash", str(HERE / "fullpanel-install.sh"), "fixture"],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(hypr.read_text().count('require("hypr.omacvm_fullpanel")'), 1)
        self.assertTrue(hypr.read_text().startswith('-- user config\nrequire("hypr.notchbar")\n'))
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertFalse(self.g.failed.exists())
        self.assert_protected()
        # Wiring failure does not write a config hook or disturb active bars.
        hypr_before = hypr.read_bytes()
        result = subprocess.run(["/bin/bash", str(HERE / "fullpanel-install.sh"), "fixture"],
                                env=dict(env, FAIL_INSTALL="1"), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(hypr.read_bytes(), hypr_before)
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertTrue(self.g.failed.exists())
        with self.assertRaisesRegex(ValueError, "installation failed"):
            self.g.status()
        result = subprocess.run(["/bin/bash", str(HERE / "fullpanel-install.sh"), "fixture"], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.g.failed.exists())
        # The supported root installer calls the app installer, which calls
        # this wiring. Both new builds and apply/update use that same path.
        src = HERE.parents[1]
        self.assertIn('"$R/app/guest/install.sh" "$U"', (src / "guest/install.sh").read_text())
        self.assertIn('bash fullpanel-install.sh "$U"', (HERE / "install.sh").read_text())
        hook = (HERE / "omacvm_fullpanel.lua").read_text()
        self.assertIn('os.execute("/usr/local/bin/omacvm-fullpanel prepare")', hook)
        self.assertNotIn("hl.exec_cmd(", hook)

    def test_external_masks_and_user_selection_are_preserved(self):
        self.g.units["notchcast.service"] = "masked"
        self.mode(True)
        self.g.prepare()
        self.mode(False)
        # A user selected another working bar. Native startup leaves it alone.
        write(self.g.config, self.original)
        self.g.prepare()
        self.assertEqual(self.g.units["notchcast.service"], "masked")
        self.assertEqual(self.g.config.read_bytes(), self.original)

    def test_active_shell_refuses_mode_change_and_defers_updates(self):
        self.g.running = True
        self.mode(True)
        with self.assertRaisesRegex(ValueError, "next session"):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.g.running = False
        self.g.prepare()
        before = snapshot(self.g.plugin)
        self.g.running = True
        self.g.prepare()  # Idempotent config reload is harmless.
        write(self.source / "BarModel.js", "// next version\n")
        with self.assertRaisesRegex(ValueError, "next session"):
            self.g.install()
        self.assertEqual(snapshot(self.g.plugin), before)
        self.mode(False)
        with self.assertRaisesRegex(ValueError, "next session"):
            self.g.prepare()
        self.assertEqual(self.selected(), mod.PLUGIN)

    def test_missing_native_plugin_or_corrupt_restore_retains_working_fullpanel(self):
        self.mode(True)
        self.g.prepare()
        fullpanel = self.g.config.read_bytes()
        (self.native_plugin / "Bar.qml").unlink()
        self.mode(False)
        with self.assertRaises(ValueError):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), fullpanel)
        self.assertTrue(self.g.masks.exists())
        write(self.g.state, "{broken")
        with self.assertRaises(ValueError):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), fullpanel)

    def test_failed_native_restore_after_reboot_still_suppresses_omanotch(self):
        self.mode(True)
        self.g.prepare()
        self.g.masks.unlink()
        for unit in mod.UNITS:
            (self.g.mask_dir / unit).unlink()
        self.g.units = {u: "enabled" for u in mod.UNITS}
        self.g.state.unlink()
        self.mode(False)
        with self.assertRaises(ValueError):
            self.g.prepare()
        self.assertEqual(self.selected(), mod.PLUGIN)
        self.assertEqual(set(self.g.units.values()), {"masked-runtime"})

    def test_unmask_does_not_change_disabled_service_preferences(self):
        self.g.units["notchcast.service"] = "disabled"
        self.mode(True)
        self.g.prepare()
        self.mode(False)
        self.g.prepare()
        self.assertEqual(self.g.units["notchcast.service"], "disabled")
        self.assert_protected()

    def test_native_boot_restores_services_that_started_before_config_loading(self):
        self.mode(True)
        self.g.prepare()
        self.g.masks.unlink()
        for unit in mod.UNITS:
            (self.g.mask_dir / unit).unlink()
        self.g.units = {u: "enabled" for u in mod.UNITS}
        self.g.active.add("notchcast.service")
        self.mode(False)
        self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertIn("notchcast.service", self.g.active)
        service_ops = [c for c in self.g.commands if c[0] == "systemctl" and c[2] in ("stop", "start")]
        self.assertTrue(service_ops)
        self.assertTrue(all("--no-block" in c for c in service_ops))
        self.assert_protected()

    def test_first_native_boot_starts_enabled_services_after_session_target(self):
        self.g.install()
        self.g.activate_graphical_session()
        self.g.prepare()  # Working Native before entering FullPanel.
        self.mode(True)
        self.g.prepare()
        self.assertFalse(self.g.active)
        self.assertEqual(self.selected(), mod.PLUGIN)
        # A fresh boot loses /run and active PIDs, but retains the selected
        # FullPanel bar. The target starts while prepare's masks are present.
        self.g.masks.unlink()
        for unit in mod.UNITS:
            (self.g.mask_dir / unit).unlink()
        self.g.command("systemctl", "--user", "daemon-reload")
        self.g.graphical_session_active = False
        self.g.activate_session_on_reload = True
        self.g.commands.clear()
        self.mode(False)
        command = self.g.command
        def checked(*args, **kwargs):
            if "start" in args:
                self.assertTrue(self.g.graphical_session_active)
                self.assertEqual(self.g.config.read_bytes(), self.original)
                self.assertFalse(any((self.g.mask_dir / u).is_symlink() for u in mod.UNITS))
                self.assertIn("--no-block", args)
            return command(*args, **kwargs)
        with patch.object(self.g, "command", side_effect=checked):
            self.g.prepare()
        self.assertTrue(self.g.graphical_session_active)
        self.assertIn("notchcast.service", self.g.active)
        starts = [c for c in self.g.commands if "start" in c]
        self.assertEqual({u for c in starts for u in c if u in mod.UNITS}, set(mod.UNITS))
        self.assertIn("Native", self.g.status())
        self.assertFalse(self.g.masks.exists())
        self.g.commands.clear()
        self.g.prepare()  # Repeated Native does not restart the streamer.
        self.assertFalse(any("stop" in c or "start" in c for c in self.g.commands))
        self.assertIn("notchcast.service", self.g.active)
        self.g.active.clear()
        self.g.graphical_session_active = False
        self.g.activate_graphical_session()  # A subsequent ordinary Native boot.
        self.g.commands.clear()
        self.g.prepare()
        self.assertFalse(any("stop" in c or "start" in c for c in self.g.commands))
        self.assertIn("notchcast.service", self.g.active)
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assert_protected()

    def test_native_restore_respects_service_enablement_and_external_masks(self):
        for status in ("disabled", "missing", "masked", "masked-runtime", "static", "enabled-runtime"):
            with self.subTest(status=status):
                self.g.units["notchcast.service"] = status
                self.g.active.clear()
                self.g.graphical_session_active = False
                self.g.activate_session_on_reload = True
                self.mode(True)
                self.g.prepare()
                write(self.g.runtime / "systemd/user/unrelated.service", "[Service]\n# custom override\n")
                self.g.commands.clear()
                self.mode(False)
                self.g.prepare()
                self.assertEqual(self.g.units["notchcast.service"], status)
                self.assertEqual("notchcast.service" in self.g.active, status == "enabled-runtime")
                starts = [c for c in self.g.commands if "start" in c]
                self.assertEqual(any("notchcast.service" in c for c in starts), status == "enabled-runtime")
                self.assertEqual((self.g.runtime / "systemd/user/unrelated.service").read_text(), "[Service]\n# custom override\n")
                self.assertEqual(self.g.config.read_bytes(), self.original)
                self.assert_protected()

    def test_interrupted_native_restore_does_not_restart_running_services(self):
        self.mode(True)
        self.g.prepare()
        write(self.g.config, self.original)  # Native commit succeeded before interruption.
        for unit in mod.UNITS:
            (self.g.mask_dir / unit).unlink()
        self.g.command("systemctl", "--user", "daemon-reload")
        self.g.active.update(mod.UNITS)
        self.g.commands.clear()
        self.mode(False)
        self.g.prepare()
        self.assertFalse(any("start" in c or "stop" in c for c in self.g.commands))
        self.assertEqual(self.g.active, set(mod.UNITS))
        self.assertFalse(self.g.masks.exists())
        self.assert_protected()

    def test_native_restore_keeps_independent_runtime_mask(self):
        unit = "notchcast.service"
        self.g.mask_dir.mkdir(parents=True)
        external = self.g.mask_dir / unit
        external.symlink_to("/dev/null")
        self.g.units[unit] = "masked-runtime"
        self.mode(True)
        self.g.prepare()
        self.assertNotIn(unit, self.g.mask_record()[0])
        self.g.commands.clear()
        self.mode(False)
        self.g.prepare()
        self.assertTrue(external.is_symlink())
        self.assertEqual(os.readlink(external), "/dev/null")
        self.assertEqual(self.g.units[unit], "masked-runtime")
        self.assertFalse(any("start" in c and unit in c for c in self.g.commands))
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assert_protected()

    def test_native_service_start_failure_retains_safe_bar_and_recovers(self):
        self.mode(True)
        self.g.prepare()
        fullpanel = self.g.config.read_bytes()
        self.mode(False)
        self.g.fail = "start"
        with self.assertRaisesRegex(ValueError, "command failed.*start"):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), fullpanel)
        self.assertEqual(set(self.g.units.values()), {"masked-runtime"})
        self.assertFalse(self.g.active)
        self.g.fail = None
        self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertIn("notchcast.service", self.g.active)
        self.assertFalse(self.g.masks.exists())
        self.assert_protected()

    def test_unusable_runtime_mask_is_detected_before_changing_selection(self):
        self.mode(True)
        command = self.g.command
        def refuse_mask(*args, **kwargs):
            result = command(*args, **kwargs)
            if "--property=LoadState" in args:
                result.stdout = "loaded"  # A higher-priority user override.
            return result
        with patch.object(self.g, "command", side_effect=refuse_mask):
            with self.assertRaisesRegex(ValueError, "could not be suppressed"):
                self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertFalse(self.g.masks.exists())
        self.assertEqual(set(self.g.units.values()), {"enabled"})

    def test_unmanaged_plugin_and_unsupported_stock_are_never_overwritten(self):
        write(self.g.plugin / "Bar.qml", "// existing custom plugin\n")
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            self.g.install()
        self.assertEqual((self.g.plugin / "Bar.qml").read_text(), "// existing custom plugin\n")
        self.assert_protected()

    def test_invalid_signal_and_shell_json_are_left_unchanged(self):
        write(self.g.host, "OMACVM_FULLPANEL=surprise\n")
        with self.assertRaises(ValueError):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.mode(True)
        write(self.g.config, "{broken")
        with self.assertRaises(ValueError):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), b"{broken")
        self.assert_protected()

    def test_legacy_omanotch_patcher_does_not_add_fullpanel(self):
        # Import the unchanged Omanotch patcher, which imports FullPanel using
        # its legacy one-argument call. Native QML must remain byte-for-byte.
        omanotch = runpy.run_path(str(HERE.parents[1] / "omanotch/guest/bar/apply-patch.py"))
        text = "// user Omanotch bar\n"
        self.assertEqual(omanotch["fullpanel_patch"](text), text)

    def test_stop_no_block_does_not_allow_live_components_during_selection(self):
        self.mode(True)
        self.g.active.add("notchcast.service")
        self.g.defer_stop = True
        self.g.prepare()
        self.assertFalse(self.g.active)
        self.assertEqual(self.selected(), mod.PLUGIN)
        self.assertEqual(len([c for c in self.g.commands if "kill" in c]), 1)

    def test_in_progress_omanotch_installer_is_never_interrupted(self):
        self.mode(True)
        self.g.active.add("omacvm-omanotch.service")
        with self.assertRaisesRegex(ValueError, "installation is in progress"):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertIn("omacvm-omanotch.service", self.g.active)
        self.assertFalse(any("stop" in c or "kill" in c for c in self.g.commands))
        self.assertFalse(self.g.masks.exists())
        self.assert_protected()
        self.g.active.clear()  # Installer finishes normally before next login.
        self.g.prepare()
        self.assertEqual(self.selected(), mod.PLUGIN)

    def test_fullpanel_with_no_omanotch_units_installed(self):
        self.g.units = {unit: "missing" for unit in mod.UNITS}
        self.mode(True)
        self.g.prepare()
        self.assertEqual(self.selected(), mod.PLUGIN)
        self.assertIn("intentionally suppressed", self.g.status())
        self.assertFalse(any("stop" in c for c in self.g.commands))
        self.mode(False)
        self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertEqual(set(self.g.units.values()), {"missing"})
        self.assert_protected()

    def test_missing_unit_stop_is_rejected_even_with_runtime_mask(self):
        unit = "omacvm-omanotch.service"
        self.g.units[unit] = "missing"
        self.g.mask_dir.mkdir(parents=True)
        (self.g.mask_dir / unit).symlink_to("/dev/null")
        self.g.command("systemctl", "--user", "daemon-reload")
        result = self.g.command("systemctl", "--user", "stop", "--no-block", unit, required=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not loaded", result.stderr)

    def test_running_notchcast_stops_when_other_unit_is_missing(self):
        self.g.units["omacvm-omanotch.service"] = "missing"
        self.g.active.add("notchcast.service")
        self.g.defer_stop = True
        self.mode(True)
        self.g.prepare()
        stops = [c for c in self.g.commands if "stop" in c]
        self.assertEqual(stops, [("systemctl", "--user", "stop", "--no-block", "notchcast.service")])
        self.assertFalse(self.g.active)
        self.assertEqual(self.selected(), mod.PLUGIN)
        self.mode(False)
        self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertEqual(self.g.units["omacvm-omanotch.service"], "missing")
        self.assertIn("notchcast.service", self.g.active)
        self.assert_protected()

    def test_stop_components_accepts_missing_units_without_masks(self):
        self.g.units = {unit: "missing" for unit in mod.UNITS}
        self.g.stop_components()
        self.assertFalse(any("stop" in c for c in self.g.commands))
        self.assertEqual(self.g.config.read_bytes(), self.original)

    def test_real_stop_failure_with_missing_other_unit_preserves_native(self):
        self.g.units["omacvm-omanotch.service"] = "missing"
        self.g.active.add("notchcast.service")
        self.g.fail = "stop"
        self.mode(True)
        with self.assertRaisesRegex(ValueError, "command failed.*stop"):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertFalse(self.g.masks.exists())
        self.assertIn("notchcast.service", self.g.active)
        self.assertEqual(self.g.units["omacvm-omanotch.service"], "missing")
        self.assert_protected()

    def test_process_query_failure_is_not_treated_as_safe_suppression(self):
        self.mode(True)
        command = self.g.command
        def fail_query(*args, **kwargs):
            if args[0] == "pgrep":
                return subprocess.CompletedProcess(args, 2, "", "query failed")
            return command(*args, **kwargs)
        with patch.object(self.g, "command", side_effect=fail_query):
            with self.assertRaisesRegex(ValueError, "cannot check"):
                self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertFalse(self.g.masks.exists())

    def test_empty_default_bar_id_is_preserved_like_omarchy_registry(self):
        config = copy.deepcopy(self.native)
        config["bar"]["id"] = ""
        original = mod.encoded(config)
        write(self.g.config, original)
        self.g.install()
        self.assertIn("Native", self.g.status())
        self.mode(True)
        self.g.prepare()
        self.mode(False)
        self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), original)

    def test_failed_kill_and_unmanaged_process_preserve_native(self):
        self.mode(True)
        self.g.active.add("notchcast.service")
        self.g.defer_stop = True
        self.g.fail = "kill"
        with self.assertRaisesRegex(ValueError, "still running"):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertFalse(self.g.masks.exists())
        self.g.fail = None
        self.g.unmanaged = True
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)

    def test_bounded_process_wait_failure_restores_native_service_state(self):
        self.mode(True)
        self.g.active.add("notchcast.service")
        with patch.object(mod.select, "select", return_value=([], [], [])):
            with self.assertRaisesRegex(ValueError, "did not stop"):
                self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertIn("notchcast.service", self.g.active)

    def test_interrupted_suppression_recovers_recorded_masks_before_selection(self):
        self.mode(True)
        write(self.g.masks, mod.encoded({"owned": list(mod.UNITS), "active": ["notchcast.service"]}))
        self.g.active.add("notchcast.service")
        (self.g.mask_dir).mkdir(parents=True)
        (self.g.mask_dir / mod.UNITS[0]).symlink_to("/dev/null")
        self.g.prepare()
        self.assertEqual(set(self.g.units.values()), {"masked-runtime"})
        self.assertFalse(self.g.active)
        self.mode(False)
        self.g.prepare()
        self.assertIn("notchcast.service", self.g.active)
        self.assert_protected()

    def test_native_selection_is_committed_before_service_restart(self):
        self.mode(True)
        self.g.active.add("notchcast.service")
        self.g.prepare()
        self.mode(False)
        command = self.g.command
        def checked(*args, **kwargs):
            if "start" in args:
                self.assertEqual(self.g.config.read_bytes(), self.original)
            return command(*args, **kwargs)
        with patch.object(self.g, "command", side_effect=checked):
            self.g.prepare()

    def test_native_restore_failure_retains_previous_bar_and_suppression(self):
        self.mode(True)
        self.g.prepare()
        before = self.g.config.read_bytes()
        self.mode(False)
        self.g.fail = "daemon-reload"
        with self.assertRaises(ValueError):
            self.g.prepare()
        # Suppression fails before native selection is committed. Its existing
        # selection and owned runtime overrides must stay in place.
        self.assertEqual(self.g.config.read_bytes(), before)
        self.assertTrue(self.g.masks.exists())
        self.assert_protected()

    def test_unmask_failure_after_native_commit_keeps_safe_native_selection(self):
        self.mode(True)
        self.g.prepare()
        self.mode(False)
        command = self.g.command
        def fail_native_reload(*args, **kwargs):
            result = command(*args, **kwargs)
            if "daemon-reload" in args and self.selected() != mod.PLUGIN:
                raise ValueError("manager reload failed after commit")
            return result
        with patch.object(self.g, "command", side_effect=fail_native_reload):
            with self.assertRaises(ValueError):
                self.g.prepare()
        self.assertEqual(self.g.config.read_bytes(), self.original)
        self.assertTrue(self.g.masks.exists())
        # The next attempt recovers the journal and resumes native services.
        self.g.prepare()
        self.assertFalse(self.g.masks.exists())
        self.assert_protected()

    def test_health_checks_modes_installation_selection_and_service_conflicts(self):
        self.g.install()
        self.assertIn("ready and inactive", self.g.status())
        self.mode(True)
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.g.status()
        self.g.prepare()
        self.assertIn("intentionally suppressed", self.g.status())
        self.g.active.add("notchcast.service")
        with self.assertRaisesRegex(ValueError, "service is running"):
            self.g.status()
        self.g.active.clear()
        self.g.running = True
        self.g.active_bar = "omarchy.bar"
        with self.assertRaisesRegex(ValueError, "QML fallback"):
            self.g.status()
        self.g.running = False
        write(self.g.failed, "incomplete\n")
        with self.assertRaisesRegex(ValueError, "installation failed"):
            self.g.status()
        self.g.failed.unlink()
        (self.g.plugin / "Bar.qml").unlink()
        with self.assertRaises(ValueError):
            self.g.status()

    def test_inactive_plugin_updates_while_native_shell_is_running(self):
        self.g.install()
        self.g.running = True
        write(self.source / "BarModel.js", "// updated stock model\n")
        self.g.install()
        self.assertEqual((self.g.plugin / "BarModel.js").read_text(), "// updated stock model\n")
        self.assertEqual(self.g.config.read_bytes(), self.original)

    def test_health_main_does_not_write_and_startup_lock_never_waits(self):
        self.g.install()
        before = snapshot(self.g.home)
        with patch.object(mod, "FullPanel", return_value=self.g), patch.dict(os.environ, XDG_RUNTIME_DIR=str(self.g.runtime)), patch.object(sys, "argv", ["omacvm-fullpanel", "status"]), patch("sys.stdout"):
            mod.main()
        self.assertEqual(snapshot(self.g.home), before)
        lock = self.g.home / ".local/state/omacvm/fullpanel.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        with lock.open("a") as busy:
            mod.fcntl.flock(busy, mod.fcntl.LOCK_EX | mod.fcntl.LOCK_NB)
            with patch.object(mod, "FullPanel", return_value=self.g), patch.dict(os.environ, XDG_RUNTIME_DIR=str(self.g.runtime)), patch.object(sys, "argv", ["omacvm-fullpanel", "prepare"]):
                with self.assertRaises(BlockingIOError):
                    mod.main()

    def test_installer_failure_is_not_swallowed_by_app_workflow(self):
        # Execute just the FullPanel boundary from the supported app installer
        # in a fixture, without running its unrelated install steps.
        root = Path(self.tmp.name)
        write(root / "fullpanel-install.sh", "#!/bin/bash\nexit 9\n")
        source = (HERE / "install.sh").read_text()
        begin = source.index('bash fullpanel-install.sh "$U"')
        end = source.index("# HDR", begin)
        result = subprocess.run(["/bin/bash", "-c", 'U=fixture\n' + source[begin:end]], cwd=root, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"failed during: FullPanel", result.stderr)


if __name__ == "__main__":
    unittest.main()
