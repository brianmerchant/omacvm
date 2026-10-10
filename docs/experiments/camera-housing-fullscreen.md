# FullPanel fullscreen experiment

FullPanel is an experimental extension in Brian Merchant's
[OmacVM fork, branch fullpanel](https://github.com/brianmerchant/omacvm/tree/fullpanel).
The current source reports OmacVM **3.0.15** in `src/VERSION` and retains
Quickbar **v4**. This identifies development code, not an official release.

Full Panel (Experimental) keeps QEMU in a native macOS fullscreen Space and
uses the physical display area beside a MacBook camera housing. Native is
the default, including when the saved mode is unknown. Select **Full screen
mode → Full Panel (Experimental)** in OmacVM.app before the next VM start.
The CLI's app-route setup offers the same choice; `omacvm fullscreen`
configures it later. Both use the existing app-wide `fullScreenMode`
preference. Guest components install automatically through the supported
guest install/apply/update workflow, even when Native is chosen. No separate
FullPanel component selection or manual Linux bar patch is required.
The launcher sets `OMACVM_CAMERA_HOUSING=1` for that start; Native removes an
inherited flag. This setting does not change the VM's saved feature choices.
Full Panel suppresses the Mac-side Omanotch rendering link for that start
because the guest bar occupies the camera strip itself.

## Provenance and licensing

The original [OmacVM project](https://github.com/gillesgoetsch/OmacVM) is by
Gilles Goetsch. Brian Merchant contributed this fork's experimental FullPanel
integration. OmacVM's existing MIT licence and Gilles Goetsch's copyright
remain intact; these contributions do not replace upstream authorship.

UTM's camera-housing fullscreen work by Turing Software, LLC,
[PR #7885](https://github.com/utmapp/UTM/pull/7885) and
[PR #7910](https://github.com/utmapp/UTM/pull/7910), provided architectural
prior art. UTM's implementation is Apache-2.0. As recorded in
`app/runtime/patches/apply-camera-housing-fullscreen.py`, the FullPanel
transformer is an independent Objective-C implementation; UTM's Swift
implementation was not copied.

QEMU's `ui/cocoa.m` retains its MIT notice, copyright (c) 2008 Mike
Kronenberg. The modified driver remains part of the wider QEMU distribution,
with its GPL-2.0 and applicable per-file licences. Existing Try Omarchy,
Omarchy, Omanotch and other component credits remain in the
[repository notices](../../THIRD_PARTY_NOTICES.md) and
[app notices](../../app/THIRD_PARTY_NOTICES.md). The latter records the exact
QEMU pin, fork modifications and source requirements for a future binary.

## Geometry, reveal and fallback

FullPanel verifies AppKit method encodings and the required SkyLight symbols
before using private interfaces. A non-notched display, unavailable private
dependency, incompatible AppKit method or the macOS preference to keep the
fullscreen menu bar visible uses ordinary native fullscreen.
This is a geometry fallback, not an automatic change of the saved mode or
an automatic reactivation of Omanotch; see the startup distinction below.

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

## Dedicated guest bar: Quickbar v4

The launcher passes measured built-in screen width, bar height and camera
bounds as integer tenths of macOS points through SMBIOS. `omacvm-app-host`
exposes these in `/run/omacvm/host.env`; the display agent identifies the
built-in guest output in `$XDG_RUNTIME_DIR/omacvm/builtin`.

The guest installer builds `omacvm.fullpanel.bar` in
`~/.config/omarchy/plugins/` from the installed stock Omarchy bar. Only this
managed copy receives the v4 transform. It keeps the stock capability
metadata and copied component notices; it does not derive from, patch or
overwrite the existing Omanotch/user bar. The legacy one-argument transform
imported by Omanotch is inert. A pre-existing user clone is not required.

Installation stages and validates the dedicated plugin before publishing it.
It does not select a bar. At Hyprland config load, before the shell starts,
`omacvm-fullpanel prepare` reads the boot's host mode signal and selects the
dedicated bar through `shell.json`. It preserves unrelated shell settings
and saves the native bar selection/options for restoration. Returning to
Native restores that configuration before removing FullPanel-owned runtime
masks and queuing nonblocking starts for enabled, inactive Omanotch services.
Disabled, absent and independently masked units are respected. No permanent
daemon, polling process or second shell/bar launcher is introduced.

Unmanaged plugin paths, unsupported stock anchors and failed installations
are reported without overwriting native bar contents. Running-shell mode
changes are deferred to the next session. An active FullPanel plugin is not
replaced behind the shell; the next startup can update it, retaining the
previous validated copy if an update fails. Detailed installation, recovery
and health-check behavior is in [FULLPANEL.md](../../src/app/guest/FULLPANEL.md).

The QML converts the host dimensions using the QScreen logical width exactly
once. Height and bounds follow guest resolution and 1x–4x scale, including
1.33333 and 1.6. The measured FullPanel height replaces the ordinary horizontal
bar height on an eligible built-in top bar; it is independent of font scaling.
External outputs and outputs that fail the v4 eligibility checks use ordinary
bar dimensions. Native mode uses the saved original bar. Eligibility relies
on the built-in output identity and guest dimensions; the guest does not
receive a live host fullscreen/fallback state.
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
the fallback. Host notch measurements are taken at VM start. The installed
stock Omarchy bar must match the transform's supported anchors; unsupported
changes leave the working configuration intact and produce an install/check
failure.

The host and guest make separate fallback decisions:

- Each QEMU window uses ordinary fullscreen geometry on a screen without a
  positive camera safe-area inset, including ordinary external displays.
  This does not disable FullPanel globally on a notched host.
- When valid built-in notch geometry exists at VM start, the launcher sends
  `OMACVM_FULLPANEL=1` through SMBIOS. The guest selects its dedicated plugin
  globally; only its eligible built-in top bar gets notch clearance. Its
  external bars use ordinary dimensions, and NOTCH outputs are excluded.
- Without valid built-in notch geometry, the launcher sends no FullPanel
  flag and the guest follows the Native bar-selection path. However, a saved
  FullPanel choice still closes the Mac Omanotch link for that start.
- Private-API or menu-bar-preference fallback can also leave the guest's
  boot-time FullPanel flag and dedicated plugin selected. QEMU's geometry
  fallback does not signal the guest to restore Omanotch. Select Native and
  restart the VM to restore the complete native experience.

These fallback descriptions come from code inspection, not hardware
verification of non-notched or external displays. The bar's aspect-ratio
guard is a heuristic, not a live fullscreen-state report.

Check the VM's `qemu.log` for the selected mode, private-dependency fallback,
`FRAME HOOK rejected`, protected frame, `AREA LOST`, transaction failure or
return timeout messages. For guest clearance, inspect the numeric FullPanel
fields in `host.env`, the built-in output name and the v4 marker in
`omacvm.fullpanel.bar/Bar.qml`. A Native launcher supplies no FullPanel
metadata. Use `omacvm check --vm "<VM name>" --json` to check readiness,
selection and service coordination; preserve rejected/custom files for review.

## Validation status

The maintainer reported working FullPanel rendering and the v4 Quickbar on
a physical 14-inch M1 Pro MacBook Pro, and passing Native-to-FullPanel checks
with OmacVM 3.0.15. Those reports do not establish coverage of other hardware
or every Space/menu-reveal transition.

The maintainer also reproduced a first-Native-boot return failure twice:
the original bar returned, but notchcast/NOTCH recovered only on another
Native boot. The selector now explicitly starts enabled, inactive services
after restoring the native bar and removing its masks. Local fixtures cover
the graphical target already being active, repeated Native starts, external
masks and failed-start recovery. Hardware confirmation of that correction
is still required.

Fast offline coverage lives in
`app/runtime/Tests/display/test-camera-housing-frame-guards.py`,
`test-camera-housing-fullscreen.sh` and
`src/app/guest/tests/test-fullpanel-bar.py`, plus
`src/app/guest/tests/test_fullpanel.py` and `src/tests/test_fullscreen.py`.
The runtime fixture suite compiles the generated helper
and geometry methods against fake AppKit objects and checks guarded restoration.
Guest fixtures cover dedicated bar installation, native selection restoration
and service coordination. Standalone Omanotch safe-write
checks run with `python3 src/omanotch/guest/tests/test_safe_write.py`; the full
Omanotch bar suite also needs Node.js. These tests do not verify real Linux
user-manager timing, QML rendering or binary-distribution compliance. They
do not replace a complete QEMU translation-unit build or broader Mac tests of
fullscreen entry, Split View, menu reveal, Space return, Mission Control and
external displays.
No application/runtime build or VM test was performed for this documentation
audit, and no public FullPanel binary release is established here.
