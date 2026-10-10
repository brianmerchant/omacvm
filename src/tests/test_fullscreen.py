#!/usr/bin/env python3
"""CLI setup/configuration and check boundaries, with no Mac or VM changes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FullscreenTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # Run the real CLI scripts in an isolated miniature checkout. Only
        # their platform/build dependencies are fakes; no app or guest starts.
        for path in ("omacvm", "src/VERSION", "src/features.tsv", "src/cmd/build.sh",
                     "src/cmd/fullscreen.sh", "src/lib/app.sh", "src/lib/version.sh",
                     "src/lib/features.sh", "src/lib/setup.sh"):
            dest = self.root / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, dest)
            dest.chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Redirect the build's logs/key paths in its temporary copy too. All
        # external operations remain mocked, including the post-build reboot.
        build = self.root / "src/cmd/build.sh"
        build.write_text(build.read_text().replace('BUILD_LOG=~/Library/Logs/', 'BUILD_LOG=$FIX_ROOT/logs/')
                         .replace('mkdir -p "$HOME/Library/Logs"', 'mkdir -p "$FIX_ROOT/logs"')
                         .replace('exec > >(tee -a "$BUILD_LOG") 2>&1', ': # log redirection mocked')
                         .replace('KEY=~/.ssh/omacvm', 'KEY=$FIX_ROOT/ssh-key'))
        (self.root / "ssh-key").write_text("fixture key\n")
        self.prefs = self.root / "preferences.json"
        self.prefs.write_text(json.dumps({"unrelated": "keep"}))
        self.events = self.root / "events"
        self.terminal = self.root / "terminal"
        self.terminal.write_text("fixture\n")
        self.executable("defaults", "#!" + sys.executable + '''
import json, os, pathlib, sys
p = pathlib.Path(os.environ["FIX_PREFS"])
data = json.loads(p.read_text())
args = sys.argv[1:]
if args == ["read", "-g", "AppleLanguages"]: print("(\\nen\\n)")
elif args == ["read", "-g", "AppleLocale"]: print("en_US")
elif args[:1] == ["read"]:
    value = data.get(args[1], {}).get(args[2])
    if value is None: sys.exit(1)
    print(value)
elif args[:1] == ["write"]:
    assert args[2:4] == ["fullScreenMode", "-string"]
    if os.environ.get("FAIL_PREFS"): sys.exit(1)
    data.setdefault(args[1], {})[args[2]] = args[4]
    p.write_text(json.dumps(data))
else: raise AssertionError(args)
''')
        for name, body in {
            "uname": 'echo arm64', "sw_vers": 'echo 15.7',
            "diskutil": 'echo fixture', "plutil": 'echo apfs',
            "readlink": 'echo /var/db/timezone/zoneinfo/UTC',
        }.items():
            self.executable(name, "#!/bin/bash\n" + body + "\n")
        self.write("src/keyboard/mac-layout.sh", "#!/bin/bash\necho us\n", executable=True)
        self.write("src/cmd/apply.sh", '#!/bin/bash\nprintf "apply %s\\n" "$*" >> "$FIX_EVENTS"\nexit "${FAIL_APPLY:-0}"\n', executable=True)
        self.write("stub.sh", r'''
TTY=$FIX_TERMINAL; UI_FANCY=0; SPACE_NOTE=""; SPACE_VM_GB=30
KEY=fixture; UB=""; UR=""; README_ROUTES=fixture
ui_restore() { :; }
log() { :; }; info() { :; }; say() { :; }; hd() { :; }; step() { :; }
die() { echo "$*" >&2; exit 1; }
mac_specs() { mac_cores=8; mac_perf=4; mac_eff=4; mac_mem_gb=32; }
free_gb_at() { echo 500; }
mac_tool() { echo notch; }
have_xcode_tools() { return 0; }; ensure_xcode_tools() { :; }; ensure_swift_works() { :; }
ensure_vm_app() { :; }; prereq_screen() { :; }
app_bundle() { echo "$FIX_ROOT/Fake.app"; }
app_version() { cat "$FIX_ROOT/src/VERSION"; }
app_other_running() { return 1; }; app_missing_drive() { return 1; }
app_vms_root() { echo "$FIX_ROOT/vms"; }
app_has_prebuilt() { return 1; }; prebuilt_lookup() { return 1; }
app_prebuilt_lookup() { return 1; }
vm_taken() { return 1; }; vm_taken_info() { :; }
vms_list() { :; }; fusion_bundle() { echo "$FIX_ROOT/unused"; }
space_problem() { return 0; }
omarchy_channel() { echo stable; }
json_str() { "$FIX_PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ui_select() {
  printf 'question %s\n' "$2" >> "$FIX_EVENTS"
  case $2 in "Full screen mode"*) printf -v "$1" '%s' "${PICK_MODE:-$3}" ;; *) printf -v "$1" '%s' "$3" ;; esac
}
ui_checklist() { :; }; ask_value() { echo "$2"; }; ask_yn() { return 0; }
app_free_port() { echo 52222; }
app_create() { cat >/dev/null; printf 'create %s\n' "$(app_fullscreen_choice)" >> "$FIX_EVENTS"; }
ui_follow() { cat; }; ui_step() { :; }
app_ip() { echo fixture; }; vm_pin() { :; }
gssh() { printf 'guest-action %s\n' "$*" >> "$FIX_EVENTS"; }
''')
        self.write("bash-env.sh", r'''
source() {
  case $1 in
    */src/lib/mac.sh) builtin source "$FIX_ROOT/src/lib/app.sh" ;;
    */src/lib/app.sh|*/src/lib/version.sh|*/src/lib/features.sh|*/src/lib/setup.sh) builtin source "$1" ;;
    *) : ;;
  esac
  # Last build library, or UI for the later configuration flow.
  case $1 in */src/lib/space.sh|*/src/lib/ui.sh) builtin source "$FIX_ROOT/stub.sh" ;; esac
}
builtin source "$FIX_ROOT/stub.sh"
''')
        self.env = dict(os.environ, FIX_ROOT=str(self.root), FIX_PREFS=str(self.prefs),
                        FIX_EVENTS=str(self.events), FIX_TERMINAL=str(self.terminal), FIX_PYTHON=sys.executable,
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        BASH_ENV=str(self.root / "bash-env.sh"), TMPDIR=str(self.root),
                        OMACVM_APP_NEWER_SAID="1", PYTHONDONTWRITEBYTECODE="1")
        for key in ("OMACVM_APP_ID", "OMACVM_TEST_IDENTITY", "OMACVM_PASSWORD", "OMACVM_APP_COPY"):
            self.env.pop(key, None)

    def write(self, path, text, executable=False):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        if executable:
            dest.chmod(0o755)

    def executable(self, name, body):
        self.write("bin/" + name, body, executable=True)

    def cli(self, *args, **env):
        return subprocess.run(["/bin/bash", str(self.root / "omacvm"), *args],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=20)

    def build(self, *args, **env):
        return self.cli("build", "--build", "--vm-type", "app", "--user", "fixture", "--full-name", "Fixture",
                        "--vm-name", "Fixture", "--resources", "balanced", *args, **env)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_default_native_and_shared_gui_preference_roundtrip(self):
        self.assertEqual(json.loads(self.cli("fullscreen", "--json").stdout)["fullscreen_mode"], "native")
        result = self.cli("fullscreen", "fullpanel", "--json")
        self.assert_ok(result)
        self.assertTrue(json.loads(result.stdout)["changed"])
        data = json.loads(self.prefs.read_text())
        self.assertEqual(data, {"unrelated": "keep", "org.omacvm.app": {"fullScreenMode": "fullPanel"}})
        # Simulate the GUI changing precisely that same UserDefaults key.
        data["org.omacvm.app"]["fullScreenMode"] = "native"
        self.prefs.write_text(json.dumps(data))
        self.assertEqual(json.loads(self.cli("fullscreen", "--json").stdout)["fullscreen_mode"], "native")
        self.assertIn('UserDefaults.standard.set(newValue.rawValue, forKey: "fullScreenMode")',
                      (ROOT / "app/app/Sources/OmacVM/Model.swift").read_text())

    def test_fresh_cli_install_native_and_fullpanel(self):
        for mode in ("native", "fullpanel"):
            result = self.build("--yes", "--fullscreen-mode", mode, OMACVM_PASSWORD="fixture")
            self.assert_ok(result)
            self.assertEqual(json.loads(self.cli("fullscreen", "--json").stdout)["fullscreen_mode"], mode)
            events = self.events.read_text()
            self.assertIn("create " + mode, events)
            self.assertIn("apply --vm Fixture --vm-type app", events)
            self.assertNotIn("--feature fullpanel", events)

    def test_interactive_installer_and_later_cli_configuration(self):
        result = self.build("--dry-run", PICK_MODE="1")
        self.assert_ok(result)
        self.assertIn("Full Panel (Experimental)", result.stdout)
        self.assertIn("question Full screen mode (OmacVM.app Settings, all app VMs)", self.events.read_text())
        self.assertNotIn("org.omacvm.app", json.loads(self.prefs.read_text()))
        result = self.cli("fullscreen", "--configure", PICK_MODE="1")
        self.assert_ok(result)
        self.assertEqual(json.loads(self.cli("fullscreen", "--json").stdout)["fullscreen_mode"], "fullpanel")

    def test_existing_selection_survives_setup_and_plans_do_not_write(self):
        self.assert_ok(self.cli("fullscreen", "fullpanel"))
        before = self.prefs.read_bytes()
        result = self.build("--plan", "--json")
        self.assert_ok(result)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["fullscreen_mode"], "fullpanel")
        self.assertIn("--fullscreen-mode fullpanel", plan["command"])
        result = self.build("--plan", "--json", "--fullscreen-mode", "native")
        self.assert_ok(result)
        self.assertEqual(json.loads(result.stdout)["fullscreen_mode"], "native")
        self.assertEqual(self.prefs.read_bytes(), before)
        self.assert_ok(self.build("--yes", OMACVM_PASSWORD="fixture"))
        self.assertEqual(self.prefs.read_bytes(), before)

    def test_failures_surface_without_building_or_claiming_success(self):
        result = self.build("--yes", "--fullscreen-mode", "fullpanel", OMACVM_PASSWORD="fixture", FAIL_PREFS="1")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.events.exists())
        result = self.build("--yes", OMACVM_PASSWORD="fixture", FAIL_APPLY="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Done in", result.stdout)

    def test_invalid_modes_and_other_routes_reject_mode_option(self):
        self.assertEqual(self.cli("fullscreen", "invalid").returncode, 2)
        self.assertEqual(self.build("--yes", "--fullscreen-mode", "invalid").returncode, 2)
        self.assertEqual(self.build("--yes", "--fullscreen-mode").returncode, 2)
        result = self.build("--yes", "--vm-type", "utm", "--fullscreen-mode", "fullpanel")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--vm-type app", result.stderr)
        self.assertNotIn("fullpanel", (ROOT / "src/features.tsv").read_text().lower())

    def test_test_identity_isolated_from_production_preferences(self):
        self.assert_ok(self.cli("fullscreen", "fullpanel", OMACVM_TEST_IDENTITY="1"))
        self.assertEqual(json.loads(self.prefs.read_text())["org.omacvm.app.test"]["fullScreenMode"], "fullPanel")
        self.assertEqual(json.loads(self.cli("fullscreen", "--json").stdout)["fullscreen_mode"], "native")

    def check_fragment(self, source, text, *, fullpanel=False, component=True, failed=False, setup=""):
        """Execute the actual check boundaries; paths/commands are fixtures."""
        host = self.root / "host.env"
        host.write_text("OMACVM_FULLPANEL=1\n" if fullpanel else "OMACVM_FULLPANEL=0\n")
        helper = self.root / "omacvm-fullpanel"
        if component:
            helper.write_text("fixture\n")
            helper.chmod(0o755)
        elif helper.exists():
            helper.unlink()
        common = '''
TYPE=app; FULLPANEL=%s; OMANOTCH=on; H="$FIX_ROOT/home"; U=fixture; HOST=fixture
ok() { echo "OK $1 $2"; }; bad() { echo "FAIL $1 $2"; }; skip() { echo "SKIP $1 $2"; }
feat() { echo on; }; pgrep() { return 0; }; defaults() { echo 0; }
omanotch_serves_app() { echo "UNEXPECTED native version check"; return 1; }
as_user() { echo "%s"; return %s; }
connected_to() { return 0; }
systemctl() { echo notchcast; }
''' % (int(fullpanel), "FullPanel installation failed" if failed else "guest mode ready", int(failed))
        code = common + setup + text.replace("/run/omacvm/host.env", str(host)).replace("/usr/local/bin/omacvm-fullpanel", str(helper))
        result = subprocess.run(["/bin/bash", "-c", code], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, source + result.stderr)
        return result.stdout

    def test_guest_checks_readiness_in_native_and_fullpanel_modes(self):
        source = (ROOT / "src/guest/check.sh").read_text()
        begin = source.index("  # FullPanel components are always")
        end = source.index("  # Which UEFI firmware", begin)
        fragment = source[begin:end]
        for fp in (False, True):
            self.assertIn("OK Full screen mode", self.check_fragment("guest", fragment, fullpanel=fp))
            self.assertIn("FAIL Full screen mode FullPanel guest components missing",
                          self.check_fragment("guest", fragment, fullpanel=fp, component=False))
            self.assertIn("FAIL Full screen mode FullPanel installation failed",
                          self.check_fragment("guest", fragment, fullpanel=fp, failed=True))

    def test_guest_omanotch_streaming_check_is_mode_aware(self):
        source = (ROOT / "src/guest/check.sh").read_text()
        begin = source.index('if [[ $TYPE == app ]] && grep -qx \'OMACVM_FULLPANEL=1\'')
        end = source.index("  # The hidden NOTCH", begin)
        # End this boundary after the original streaming branch; no real
        # Hyprland geometry, network connection or service query is needed.
        fragment = source[begin:end] + "fi\n"
        (self.root / "home/.local/bin").mkdir(parents=True)
        notchcast = self.root / "home/.local/bin/notchcast"
        notchcast.write_text("fixture\n")
        notchcast.chmod(0o755)
        result = self.check_fragment("guest streaming", fragment, fullpanel=True)
        self.assertIn("SKIP Omanotch suppressed", result)
        self.assertNotIn("FAIL", result)
        result = self.check_fragment("guest streaming", fragment)
        self.assertIn("OK Omanotch streaming the bar to the Mac", result)

    def test_mac_streaming_suppression_uses_actual_boot_signal(self):
        source = (ROOT / "src/cmd/check.sh").read_text()
        begin = source.index('if (( FULLPANEL )); then\n  skip "Omanotch (Mac)"')
        end = source.index("# Touch ID", begin)
        result = self.check_fragment("Mac streaming", source[begin:end], fullpanel=True)
        self.assertIn("SKIP Omanotch (Mac) suppressed", result)
        self.assertNotIn("UNEXPECTED", result)
        result = self.check_fragment("Mac streaming", source[begin:end])
        self.assertIn("FAIL Omanotch for OmacVM.app too old", result)
        self.assertIn("grep -qx 'OMACVM_FULLPANEL=1' /run/omacvm/host.env", source)

    def test_mac_links_follow_logged_start_mode_and_keep_real_failures(self):
        source = (ROOT / "src/cmd/check.sh").read_text()
        begin = source.index('# OmacVM.app: what of the Mac this start')
        end = source.index("# OmacVM.app's USB devices", begin)
        setup = '''
builtin source "$FIX_ROOT/src/lib/app.sh"
app_dir() { echo "$FIX_ROOT/vm"; }
'''
        # Runner closes Omanotch for its logged Full Panel choice, even when
        # missing host geometry prevents the guest's FullPanel SMBIOS flag.
        # A known guest FullPanel signal still requires suppression; otherwise
        # unknown/older logs must not excuse closed or incorrectly open links.
        cases = [
            ("fullPanel", True, "off", {}, {}, "OK Mac links (app)"),
            ("fullPanel", False, "off", {}, {}, "OK Mac links (app)"),
            ("fullPanel", True, "on", {}, {}, "still serves it: Omanotch"),
            ("fullPanel", False, "on", {}, {}, "still serves it: Omanotch"),
            ("native", False, "on", {}, {}, "OK Mac links (app)"),
            ("native", True, "on", {}, {}, "still serves it: Omanotch"),
            ("native", False, "off", {}, {}, "closed to the VM since its start: Omanotch"),
            (None, False, "on", {}, {}, "OK Mac links (app)"),
            (None, True, "off", {}, {}, "OK Mac links (app)"),
            (None, False, "off", {}, {}, "closed to the VM since its start: Omanotch"),
            (None, True, "on", {}, {}, "still serves it: Omanotch"),
            ("unknown", True, "off", {}, {}, "OK Mac links (app)"),
            ("unknown", False, "off", {}, {}, "closed to the VM since its start: Omanotch"),
            ("fullPanel", True, "off", {"omanotch": "off"}, {}, "OK Mac links (app)"),
            ("native", False, "on", {"omanotch": "off"}, {}, "still serves it: Omanotch"),
            ("fullPanel", True, "off", {}, {"Gestures": "off"}, "closed to the VM since its start: Gestures"),
            ("fullPanel", True, "off", {"bridge": "off"}, {}, "still serves it: Bridge"),
            ("fullPanel", True, None, {}, {}, "still serves it: Omanotch"),
        ]
        for mode, fp, omanotch, features, overrides, expected in cases:
            with self.subTest(mode=mode, guest_fullpanel=fp, omanotch=omanotch,
                              features=features, overrides=overrides):
                links = dict(Omanotch=omanotch, Gestures="on", Bridge="on", battery="on", camera="on")
                links.update(overrides)
                record = ", ".join(f"{key} {value}" for key, value in links.items() if value is not None)
                record += ", Touch ID off, Touch ID port on, Mac input methods off"
                log = "OmacVM: Mac links: " + record + "\n"
                if mode is not None:
                    log += "OmacVM: full screen mode: " + mode + "\n"
                self.write("vm/logs/qemu.log", log)
                feature_setup = "feat() { case $1 in\n" + "".join(
                    f"{key}) echo {value} ;;\n" for key, value in features.items()
                ) + "*) echo on ;; esac; }\n"
                result = self.check_fragment("Mac links", source[begin:end], fullpanel=fp,
                                             setup=setup + feature_setup)
                self.assertIn(expected, result)
                if expected.startswith("OK"):
                    self.assertNotIn("FAIL", result)
                else:
                    self.assertIn("FAIL Mac links (app)", result)

    def test_mac_links_log_fixture_matches_app_runtime(self):
        runner = (ROOT / "app/app/Sources/OmacVM/Runner.swift").read_text()
        links = (ROOT / "app/app/Sources/OmacVM/MacLinks.swift").read_text()
        begin = runner.index("let fullScreenMode = Settings.fullScreenMode")
        end = runner.index("p.arguments = arguments()", begin)
        self.assertIn("if fullScreenMode == .fullPanel", runner[begin:end])
        self.assertIn("links.omanotch = false", runner[begin:end])
        self.assertIn(r'OmacVM: full screen mode: \(fullScreenMode.rawValue)\n', runner)
        self.assertIn(r'OmacVM: Mac links: \(links.record)\n', runner)
        self.assertIn('("Omanotch", omanotch)', links)
        self.assertIn(r'.map { "\($0.0) \($0.1 ? "on" : "off")" }.joined(separator: ", ")', links)


if __name__ == "__main__":
    unittest.main()
