#!/usr/bin/env python3
"""Install/select FullPanel's bar at config load, before Omarchy launches its shell.

No process is kept running. Native plugins, theme files and persistent unit
settings are never written. Run as the desktop user, through install.sh or
hypr.omacvm_fullpanel. The host signal is fixed for each VM boot.
"""
from __future__ import annotations

import argparse
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time

PLUGIN = "omacvm.fullpanel.bar"
OWNER = ".omacvm-fullpanel"
UNITS = ("notchcast.service", "omacvm-omanotch.service")
LIMIT = 2 * 1024 * 1024


def read(path: Path) -> bytes | None:
    if path.is_symlink():
        raise ValueError(f"refusing symlink: {path}")
    if not path.exists():
        return None
    if not path.is_file() or path.stat().st_size > LIMIT:
        raise ValueError(f"not a bounded regular file: {path}")
    return path.read_bytes()


def atomic(path: Path, data: bytes, expected: bytes | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    pending = Path(name)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            os.fchmod(out.fileno(), path.stat().st_mode & 0o777 if path.exists() else 0o600)
            out.flush()
            os.fsync(out.fileno())
        if read(path) != expected:
            raise ValueError(f"concurrent edit; left unchanged: {path}")
        os.replace(pending, path)
    finally:
        pending.unlink(missing_ok=True)


def encoded(value) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def object_from(raw: bytes | None, label: str) -> dict:
    value = json.loads(raw) if raw is not None else None
    if not isinstance(value, dict):
        raise ValueError(f"invalid {label}")
    return value


class FullPanel:
    def __init__(self, home: Path, omarchy: Path, runtime: Path,
                 host: Path, layout: Path):
        self.home, self.omarchy, self.runtime = home, omarchy, runtime
        self.host, self.layout = host, layout
        # Omarchy itself uses these HOME paths (not XDG_CONFIG_HOME).
        self.config = home / ".config/omarchy/shell.json"
        self.plugin = home / ".config/omarchy/plugins" / PLUGIN
        self.options = home / ".config/omacvm/fullpanel-bar.json"
        self.state = home / ".local/state/omacvm/fullpanel-native.json"
        self.failed = home / ".local/state/omacvm/fullpanel-install-failed"
        self.masks = runtime / "omacvm/fullpanel-masks.json"
        # Ordinary --runtime masks are below ~/.config/systemd/user in the
        # search path and cannot suppress Omanotch's locally installed unit.
        # Runtime control overrides precede it; original unit files stay put.
        self.mask_dir = runtime / "systemd/user.control"

    def command(self, *args, required=True):
        result = subprocess.run(args, capture_output=True, text=True, timeout=4)
        if required and result.returncode:
            raise ValueError(f"{' '.join(args)}: {result.stderr.strip() or result.stdout.strip()}")
        return result

    def shell_running(self):
        return self.command("omarchy-shell", "shell", "ping", required=False).returncode == 0

    def notchcast_running(self):
        result = self.command("pgrep", "-u", str(os.getuid()), "-x", "notchcast", required=False)
        if result.returncode not in (0, 1):
            raise ValueError("cannot check for conflicting notchcast processes")
        return result.returncode == 0

    def install(self):
        """Build from the stock plugin, validate, then publish only our directory."""
        source = self.omarchy / "shell/plugins/bar"
        manifest = object_from(read(source / "manifest.json"), "stock bar manifest")
        if manifest.get("id") != "omarchy.bar" or manifest.get("entryPoints", {}).get("bar") != "Bar.qml":
            raise ValueError("unsupported stock bar manifest")
        if self.plugin.is_symlink() or (self.plugin.exists() and read(self.plugin / OWNER) != b"1\n"):
            raise ValueError(f"unmanaged plugin at {self.plugin}; left unchanged")
        if any(p.is_symlink() for p in source.rglob("*")) or any(p.is_symlink() for p in self.plugin.rglob("*")):
            raise ValueError("bar plugin contains symlinks; left unchanged")
        spec = importlib.util.spec_from_file_location("fullpanel_layout", self.layout)
        layout = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(layout)
        self.plugin.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".fullpanel-", dir=self.plugin.parent) as tmp:
            stage = Path(tmp) / PLUGIN
            shutil.copytree(source, stage)
            if any(p.is_symlink() for p in stage.rglob("*")):
                raise ValueError("stock bar contains symlinks")
            bar = layout.patch_text((stage / "Bar.qml").read_text(), dedicated=True)
            # Same property defaults needed by any URL-loaded stock bar clone.
            for old, new in (
                ("required property string omarchyPath", 'property string omarchyPath: Quickshell.env("OMARCHY_PATH")'),
                ("required property var barWidgetRegistry", "property var barWidgetRegistry: null"),
                ("required property var barConfig", "property var barConfig: ({})"),
            ):
                bar = bar.replace(old, new)
            # Omanotch's compositor may still have its hidden output. Our bar
            # never draws onto it and supplies no notchbar IPC/parking code.
            anchor = "model: Quickshell.screens"
            if anchor not in bar:
                raise ValueError("unsupported bar screen model")
            bar = bar.replace(anchor, 'model: Quickshell.screens.filter(s => !String(s.name).startsWith("NOTCH"))')
            (stage / "Bar.qml").write_text(bar)
            manifest.update(id=PLUGIN, name="OmacVM FullPanel", author="OmacVM")
            # Registry IPC aliases and capability inheritance require this
            # metadata. It refers to stock Omarchy, never an Omanotch clone.
            manifest["omarchy"] = {"clonedFrom": "omarchy.bar"}
            (stage / "manifest.json").write_bytes(encoded(manifest))
            (stage / OWNER).write_bytes(b"1\n")
            self.command("omarchy-plugin-validate", str(stage))
            def contents(folder):
                return {str(p.relative_to(folder)): p.read_bytes() for p in folder.rglob("*") if p.is_file()}
            if self.plugin.exists() and contents(stage) == contents(self.plugin):
                return
            current = object_from(read(self.config), "shell.json") if read(self.config) is not None else {}
            if self.plugin.exists() and current.get("bar", {}).get("id") == PLUGIN and self.shell_running():
                raise ValueError("bar update deferred until the next session; running plugin left unchanged")
            previous = Path(tmp) / "previous"
            if self.plugin.exists():
                os.replace(self.plugin, previous)
            try:
                os.replace(stage, self.plugin)
            except OSError:
                if previous.exists():
                    os.replace(previous, self.plugin)
                raise

    def mode(self):
        raw = read(self.host)
        if raw is None:
            raise ValueError("host.env is missing; retaining the current bar")
        flags = [line.split("=", 1)[1] for line in raw.decode("ascii").splitlines()
                 if line.startswith("OMACVM_FULLPANEL=")]
        if flags and flags != ["1"] and flags != ["0"]:
            raise ValueError("invalid FullPanel host signal; retaining the current bar")
        return flags == ["1"]

    def available(self, bar):
        ident = bar.get("id") or "omarchy.bar"
        if ident == "omarchy.bar":
            return
        if not isinstance(ident, str) or not ident or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in ident) or ".." in ident:
            raise ValueError("invalid saved bar id")
        manifest = object_from(read(self.plugin.parent / ident / "manifest.json"), "saved bar manifest")
        if manifest.get("id") != ident or "bar" not in manifest.get("kinds", []):
            raise ValueError("original bar is unavailable; retaining the current bar")
        entry = manifest.get("entryPoints", {}).get("bar")
        if not isinstance(entry, str) or Path(entry).is_absolute() or ".." in Path(entry).parts or read(self.plugin.parent / ident / entry) is None:
            raise ValueError("original bar entry point is unavailable; retaining the current bar")

    def working_plugin(self):
        if read(self.plugin / OWNER) != b"1\n":
            raise ValueError("managed FullPanel plugin is missing")
        self.available({"id": PLUGIN})
        manifest = object_from(read(self.plugin / "manifest.json"), "FullPanel manifest")
        if manifest.get("omarchy", {}).get("clonedFrom") != "omarchy.bar":
            raise ValueError("FullPanel bar capability metadata is missing; run OmacVM apply/update")
        spec = importlib.util.spec_from_file_location("fullpanel_layout", self.layout)
        layout = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(layout)
        layout.validate_v4(read(self.plugin / "Bar.qml").decode())

    def native_record(self):
        record = object_from(read(self.state), "native bar restore record")
        native_bar = record.get("bar")
        if (record.get("version") != 1 or not isinstance(native_bar, dict)
                or native_bar.get("id") == PLUGIN or not isinstance(record.get("selected"), str)
                or (record.get("original") is not None and not isinstance(record["original"], str))):
            raise ValueError("invalid native bar restore record; retaining the current bar")
        return record

    def unit_processes(self, unit):
        result = self.command("systemctl", "--user", "show", "--property=MainPID", "--property=ControlPID", unit, required=False)
        if result.returncode:
            state = self.command("systemctl", "--user", "show", "--property=LoadState", "--value", unit, required=False).stdout.strip()
            if state == "not-found":
                return set()  # Omanotch may never have been installed/enabled.
            raise ValueError(f"cannot determine {unit} processes; retaining the current bar")
        fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        if set(fields) != {"MainPID", "ControlPID"} or any(not p.isdecimal() for p in fields.values()):
            raise ValueError(f"cannot determine {unit} processes; retaining the current bar")
        return {int(p) for p in fields.values() if int(p)}

    def stop_components(self):
        # Stop jobs cannot be waited for here: ExecStopPost calls Hyprland
        # while its synchronous config loader is waiting for us. Pin current
        # service PIDs, queue stops, then kill the service cgroups and wait
        # briefly for those processes to exit (pidfds, no polling). Masking
        # prevents a queued start/restart from launching another installer.
        descriptors = []
        running = []
        try:
            for unit in UNITS:
                pids = self.unit_processes(unit)
                if unit == "omacvm-omanotch.service" and pids:
                    raise ValueError("Omanotch installation is in progress; retaining the current bar; try the next session")
                if pids:
                    running.append(unit)
                for pid in pids:
                    if not hasattr(os, "pidfd_open"):
                        raise ValueError("safe service switching requires Linux pidfd support")
                    try:
                        descriptors.append(os.pidfd_open(pid))
                    except ProcessLookupError:
                        pass
            # Masks already prevent new starts. Inactive units need no stop
            # job: systemd can reject one when Omanotch was never installed.
            if running:
                self.command("systemctl", "--user", "stop", "--no-block", *running)
            for unit in running:
                # A unit may already have exited between stop and kill. Its
                # pinned PIDs and the subsequent process check are authoritative.
                self.command("systemctl", "--user", "kill", "--kill-whom=all", "--signal=SIGKILL", unit, required=False)
            deadline = time.monotonic() + 2
            for fd in descriptors:
                if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                    raise ValueError("Omanotch process did not stop; retaining the current bar")
            for unit in UNITS:
                if self.unit_processes(unit):
                    raise ValueError(f"{unit} is still running; retaining the current bar")
            if self.notchcast_running():
                raise ValueError("unmanaged notchcast is running; retaining the current bar")
        finally:
            for fd in descriptors:
                os.close(fd)

    def suppress(self, rollback=True):
        """Own only runtime masks we create; remember active units for rollback."""
        # Do not interrupt an installer that may be writing the native clone.
        # Recheck after masking too, in case a pending start raced this check.
        if self.unit_processes("omacvm-omanotch.service"):
            raise ValueError("Omanotch installation is in progress; retaining the current bar; try the next session")
        if read(self.masks) is not None:
            owned, active = self.mask_record()
        else:
            owned, active = [], []
            for unit in UNITS:
                status = self.command("systemctl", "--user", "is-enabled", unit, required=False).stdout.strip()
                if status not in ("masked", "masked-runtime"):
                    path = self.mask_dir / unit
                    if path.exists() or path.is_symlink():
                        raise ValueError(f"existing runtime override at {path}; left unchanged")
                    owned.append(unit)
                    if self.command("systemctl", "--user", "is-active", "--quiet", unit, required=False).returncode == 0:
                        active.append(unit)
            atomic(self.masks, encoded({"owned": owned, "active": active}), None)
        try:
            self.mask_dir.mkdir(parents=True, exist_ok=True)
            for unit in owned:
                path = self.mask_dir / unit
                if path.is_symlink() and os.readlink(path) == "/dev/null":
                    continue
                if path.exists() or path.is_symlink():
                    raise ValueError(f"runtime override changed at {path}; left unchanged")
                path.symlink_to("/dev/null")
            if owned:
                self.command("systemctl", "--user", "daemon-reload")
            for unit in UNITS:
                if self.command("systemctl", "--user", "show", "--property=LoadState", "--value", unit).stdout.strip() != "masked":
                    raise ValueError(f"{unit} could not be suppressed; retaining the native bar")
            self.stop_components()
        except (OSError, ValueError, subprocess.SubprocessError):
            if rollback:
                self.unsuppress(rollback=True)
            raise

    def mask_record(self):
        raw = read(self.masks)
        masks = object_from(raw, "runtime mask record")
        owned, active = masks.get("owned", []), masks.get("active", [])
        if not isinstance(owned, list) or not isinstance(active, list) or any(u not in UNITS for u in owned + active):
            raise ValueError("invalid runtime mask record")
        return owned, active

    def unsuppress(self, rollback=False):
        if read(self.masks) is None:
            return
        owned, active = self.mask_record()
        if owned:
            # Check every path before changing any override.
            for unit in owned:
                path = self.mask_dir / unit
                if (path.exists() or path.is_symlink()) and not (path.is_symlink() and os.readlink(path) == "/dev/null"):
                    raise ValueError(f"runtime override changed at {path}; left unchanged")
            for unit in owned:
                (self.mask_dir / unit).unlink(missing_ok=True)
            self.command("systemctl", "--user", "daemon-reload")
        if rollback and active:
            self.command("systemctl", "--user", "start", "--no-block", *active)
        self.masks.unlink()

    def prepare(self):
        fullpanel = self.mode()
        original = read(self.config)
        config = object_from(original if original is not None else read(self.omarchy / "config/omarchy/shell.json"), "shell.json")
        bar = config.get("bar")
        if config.get("version") != 1 or not isinstance(bar, dict):
            raise ValueError("unsupported shell.json; retaining the current bar")
        selected = bar.get("id") == PLUGIN
        if not fullpanel and not selected:
            self.unsuppress(rollback=True)
            return  # Disabled: no plugin install, config write or unit changes.
        # Never write behind a shell's in-memory config or launch another shell.
        if self.shell_running():
            if fullpanel and selected:
                self.status()  # Config reloads must not conceal broken suppression.
                return
            raise ValueError("mode change deferred until the next session; running bar left unchanged")
        if selected:
            # A failed native restore still launches the last FullPanel bar.
            # Keep its conflicting display services suppressed on this boot,
            # even though the previous boot's runtime masks have expired.
            self.suppress(rollback=False)
        if fullpanel:
            if read(self.failed) is not None and not selected:
                raise ValueError("FullPanel installation failed or is incomplete; retaining the native bar")
            if selected:
                if read(self.state) is None:
                    raise ValueError("native bar restore record missing; retaining the current bar")
                try:
                    self.install()
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    self.working_plugin()
                    print(f"FullPanel: update failed; using the previous validated plugin: {error}", file=sys.stderr)
                self.working_plugin()
                return
            self.install()
            options_raw = read(self.options)
            options = object_from(options_raw, "FullPanel bar config") if options_raw is not None else copy.deepcopy(bar)
            options["id"] = PLUGIN
            # FullPanel has its own bar settings. Unrelated shell settings stay
            # in the canonical shell.json; native bar options are saved intact.
            next_config = copy.deepcopy(config)
            next_config["bar"] = options
            next_raw = encoded(next_config)
            record = {"version": 1, "bar": bar, "original": original.decode() if original is not None else None,
                      "selected": next_raw.decode()}
            atomic(self.state, encoded(record), read(self.state))
            self.suppress()
            try:
                atomic(self.options, encoded(options), options_raw)
                atomic(self.config, next_raw, original)
            except (OSError, ValueError):
                self.unsuppress(rollback=True)
                raise
        else:
            record = self.native_record()
            native_bar = record["bar"]
            self.available(native_bar)
            atomic(self.options, encoded(bar), read(self.options))
            # A first login can start in FullPanel before OmacVM's existing
            # pending-plugins job places the widgets. There was no user bar
            # config to preserve yet: carry those placements into native too.
            if record.get("original") is None:
                fresh_bar = copy.deepcopy(bar)
                fresh_bar.pop("id", None)
                if "id" in native_bar:
                    fresh_bar["id"] = native_bar["id"]
                native_bar = fresh_bar
            config["bar"] = native_bar
            # Restore exact original bytes when no other settings changed.
            restored = record["original"] if original.decode() == record["selected"] else encoded(config).decode()
            try:
                if restored is None:
                    if read(self.config) != original:
                        raise ValueError("concurrent shell.json edit")
                    self.config.unlink()
                else:
                    atomic(self.config, restored.encode(), original)
                # Commit native selection before restarting any native service.
                self.unsuppress(rollback=True)
            except (OSError, ValueError):
                # Never put the FullPanel selection back before its display
                # services have been suppressed again. If that fails, the
                # validated native bar is the safe remaining selection.
                self.suppress(rollback=False)
                if read(self.config) != original:
                    atomic(self.config, original, read(self.config))
                raise
            # Keep the record: recovery after an interrupted switch is safe.

    def status(self):
        """Read-only readiness and actual boot-mode checks, also used by check."""
        self.working_plugin()
        if read(self.failed) is not None:
            raise ValueError("FullPanel guest installation failed or is incomplete; run OmacVM apply/update")
        hook = read(self.home / ".config/hypr/omacvm_fullpanel.lua")
        hypr = read(self.home / ".config/hypr/hyprland.lua")
        if hook is None or b'omacvm-fullpanel prepare' not in hook or hypr is None or b'require("hypr.omacvm_fullpanel")' not in hypr:
            raise ValueError("FullPanel startup hook is missing; run OmacVM apply/update")
        fullpanel = self.mode()
        raw = read(self.config)
        config = object_from(raw if raw is not None else read(self.omarchy / "config/omarchy/shell.json"), "shell.json")
        if config.get("version") != 1 or not isinstance(config.get("bar"), dict):
            raise ValueError("unsupported shell.json")
        selected = config["bar"].get("id") or "omarchy.bar"
        if (selected == PLUGIN) != fullpanel:
            raise ValueError("active bar selection does not match this VM start's fullscreen mode")
        self.available(config.get("bar", {}))
        if fullpanel:
            if read(self.state) is None:
                raise ValueError("native bar restore record is missing")
            self.available(self.native_record()["bar"])
            for unit in UNITS:
                if self.command("systemctl", "--user", "show", "--property=LoadState", "--value", unit).stdout.strip() != "masked":
                    raise ValueError(f"conflicting service is not suppressed: {unit}")
                if self.command("systemctl", "--user", "show", "--property=MainPID", "--value", unit).stdout.strip() != "0":
                    raise ValueError(f"conflicting service is running: {unit}")
            if self.notchcast_running():
                raise ValueError("conflicting notchcast process is running")
        elif read(self.masks) is not None:
            raise ValueError("FullPanel runtime masks remain in native mode")
        if self.shell_running():
            plugins = json.loads(self.command("omarchy-shell", "shell", "listPlugins").stdout)
            if not isinstance(plugins, list) or [p.get("id") for p in plugins if p.get("active") and "bar" in p.get("kinds", [])] != [selected]:
                raise ValueError("shell is not running the selected bar (missing plugin or QML fallback)")
        return "Full Panel (Experimental); Omanotch intentionally suppressed" if fullpanel else "Native; FullPanel guest components ready and inactive"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "prepare", "status"))
    args = parser.parse_args()
    app = FullPanel(Path.home(), Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")),
                    Path(os.environ["XDG_RUNTIME_DIR"]), Path("/run/omacvm/host.env"),
                    Path("/usr/local/lib/omacvm/fullpanel-bar.py"))
    if args.action == "status":
        print(app.status())
        return  # Checks do not create state directories or a lock file.
    lock = app.home / ".local/state/omacvm/fullpanel.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open("a") as stream:
        # A concurrent install must never hold synchronous Hyprland startup.
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        getattr(app, args.action)()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"FullPanel: {error}", file=sys.stderr)
        sys.exit(1)
