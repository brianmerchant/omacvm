# FullPanel on OmacVM 3.0.14

Full Panel (Experimental) keeps QEMU in a native macOS fullscreen Space and
uses the physical display area beside a MacBook camera housing. Native is
the default, including when the saved mode is unknown. Select **Full screen
mode → Full Panel (Experimental)** in OmacVM.app before the next VM start.
The launcher sets `OMACVM_CAMERA_HOUSING=1` for that start; Native removes an
inherited flag. This setting does not change the VM's saved feature choices.
Full Panel suppresses the Mac-side Omanotch rendering link for that start
because the guest bar occupies the camera strip itself.

The Cocoa transformer is an independent Objective-C implementation for
QEMU's MIT-licensed Cocoa driver. UTM's camera-housing fullscreen work by
Turing Software, LLC (PRs #7885 and #7910, Apache-2.0) is architectural prior
art; its Swift source was not copied.

## Geometry, reveal and fallback

FullPanel verifies AppKit method encodings and the required SkyLight symbols
before using private interfaces. A non-notched display, unavailable private
dependency, incompatible AppKit method or the macOS preference to keep the
fullscreen menu bar visible uses ordinary native fullscreen.

The frame hook accepts the whole display only for an untiled fullscreen
region. After acceptance, it retains that physical frame when AppKit
re-queries the exact camera-safe tile or tries a safe-area shrink. Horizontal
Split View remains eligible for AppKit's own geometry. If the physical area
is lost, the state latches that loss and restores the normal menu bar; it
does not repeatedly force a frame back into place.

Menu-bar alpha changes target only the window's owned fullscreen Space
(type 4). Pointer motion at the top edge permits menu reveal; AppKit's reveal
callbacks also control the app's fullscreen toolbar. Exit/close restores
presentation options, toolbar visibility and the Space's menu alpha.
Space changes, key-window and visibility events retain bounded return
recovery. Recovery checks WindowServer bounds before reapplying reveal state;
it stops on missing evidence and expires after about two seconds, without
changing geometry. The former tracing and A/B policy switches are removed.

## Existing cloned bar: Quickbar v4

The launcher passes measured built-in screen width, bar height and camera
bounds as integer tenths of macOS points through SMBIOS. `omacvm-app-host`
exposes these in `/run/omacvm/host.env`; the display agent identifies the
built-in guest output in `$XDG_RUNTIME_DIR/omacvm/builtin`.

The guest installer patches only an existing
`~/.config/omarchy/plugins/$USER.bar/Bar.qml`. It creates no plugin, selects
no plugin, and changes neither `shell.json` nor `shell.toml`. The patcher
validates unique known anchors, migrates v1/v2/v3 to v4 and is idempotent.
Each changed install saves a unique `Bar.qml.fullpanel-backup-*` beside the
clone, then atomically replaces it while preserving owner and mode. A failed
transformation or write leaves the clone intact. Omanotch's bar patcher
composes the same transformation and uses the same backup/replacement path;
there is no second backup layer in the guest installer.

For developer inspection of a supported existing clone, run as its owner:

```sh
python3 /usr/local/lib/omacvm/fullpanel-bar.py "$HOME/.config/omarchy/plugins/$USER.bar/Bar.qml"
```

This is a dry run. `--install` applies it with a backup. Customizations outside
the validated blocks survive; changed anchors or modified FullPanel blocks
are rejected for manual review. No background daemon is added. File replacement
is atomic: the current QML remains intact if staging fails, and a unique
pre-update backup is retained. A Quickshell watcher may not reload a replaced
file automatically; after updating an active clone, run `omarchy-restart-shell`
in an interactive Omarchy session. The installer does not restart the desktop.

The QML converts the host dimensions using the QScreen logical width exactly
once. Height and bounds follow guest resolution and 1x–4x scale, including
1.33333 and 1.6. The measured FullPanel height replaces the ordinary horizontal
bar height on an eligible built-in top bar; it is independent of font scaling.
Native, windowed, non-notched and external outputs retain their normal layout.
The existing clean-size trim and guest scale presets remain unchanged.

Quickbar v4 keeps widget order and region identity. A disjoint prefix of the
right-hand entries can borrow spare space left of the notch; the remaining
entries stay right. Actual slot widths determine the split, without duplicate
steady-state widget instances. Page arrows expose overflow. Rebalancing is
paused during hover, popouts and dragging to prevent hover-dependent widths
from repeatedly recreating widgets at 4x. The accepted 3x/4x layout is retained.

## Limitations and troubleshooting

A brief camera-strip flash on Mission Control return remains. Matching
WindowServer bounds is a recovery guard, not proof of which pixels the
compositor displayed. Private macOS interfaces can change; Native remains
the fallback. Host notch measurements are taken at VM start. An existing
supported bar clone is required; no clone means no guest bar patch.

Check the VM's `qemu.log` for the selected mode, private-dependency fallback,
`FRAME HOOK rejected`, protected frame, `AREA LOST`, transaction failure or
return timeout messages. For guest clearance, inspect the numeric FullPanel
fields in `host.env`, the built-in output name and the v4 marker in the clone.
A Native launcher supplies no FullPanel metadata. A rejected clone should be
reviewed against its backup rather than overwritten.

Fast offline coverage lives in
`app/runtime/Tests/display/test-camera-housing-frame-guards.py`,
`test-camera-housing-fullscreen.sh` and
`src/app/guest/tests/test-fullpanel-bar.py`. It compiles the generated helper
and geometry methods against fake AppKit objects, checks guarded restoration
and tests bar migration/atomic installation. Standalone Omanotch safe-write
checks run with `python3 src/omanotch/guest/tests/test_safe_write.py`; the full
Omanotch bar suite also needs Node.js. These tests do not replace a complete
QEMU translation-unit build or a future Mac runtime test of fullscreen entry,
Split View, menu reveal, Space return, Mission Control and external displays.
