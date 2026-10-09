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

V1_MARKER = "// omacvm-fullpanel-quickbar v1"
V2_MARKER = "// omacvm-fullpanel-quickbar v2"
V3_MARKER = "// omacvm-fullpanel-quickbar v3"
MARKER = "// omacvm-fullpanel-quickbar v4"
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
HOST_INFO_V1 = r'''
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


# Do not re-implement v1 by a loose string search: the old QML block is
# preserved verbatim above so an existing live clone can be migrated safely.
HOST_INFO_V2 = HOST_INFO_V1.replace(
    "// omacvm-fullpanel-quickbar v1", "// omacvm-fullpanel-quickbar v2"
).replace(
    "enabled: false, screenWidth10: 0, barHeight10: 0",
    "enabled: false, screenWidth10: 0, barHeight10: 0, left10: 0, right10: 0"
).replace('''    var h = env.OMACVM_FULLPANELBAR10 || 0
    return {''', '''    var h = env.OMACVM_FULLPANELBAR10 || 0
    var l = env.OMACVM_FULLPANELLEFT10 || 0
    var r = env.OMACVM_FULLPANELRIGHT10 || 0
    var boundsValid = isFinite(l) && isFinite(r) && l > 0 && l < r
                      && r < w && (r - l) < w / 3
    return {''').replace('''      barHeight10: h
    }''', '''      barHeight10: h,
      // Older launchers only supply the height. Notch-aware layout is then
      // disabled; height adjustment still works.
      left10: boundsValid ? l : 0,
      right10: boundsValid ? r : 0
    }''')

# Keep the FullPanel height guard as the single definition of built-in screen
# eligibility; notch bounds never apply to a normal/windowed/external bar.
FULLPANEL_BOUNDS = r'''
  function fullPanelBounds(s) {
    var info = fullPanelInfo
    if (!info.enabled || !info.left10 || !info.right10) return null
    if (root.fullPanelBarHeight(s) <= 0) return null
    var w = Number(s.width)
    var left = info.left10 * w / info.screenWidth10
    var right = info.right10 * w / info.screenWidth10
    if (!isFinite(left) || !isFinite(right)
        || left <= 0 || left >= right || right >= w) return null
    return { left: left, right: right }
  }

  function fullPanelSafeWidth(s, edge) {
    var bounds = root.fullPanelBounds(s)
    if (!bounds) return 0
    // Style's edge margin is also applied by the anchors in horizontalBar.
    // Add a few logical pixels beyond the measured camera housing.
    var inset = Style.space(8) + 6
    return Math.max(1, Math.floor(edge === "left"
       ? bounds.left - inset : Number(s.width) - bounds.right - inset))
  }
'''
HOST_INFO_V2 = HOST_INFO_V2.replace("  function fullPanelBarHeight(s) {", FULLPANEL_BOUNDS + "\n  function fullPanelBarHeight(s) {")
HOST_INFO_V3 = HOST_INFO_V2.replace(V2_MARKER, V3_MARKER)
HOST_INFO = HOST_INFO_V3.replace(V3_MARKER, MARKER)

# Each side is a SINGLE ModuleList, not two arrangements. With no notch (or
# with enough width), its bounds coincide with the old anchor positions.
EDGE_COMPONENT_V2 = r'''
  // OmacVM FullPanel v2: only the built-in top bar has a safe-width limit.
  // The same widgets stay mounted while scrolling, so IPC handlers/timers
  // are not duplicated and a long clock or larger font cannot push widgets
  // under the physical camera cutout.
  component FullPanelEdgeModules: Item {
    id: fullPanelEdge
    required property var targetScreen
    property string edge: "right"
    readonly property real safeWidth: root.fullPanelSafeWidth(targetScreen, edge)
    readonly property bool notchAware: safeWidth > 0
    readonly property bool overflow: notchAware && modules.width > safeWidth
    readonly property real arrowSize: overflow ? Math.min(Style.space(5), safeWidth / 4) : 0
    property bool userScrolled: false

    width: notchAware ? Math.min(safeWidth, modules.width + 2 * arrowSize) : modules.width
    height: modules.height

    function snapToDefault() {
      if (!overflow || userScrolled) return
      viewport.contentX = edge === "right"
        ? Math.max(0, viewport.contentWidth - viewport.width) : 0
    }
    function page(towardRight) {
      userScrolled = true
      var distance = Math.max(1, viewport.width * 0.75)
      viewport.contentX = Math.max(0, Math.min(viewport.contentWidth - viewport.width,
                           viewport.contentX + (towardRight ? distance : -distance)))
    }
    onOverflowChanged: {
      userScrolled = false
      Qt.callLater(snapToDefault)
    }
    Component.onCompleted: Qt.callLater(snapToDefault)

    Flickable {
      id: viewport
      x: fullPanelEdge.arrowSize
      width: Math.max(0, parent.width - 2 * fullPanelEdge.arrowSize)
      height: parent.height
      clip: fullPanelEdge.overflow
      contentWidth: modules.width
      contentHeight: modules.height
      boundsBehavior: Flickable.StopAtBounds
      // Dragging here would steal clicks and drag-to-reorder from widgets.
      // Dedicated page arrows provide access to every slot instead.
      interactive: false
      ModuleList {
        id: modules
        entries: root.layoutEntries(fullPanelEdge.edge)
        region: fullPanelEdge.edge
        onWidthChanged: Qt.callLater(fullPanelEdge.snapToDefault)
      }
    }

    Text {
      visible: fullPanelEdge.overflow
      x: 0
      width: fullPanelEdge.arrowSize
      height: parent.height
      text: "‹"
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      font.family: root.fontFamily
      font.pixelSize: Math.max(10, Math.min(height, Style.font.body))
      color: root.barForeground
      opacity: viewport.contentX > 0.5 ? 1 : 0.35
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        enabled: viewport.contentX > 0.5
        onClicked: fullPanelEdge.page(false)
      }
    }
    Text {
      visible: fullPanelEdge.overflow
      x: parent.width - fullPanelEdge.arrowSize
      width: fullPanelEdge.arrowSize
      height: parent.height
      text: "›"
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      font.family: root.fontFamily
      font.pixelSize: Math.max(10, Math.min(height, Style.font.body))
      color: root.barForeground
      opacity: viewport.contentX < viewport.contentWidth - viewport.width - 0.5 ? 1 : 0.35
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        enabled: viewport.contentX < viewport.contentWidth - viewport.width - 0.5
        onClicked: fullPanelEdge.page(true)
      }
    }
  }
'''

# v3 reuses the proven v2 per-side pager and measures actual widget widths.
# The extra left-side group receives only the right-side entries that fit.
EDGE_COMPONENT = EDGE_COMPONENT_V2.replace(
    '    property string edge: "right"\n',
    '    property string edge: "right"\n'
    '    property string widgetRegion: edge\n'
    '    property var entriesOverride: null\n'
    '    property real widthLimit: -1\n'
).replace(
    'readonly property real safeWidth: root.fullPanelSafeWidth(targetScreen, edge)',
    'readonly property real safeWidth: widthLimit >= 0 ? Math.max(1, widthLimit) : root.fullPanelSafeWidth(targetScreen, edge)'
).replace(
    '        entries: root.layoutEntries(fullPanelEdge.edge)\n        region: fullPanelEdge.edge',
    '        entries: fullPanelEdge.entriesOverride !== null ? fullPanelEdge.entriesOverride : root.layoutEntries(fullPanelEdge.edge)\n'
    '        region: fullPanelEdge.widgetRegion'
).replace('FullPanel v2: only', 'FullPanel v3: only')

# Each widget retains its region identity (right), but the first N right
# entries can be rendered in an extra left-adjacent ModuleList. N is computed
# from the actual ModuleSlot widths for this screen; no hardcoded icon widths.
# Both the suffix and the prefix are disjoint at rest, and v2's arrows remain
# on the right whenever the two usable physical screen segments are too small.
# Moving entries can recreate those particular widget instances once on
# reflow (e.g. a scale change); the steady state doesn't duplicate them.
BALANCED_COMPONENT_V3 = r'''
  component FullPanelBalancedModules: Item {
    id: balanced
    required property var targetScreen
    readonly property real edgeMargin: Style.space(8)
    readonly property real gap: Style.space(2)
    readonly property real rightCapacity: root.fullPanelSafeWidth(targetScreen, "right")
    readonly property real leftCapacity: root.fullPanelSafeWidth(targetScreen, "left")
    readonly property real freeLeft: Math.max(0, leftCapacity - leftGroup.width - gap)
    readonly property var rightEntries: root.layoutEntries("right")
    property int borrowedCount: 0

    // A slot may exist on several displays. Only sizes from this bar surface
    // count, and only right-region slots. Unknown sizes defer redistribution;
    // the original v2 right pager remains functional in the meantime.
    readonly property var measured: {
      var slots = root.moduleSlots
      var entries = balanced.rightEntries
      var widths = []
      var ready = true
      var total = 0
      for (var i = 0; i < entries.length; i++) {
        var wanted = root.entryId(entries[i])
        var matched = null
        for (var j = 0; j < slots.length; j++) {
          var slot = slots[j]
          if (!slot || slot.region !== "right" || slot.moduleName !== wanted) continue
          var win = root.slotWindow(slot)
          if (!win || !win.screen || String(win.screen.name) !== String(targetScreen.name)) continue
          matched = slot
          break
        }
        if (!matched) { ready = false; break }
        var size = Number(matched.width)
        if (!isFinite(size) || size < 0) { ready = false; break }
        widths.push(size)
        total += size
      }
      return { ready: ready, widths: widths, total: total }
    }

    function desiredBorrowedCount() {
      if (!root.fullPanelBounds(targetScreen)) return 0
      var m = measured
      if (!m.ready) return -1
      var remaining = m.total
      if (remaining <= rightCapacity + 0.5) return 0
      var leftUsed = 0
      var count = 0
      // Only a contiguous prefix moves: order and the right-side trailing
      // power/clock controls are retained. Never take the existing left row.
      while (count < m.widths.length && remaining > rightCapacity + 0.5) {
        var nextWidth = m.widths[count]
        if (leftUsed + nextWidth > freeLeft + 0.5) break
        leftUsed += nextWidth
        remaining -= nextWidth
        count++
      }
      return count
    }

    function rebalance() {
      // Don't reparent/recreate widgets while a popout is open or while the
      // user is dragging a bar item. Defer until the next relevant change.
      if (root.activePopout || root.barDragSource) return
      var wanted = desiredBorrowedCount()
      if (wanted >= 0 && wanted !== borrowedCount) borrowedCount = wanted
    }
    // Coalesced with the QML event loop, not a timer or resident process.
    function scheduleRebalance() { Qt.callLater(rebalance) }
    onMeasuredChanged: scheduleRebalance()
    onFreeLeftChanged: scheduleRebalance()
    onLeftCapacityChanged: scheduleRebalance()
    onRightCapacityChanged: scheduleRebalance()
    onRightEntriesChanged: scheduleRebalance()
    Component.onCompleted: scheduleRebalance()
    Connections {
      target: root
      function onActivePopoutChanged() { balanced.scheduleRebalance() }
      function onBarDragSourceChanged() { balanced.scheduleRebalance() }
    }

    FullPanelEdgeModules {
      id: leftGroup
      targetScreen: balanced.targetScreen
      edge: "left"
      anchors.left: parent.left
      anchors.leftMargin: balanced.edgeMargin
      anchors.verticalCenter: parent.verticalCenter
    }
    FullPanelEdgeModules {
      id: borrowedGroup
      targetScreen: balanced.targetScreen
      edge: "left"
      widgetRegion: "right"
      widthLimit: balanced.freeLeft
      entriesOverride: balanced.rightEntries.slice(0, balanced.borrowedCount)
      anchors.left: leftGroup.right
      anchors.leftMargin: balanced.gap
      anchors.verticalCenter: parent.verticalCenter
      visible: balanced.borrowedCount > 0
    }
    FullPanelEdgeModules {
      id: rightGroup
      targetScreen: balanced.targetScreen
      edge: "right"
      widgetRegion: "right"
      entriesOverride: balanced.rightEntries.slice(balanced.borrowedCount)
      anchors.right: parent.right
      anchors.rightMargin: balanced.edgeMargin
      anchors.verticalCenter: parent.verticalCenter
    }
  }
'''

# Omarchy already records pointer presence across each complete bar surface.
# Freeze the borrowed widget split while hovered. Hover-reveal widgets (notably
# tray and indicators) can change their width, and reparenting them in response
# can cause the pointer to leave/re-enter, recreating them in a loop at 4x.
# The existing bar HoverHandler is an ancestor of the entire widget strip, so
# the freeze doesn't interfere with widget clicks, drag, or popup behavior.
BALANCED_COMPONENT = BALANCED_COMPONENT_V3.replace(
    "if (root.activePopout || root.barDragSource) return",
    "if (root.activePopout || root.barDragSource || root.barHovered) return"
).replace(
    "      function onBarDragSourceChanged() { balanced.scheduleRebalance() }",
    "      function onBarDragSourceChanged() { balanced.scheduleRebalance() }\n"
    "      function onBarHoveredChanged() { balanced.scheduleRebalance() }"
)

HORIZONTAL_OLD = '''        LeftModules {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        RightModules {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }
'''
HORIZONTAL_NEW = '''        FullPanelEdgeModules {
          edge: "left"
          targetScreen: barWindow.screen
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        FullPanelEdgeModules {
          edge: "right"
          targetScreen: barWindow.screen
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }
'''
HORIZONTAL_V3 = '''        FullPanelBalancedModules {
          targetScreen: barWindow.screen
          anchors.fill: parent
        }
'''
# Insert the component once, in the same root scope as ModuleList and LeftModules.
EDGE_ANCHOR = '''  component LeftModules: ModuleList {
'''
OLD_HEIGHT = '    implicitHeight: root.vertical ? 0 : Math.max(root.barSize, notchFloor)\n'
NEW_HEIGHT = '''    implicitHeight: root.vertical ? 0 : (root.fullPanelBarHeight(screen) > 0
      ? root.fullPanelBarHeight(screen) : Math.max(root.barSize, notchFloor))
'''
# Omanotch wraps the stock height expression inside its own role choice.
OLD_OMANOTCH_HEIGHT = '''    implicitHeight: root.vertical ? 0 : (barWindow.notchRole === "" ? Math.max(root.barSize, notchFloor) : barWindow.parkedSize)
'''
NEW_OMANOTCH_HEIGHT = '''    implicitHeight: root.vertical ? 0 : (barWindow.notchRole === ""
      ? (root.fullPanelBarHeight(screen) > 0 ? root.fullPanelBarHeight(screen) : Math.max(root.barSize, notchFloor))
      : barWindow.parkedSize)
'''
# The user's possible live one-line height override, written in the handoff.
OLD_MANUAL_HEIGHT = '''    implicitHeight: root.vertical ? 0 : (root.fullPanelBarHeight(screen) > 0 ? root.fullPanelBarHeight(screen) : Math.max(root.barSize, notchFloor))
'''

def replace_exactly_once(text: str, original: str, changed: str, label: str) -> str:
    count = text.count(original)
    if count != 1:
        raise ValueError(f"{label}: expected one original anchor, found {count}; Omarchy may have changed")
    return text.replace(original, changed, 1)


def upgrade_height(text: str) -> str:
    if NEW_HEIGHT in text or NEW_OMANOTCH_HEIGHT in text:
        return text
    for old, new in ((OLD_HEIGHT, NEW_HEIGHT),
                     (OLD_MANUAL_HEIGHT, NEW_HEIGHT),
                     (OLD_OMANOTCH_HEIGHT, NEW_OMANOTCH_HEIGHT)):
        if old in text:
            return replace_exactly_once(text, old, new, "FullPanel height")
    raise ValueError("FullPanel height: no supported implicitHeight anchor")


def validate_v2(text: str) -> None:
    if ("function fullPanelBounds(s)" not in text
        or "component FullPanelEdgeModules: Item" not in text
        or "root.fullPanelBarHeight(screen) > 0" not in text
        or "OMACVM_FULLPANELRIGHT10" not in text
        or text.count(HOST_INFO_V2) != 1
        or text.count(EDGE_COMPONENT_V2) != 1
        or text.count(HORIZONTAL_NEW) != 1):
        raise ValueError("FullPanel v2 marker found without exact expected code")


def validate_v3(text: str) -> None:
    if (text.count(HOST_INFO_V3) != 1
        or text.count(EDGE_COMPONENT) != 1
        or text.count(BALANCED_COMPONENT_V3) != 1
        or text.count(HORIZONTAL_V3) != 1
        or "root.fullPanelBarHeight(screen) > 0" not in text):
        raise ValueError("FullPanel v3 marker found without exact expected code")


def validate_v4(text: str) -> None:
    if (text.count(HOST_INFO) != 1
        or text.count(EDGE_COMPONENT) != 1
        or text.count(BALANCED_COMPONENT) != 1
        or text.count(HORIZONTAL_V3) != 1
        or "root.fullPanelBarHeight(screen) > 0" not in text):
        raise ValueError("FullPanel v4 marker found without exact expected code")


def upgrade_v3_to_v4(text: str) -> str:
    validate_v3(text)
    text = replace_exactly_once(text, HOST_INFO_V3, HOST_INFO, "FullPanel v3 metadata")
    text = replace_exactly_once(text, BALANCED_COMPONENT_V3, BALANCED_COMPONENT,
                                "FullPanel v3 balanced widget layout")
    validate_v4(text)
    return text


def upgrade_v2_to_v3(text: str) -> str:
    validate_v2(text)
    text = replace_exactly_once(text, HOST_INFO_V2, HOST_INFO_V3, "FullPanel v2 metadata")
    text = replace_exactly_once(text, EDGE_COMPONENT_V2,
                                EDGE_COMPONENT + "\n" + BALANCED_COMPONENT_V3,
                                "FullPanel v2 edge component")
    text = replace_exactly_once(text, HORIZONTAL_NEW, HORIZONTAL_V3,
                                "FullPanel v2 horizontal layout")
    validate_v3(text)
    return text


def patch_text(text: str) -> str:
    if MARKER in text:
        validate_v4(text)
        return text
    if V3_MARKER in text:
        return upgrade_v3_to_v4(text)
    if V2_MARKER in text:
        return upgrade_v3_to_v4(upgrade_v2_to_v3(text))

    if V1_MARKER in text:
        if text.count(HOST_INFO_V1) != 1:
            raise ValueError("FullPanel v1 metadata differs; refusing partial migration")
        updated = text.replace(HOST_INFO_V1, HOST_INFO_V2, 1)
    else:
        updated = replace_exactly_once(text, HOME_ANCHOR,
                                       HOME_ANCHOR + HOST_INFO_V2, "bar root")
        updated = replace_exactly_once(updated, NOTCH_FLOOR,
                                       NEW_NOTCH_FLOOR, "notchFloor")

    updated = upgrade_height(updated)
    updated = replace_exactly_once(updated, EDGE_ANCHOR,
                                   EDGE_COMPONENT_V2 + "\n" + EDGE_ANCHOR, "edge component")
    updated = replace_exactly_once(updated, HORIZONTAL_OLD, HORIZONTAL_NEW,
                                   "horizontal module layout")
    return upgrade_v3_to_v4(upgrade_v2_to_v3(updated))

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
