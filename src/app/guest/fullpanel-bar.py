#!/usr/bin/env python3
"""FullPanel-only, scale-aware Omarchy top-bar clearance.

Apply to an Omarchy bar clone (including the existing Omanotch clone). The
change is additive and idempotent. It doesn't alter shell.toml, other display
bars, or the native fullscreen route. Run as the *desktop user*::

    python3 fullpanel-bar.py --install ~/.config/omarchy/plugins/$USER.bar/Bar.qml

Omanotch's own QML patch also calls patch_text() after applying its changes,
so a future Omanotch reinstall retains this rule.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

MARKER = "// omacvm-fullpanel-quickbar v1"
HOME_ANCHOR = '  property string home: Quickshell.env("HOME")\n'
NOTCH_FLOOR = '''    readonly property int notchFloor: root.appleSiliconHost && root.position === "top"
      ? (Style.bar.notchHeight > 0
          ? Style.bar.notchHeight
          : BarModel.notchHeight(screen.name, screen.width, screen.height, screen.devicePixelRatio))
      : 0
'''
NEW_NOTCH_FLOOR = '''    // The real Apple panel's measured menu-bar height, scaled to this guest
    // output (OmacVM QEMU's FullPanel mode only). Unlike size-horizontal,
    // this is independent of Omarchy's font scaling and per-screen.
    readonly property int notchFloor: root.position === "top"
      ? (root.appleSiliconHost
          ? (Style.bar.notchHeight > 0
              ? Style.bar.notchHeight
              : BarModel.notchHeight(screen.name, screen.width, screen.height, screen.devicePixelRatio))
          : root.fullPanelBarHeight(screen))
      : 0
'''

# FileView is part of the already-loaded Quickshell.Io module in Bar.qml.
# The VM startup host.env file is populated from QEMU SMBIOS and contains
# no shell commands, only numeric values. Its creation precedes the shell.
HOST_INFO = r'''
  // FullPanel: OmacVM's startup metadata, passed through QEMU SMBIOS.
  // Native fullscreen passes no marker; the override is then always zero.
  // reactively updates when the guest display's dimensions/scale change.
  // omacvm-fullpanel-quickbar v1
  property var fullPanelInfo: ({ enabled: false, screenWidth10: 0, barHeight10: 0 })
  property string fullPanelBuiltin: "Virtual-1"

  function parseFullPanelInfo(raw) {
    var env = {}
    var lines = String(raw || "").split(/\r?\n/)
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^(OMACVM_[A-Z0-9_]+)=([0-9]+)$/)
      if (m) env[m[1]] = Number(m[2])
    }
    var w = env.OMACVM_FULLPANELWIDTH10 || 0
    var h = env.OMACVM_FULLPANELBAR10 || 0
    return {
      enabled: env.OMACVM_FULLPANEL === 1 && isFinite(w) && isFinite(h)
               && w > 0 && h > 0 && h < w / 5,
      screenWidth10: w,
      barHeight10: h
    }
  }

  FileView {
    path: "/run/omacvm/host.env"
    watchChanges: true
    printErrors: false
    onLoaded: root.fullPanelInfo = root.parseFullPanelInfo(text())
    onFileChanged: reload()
    onLoadFailed: root.fullPanelInfo = ({ enabled: false, screenWidth10: 0, barHeight10: 0 })
  }

  // OmacVM's display agent records which Virtual-N is the built-in display.
  // The main QEMU window need not be on the built-in Mac screen.
  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omacvm/builtin"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var name = String(text() || "").trim()
      root.fullPanelBuiltin = /^Virtual-[0-9]+$/.test(name) ? name : "Virtual-1"
    }
    onFileChanged: reload()
  }

  function fullPanelBarHeight(s) {
    var info = fullPanelInfo
    if (!info.enabled || !s || root.position !== "top") return 0
    if (String(s.name) !== fullPanelBuiltin) return 0
    var w = Number(s.width), h = Number(s.height), scale = Number(s.devicePixelRatio)
    if (!(w > 0 && h > 0 && scale > 0)) return 0
    // The window must have the camera strip: ordinary 16:10/16:9 and
    // windowed modes stay as Omarchy intended. Only a plausible notch
    // strip (at most 6% of display height) qualifies.
    var strip = h - (w * 10) / 16
    if (!(strip > 1 && strip < h * 0.06)) return 0
    // Host dimensions are in tenths of macOS points; QScreen.width is
    // ALREADY in guest logical pixels (Hyprland scale is reflected there).
    // Ratio of widths converts points to logical pixels exactly once.
    var logical = info.barHeight10 * w / info.screenWidth10
    if (!isFinite(logical) || logical < 5 || logical > 200) return 0
    return Math.ceil(logical)
  }
'''


def replace_exactly_once(text: str, original: str, changed: str, label: str) -> str:
    count = text.count(original)
    if count != 1:
        raise ValueError(f"{label}: expected one original anchor, found {count}; Omarchy may have changed")
    return text.replace(original, changed, 1)


def patch_text(text: str) -> str:
    if MARKER in text:
        # Partial/corrupt edits must not be mistaken for a full installation.
        if "root.fullPanelBarHeight(screen)" not in text or "function fullPanelBarHeight(s)" not in text:
            raise ValueError("FullPanel marker found without required code")
        return text
    updated = replace_exactly_once(text, HOME_ANCHOR, HOME_ANCHOR + HOST_INFO, "bar root")
    updated = replace_exactly_once(updated, NOTCH_FLOOR, NEW_NOTCH_FLOOR, "notchFloor")
    return updated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="rewrite an existing clone only if patchable")
    parser.add_argument("bar", type=pathlib.Path)
    args = parser.parse_args()
    original = args.bar.read_text()
    changed = patch_text(original)
    if original == changed:
        print("fullpanel-bar: already patched")
        return 0
    if not args.install:
        print("fullpanel-bar: patchable (dry run; use --install to apply)")
        return 0
    # Preserve the user's plugin file and owner/mode. Write in place, so the
    # Quickshell file watcher sees a change and the clone's ownership stays.
    with args.bar.open("r+", encoding="utf-8") as f:
        f.write(changed)
        f.truncate()
    print(f"fullpanel-bar: patched {args.bar}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"fullpanel-bar: {exc}", file=sys.stderr)
        raise SystemExit(1)
