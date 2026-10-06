#!/usr/bin/env python3
"""Keep Omanotch's hidden NOTCH output out of Omarchy's display panel.

usage: display-panel.py              (install.sh: clone the panel, patch it)
       display-panel.py --refresh    (notchcast start: rebuild a clone that
                                      an Omarchy update left behind)
       display-panel.py --remove     (uninstall.sh: back to Omarchy's panel)
       display-panel.py --patch FILE (patch one Panel.qml in place)

Omarchy's display panel lists every Hyprland output. NOTCH (the strip beside
the notch) is not a display: listed, it can be scaled or switched off there,
which breaks Omanotch. The patch leaves outputs named NOTCH* out of the list,
the count behind the "monitors" section and the bar icon.

The patched copy is the plugin omanotch.monitor in ~/.config/omarchy/plugins,
a clone of Omarchy's panel (clonedFrom omarchy.monitor, so it takes that
widget's place). It is built from Omarchy's panel and built again when that
panel changed (.source-sha256), so it follows Omarchy updates. When the patch
no longer fits Omarchy's panel, Omarchy's own panel is used again. OmacVM.app's
display panel (omacvm.monitor) carries the same patch
(src/app/guest/monitor-widget/build.py): then no clone is made.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

MARK = "omarchy-notch-bar"
VERSION = 1
VERSION_LINE = f"// omarchy-notch-bar display panel patch v{VERSION}"
CLONE_ID = "omanotch.monitor"

HELPERS = f"""  // --- omarchy-notch-bar ------------------------------------------------
  {VERSION_LINE}
  // Outputs named NOTCH* are Omanotch's hidden strip beside the notch, not
  // displays: left out of the list, the count and the bar icon.
  function notchHidden(name) {{
    return String(name || "").indexOf("NOTCH") === 0
  }}
  function notchScreenCount() {{
    var n = 0
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i] && !notchHidden(Quickshell.screens[i].name)) n++
    return n
  }}
  function notchFilterJson(raw) {{
    try {{
      var list = JSON.parse(String(raw || "[]"))
      if (Array.isArray(list))
        return JSON.stringify(list.filter(function(d) {{ return !(d && notchHidden(d.name)) }}))
    }} catch (e) {{}}
    return raw
  }}
  // --- end omarchy-notch-bar --------------------------------------------
"""

# (anchor, replacement): every anchor must be found exactly once.
EDITS = [
    ("  property var displays: []\n",
     "  property var displays: []\n" + HELPERS),
    ("    var parsed = Model.parseDisplays(displaysJson)\n",
     "    var parsed = Model.parseDisplays(root.notchFilterJson(displaysJson))\n"),
    ('    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"\n',
     '    text: root.notchScreenCount() > 1 ? "󰍺" : "󰍹"\n'),
]


def patch(text):
    """Omarchy's Panel.qml with NOTCH left out. ValueError when it does not fit."""
    if VERSION_LINE in text:
        return text
    if MARK in text:
        raise ValueError("carries another version of the patch")
    for anchor, replacement in EDITS:
        if text.count(anchor) != 1:
            raise ValueError(f"no single {anchor.strip()[:50]!r}")
        text = text.replace(anchor, replacement)
    return text


def plugins_dir():
    config = os.environ.get("XDG_CONFIG_HOME") or str(pathlib.Path.home() / ".config")
    return pathlib.Path(config) / "omarchy/plugins"


def source_dir():
    omarchy = os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy"
    return pathlib.Path(omarchy) / "shell/plugins/panels/monitor"


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def build(clone, source):
    """Fill the clone from Omarchy's panel, patched. Returns what it did."""
    panel = (source / "Panel.qml").read_bytes()
    digest = hashlib.sha256(panel).hexdigest()
    stamp = clone / ".source-sha256"
    if stamp.exists() and stamp.read_text().strip() == digest:
        return "already patched"
    patched = patch(panel.decode())
    stage = clone.with_name(f".{clone.name}.new")
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    for item in source.iterdir():
        if item.is_file() and item.name not in ("Panel.qml", "manifest.json"):
            shutil.copy2(item, stage / item.name)
    (stage / "Panel.qml").write_text(patched)
    # Omarchy's manifest as a clone (what `omarchy plugin clone` writes): it
    # takes the place of omarchy.monitor in the bar.
    manifest = json.loads((source / "manifest.json").read_text())
    manifest["id"] = CLONE_ID
    manifest["name"] = "Display (Omanotch)"
    if isinstance(manifest.get("barWidget"), dict):
        manifest["barWidget"]["displayName"] = manifest["name"]
    extra = manifest.get("omarchy") if isinstance(manifest.get("omarchy"), dict) else {}
    extra.pop("clonePaths", None)
    manifest["omarchy"] = {**extra, "clonedFrom": "omarchy.monitor"}
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    (stage / ".source-sha256").write_text(digest + "\n")
    shutil.rmtree(clone, ignore_errors=True)
    stage.rename(clone)
    return "patched"


def enabled(plugin_id):
    try:
        return any(p.get("id") == plugin_id and p.get("enabled")
                   for p in json.loads(run("omarchy-plugin-list", "--json") or "[]"))
    except (ValueError, AttributeError):
        return False


def other_clone(plugins):
    """The id of a clone of Omarchy's display panel that is not ours, or None."""
    for manifest in sorted(plugins.glob("*/manifest.json")):
        if manifest.parent.name == CLONE_ID:
            continue
        try:
            data = json.loads(manifest.read_text())
        except (OSError, ValueError):
            continue
        extra = data.get("omarchy") if isinstance(data, dict) else None
        if isinstance(extra, dict) and extra.get("clonedFrom") == "omarchy.monitor":
            return data.get("id") or manifest.parent.name
    return None


def remove(clone):
    if clone.exists():
        run("omarchy-plugin-enable", "omarchy.monitor")
        shutil.rmtree(clone, ignore_errors=True)
        run("omarchy-shell", "-q", "shell", "rescanPlugins")


def main(argv):
    if len(argv) == 3 and argv[1] == "--patch":
        path = pathlib.Path(argv[2])
        path.write_text(patch(path.read_text()))
        return 0
    mode = argv[1] if len(argv) > 1 else ""
    plugins = plugins_dir()
    clone = plugins / CLONE_ID
    if mode == "--remove":
        remove(clone)
        return 0
    if (plugins / "omacvm.monitor").is_dir():
        print("OmacVM.app's display panel leaves NOTCH out already")
        return 0
    other = other_clone(plugins)
    if other:
        print(f"your own display panel ({other}) is used: left alone")
        return 0
    source = source_dir()
    if not (source / "Panel.qml").is_file():
        print(f"no Omarchy display panel at {source}: left alone")
        return 0
    if mode == "--refresh" and not clone.is_dir():
        return 0
    try:
        patch((source / "Panel.qml").read_text())
    except ValueError as error:
        print(f"Omarchy's display panel changed ({error}): Omarchy's own panel is used")
        remove(clone)
        return 0
    result = build(clone, source)
    # --refresh runs at every notchcast start: no shell calls when nothing changed.
    if result == "patched" or (mode != "--refresh" and not enabled(CLONE_ID)):
        run("omarchy-shell", "-q", "shell", "rescanPlugins")
        # A new plugin needs a moment before the shell knows it.
        for _ in range(40):
            if run("omarchy-plugin-enable", CLONE_ID).startswith("Enabled"):
                break
            time.sleep(0.05)
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
