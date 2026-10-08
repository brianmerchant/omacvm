# 0042: The Mac's input methods in the VM: macOS composes, Fcitx5 inserts

Status: accepted, planned for 3.0.7 (`mac-ime`: off by default,
experimental, OmacVM.app only). Requested and scoped by @Vocllum in
[#273](https://github.com/gillesgoetsch/OmacVM/issues/273).

## Context

To type Chinese, Japanese or Korean in Omarchy today, you set up an input
method inside the VM (Fcitx5 with Mozc, Rime, Hangul, ...), with its own
switch key and candidate window. #273 asks for the Mac's own input methods
instead: focus a text field in the VM, type, the macOS candidate window
opens at the guest caret, the chosen text lands at the caret. Keys,
Cmd/Ctrl mapping and shortcuts stay as they are; no floating dialog, no
clipboard.

The issue names the four hard parts: AppKit needs a caret rectangle
(`firstRectForCharacterRange:`), the guest needs real preedit, commit,
cancel and focus (not typed-out characters), a native channel (no network),
and nothing that breaks the hardened runtime.

What the guest has (checked in the sources: Omarchy b83d3df, Hyprland
5a78b5e, Fcitx5 d82ac11, all from 2026-10):

- Omarchy runs Fcitx5 in every session (`omarchy-fcitx5.service`, packages
  `fcitx5`, `fcitx5-gtk`, `fcitx5-qt`), for its CapsLock compose sequences.
  `environment.d/10-omarchy-fcitx.conf` sets `QT_IM_MODULE=fcitx`,
  `XMODIFIERS=@im=fcitx`, `SDL_IM_MODULE=fcitx`; `GTK_IM_MODULE` is not
  set, so GTK uses text-input-v3.
- Hyprland speaks `zwp_input_method_v2` (with the keyboard grab and the
  popup surface), `zwp_text_input_v3` and `zwp_text_input_v1` (Chromium).
  It takes one input method per seat ("Cannot register 2 IMEs at once!",
  `InputMethodRelay.cpp`), and Fcitx5 already is that input method.
- Through input-method-v2 an input method never learns where the caret is.
  The app gives Hyprland a surface-local rectangle; Hyprland places the
  input method's popup next to it and tells the popup only its offset
  (`InputMethodPopup.cpp`). Fcitx5's Wayland frontend sets no cursor
  rectangle at all. Hyprland's IPC has no caret either.
- Fcitx5's other frontends do carry the caret: the D-Bus frontend (Qt
  through `fcitx5-qt`, GTK 3 and 4 through `fcitx5-gtk` when
  `GTK_IM_MODULE=fcitx`, kitty through its IBus mode) sends it relative to
  the window, with the scale (`SetCursorRectV2`, `CapabilityFlag::RelativeRect`);
  XIM (XWayland apps) sends it in root coordinates.
- Which Omarchy apps reach an input method at all: GTK 4 and 3 (Nautilus,
  ghostty, the launcher if GTK), Qt (QT_IM_MODULE), foot, alacritty and
  kitty (text-input-v3), XWayland apps (XIM). Chromium and Electron only
  with `--enable-wayland-ime`: Omarchy sets it for Obsidian, not in
  `chromium-flags.conf`. The same holds for a guest Fcitx5 engine today.

What the Mac side has: QEMU's `QemuCocoaView` (ui/cocoa.m) sends scancodes;
OmacVM's patches add the full-grab tap, the Cmd/Ctrl mapping, macOS's
system shortcuts and the globe key. The display port (`org.omacvm.display`,
omacvm-cocoa-displays.patch) is served inside QEMU's window code and
already knows where Hyprland put each output in logical pixels and which
Mac window shows it (the pointer mapping uses it).

## Options

Guest side:

1. Our own input-method-v2 client. Hyprland would refuse it while Fcitx5
   runs; stopping Fcitx5 loses Omarchy's compose key, XIM and the Qt path,
   and still gives no caret. No.
2. An Fcitx5 addon (a module, not an input method engine). It lives in the
   Fcitx5 that already runs: every frontend Fcitx5 has (Wayland IM v2,
   text-input-v1 for Chromium, D-Bus for Qt/GTK, XIM) works without new
   code, the keyboard engine and compose keep running, a guest engine
   (Mozc, Rime) still works next to it. It sees focus in and out, the
   caret rectangle where the frontend has one, and the field's kind
   (password, ...), and it can set the preedit and commit text on the
   focused input context. Compiled C++ against the VM's Fcitx5.
3. Fcitx5's Lua addons: no preedit or caret API, no file descriptor in the
   event loop. No.

Caret for apps that only speak text-input (Chromium, Electron, foot,
alacritty):

1. A Hyprland plugin that reads the caret box: the plugin ABI changes with
   every Hyprland release, and Omarchy updates Hyprland often. No.
2. Ask Hyprland upstream for the caret box in IPC or in the popup event:
   the clean fix; not posted (needs the maintainer's OK first).
3. Anchor on what the Mac already knows: the last click in the VM window
   if it came after the focus change, else the focused window's box (from
   Hyprland's IPC). The preedit itself is drawn by the app at the caret in
   every case; only the candidate list sits less exactly.

## Decision

Guest option 2, caret option 3 (and 2 later, with the OK), behind a new
feature `mac-ime` ("Mac input methods"): off by default, experimental,
`vm` side, app-only. Nothing changes while it is off.

### Channel

A virtio port `org.omacvm.ime` (`nr=8` on `vser0`), on every OmacVM.app VM
from its start whatever the setting, like `org.omacvm.auth`: turning the
feature on needs no VM restart and moves no PCI device. Its socket is
served by QEMU's window code (as `org.omacvm.display`, socket in
`OMACVM_IME_SOCKET`), because the window is where the keys and the input
context are. udev gives the port to the desktop user (0600), the user
Fcitx5 runs as.

JSON lines, at most 4 KiB a line (longer lines dropped), version in hello.
Numbers are checked as in the display port (finite, below 1e7); anything
else is dropped, never fatal.

Guest to Mac:

```
{"t":"hello","v":1}
{"t":"focus","on":true,"kind":"text","rect":[x,y,w,h],"exact":true}
{"t":"rect","rect":[x,y,w,h],"exact":true}
{"t":"focus","on":false}
```

`rect` in Hyprland's global logical pixels; `exact` false when only the
window's box is known. `kind` is `text` or `password` (Fcitx5's
`PasswordOrSensitive`).

Mac to guest:

```
{"t":"hello","v":1}
{"t":"preedit","text":"にほn","cursor":3,"segs":[[0,2,1],[2,3,0]]}
{"t":"commit","text":"日本"}
{"t":"cancel"}
```

`cursor` and `segs` in Unicode code points; a segment `[start,end,1]` is
the clause being converted (highlight), `0` an underline.

### Guest: the Fcitx5 addon

`src/ime/guest/`: `omacvm-ime` addon (about 400 lines of C++), built in
the VM against the installed Fcitx5 when the feature goes on, rebuilt by
`omacvm apply` when Fcitx5's version changed, as a pacman package like
`omacvm-box64`. An addon that does not load leaves Fcitx5 as it was: no
hello, so the Mac never switches over.

- Opens `/dev/virtio-ports/org.omacvm.ime` in Fcitx5's event loop, says
  hello.
- `InputContextFocusIn/Out`, `InputContextCursorRectChanged`,
  `InputContextCapabilityChanged`: sends focus and rect (debounced to one
  per frame). A relative rectangle gets the origin of Hyprland's focused
  window (`j/activewindow` on Hyprland's socket); an absolute one (XIM) is
  converted from X coordinates with the output's scale; a context with no
  rectangle (Wayland IM v2) sends the window's box with `exact:false`.
- preedit: `inputPanel().setClientPreedit()` with the segments and cursor,
  `updatePreedit()`; commit: `commitString()`; cancel: an empty preedit.
  Only on the input context that has the focus; a message for a context
  that lost it is dropped.
- With the feature on, `apply` also sets `GTK_IM_MODULE=fcitx` (so GTK
  apps, ghostty among them, give an exact caret) and adds
  `--enable-wayland-ime` to `chromium-flags.conf` and
  `electron-flags.conf`, each in a block marked as OmacVM's; off removes
  them. Both take effect at the next login; the check row says so.

### Mac: QEMU's window (`omacvm-cocoa-ime.patch`)

`QemuCocoaView` implements `NSTextInputClient` with its own
`NSTextInputContext`. `-inputContext` returns nil, and every key goes as a
scancode exactly as now, unless all of these hold:

- the guest said hello on `org.omacvm.ime` (the feature is on in the VM),
- the guest's last word is focus on, kind `text`,
- the current input source is an input method
  (`TISCopyCurrentKeyboardInputSource`, `kTISPropertyInputSourceType` is
  `kTISTypeKeyboardInputMode`; followed on
  `kTISNotifySelectedKeyboardInputSourceChanged`),
- the VM window has the keyboard.

Then, in the key path (also for keys from the full-grab tap):

- A key with Cmd or Ctrl held, and every modifier change, goes as a
  scancode (shortcuts and Hyprland binds unchanged). Option and Shift go
  to the input method.
- Every other key goes to `[ctx handleEvent:]`. `setMarkedText:` sends
  preedit, `insertText:` sends commit, `unmarkText` and an empty marked
  text send cancel. `doCommandBySelector:` (Return, Backspace, arrows, Esc
  with nothing marked) sends that key's scancode. An `insertText:` that is
  the key's own character with nothing marked (an input method in its
  Latin mode) also goes as the scancode, so terminals and key repeat
  behave as typing.
- The key-up of a key the input method took is not sent.
- `firstRectForCharacterRange:` maps the guest rectangle through the
  displays layout (the inverse of the pointer mapping: output, scale,
  notch and full-screen offsets, the window of that output) to screen
  coordinates. `exact:false`: the last mouse-down in that window if newer
  than the focus change, else the window's box.
- `attributedSubstringForProposedRange:` returns nil and
  `validAttributesForMarkedText` is empty: the Mac never reads the guest's
  text.
- Focus off, the window losing the keyboard, or the guest closing the
  port: `discardMarkedText` and cancel.
- Input source switching: while the conditions above hold except the
  input-method one, macOS's "Select the previous/next input source"
  shortcuts (symbolic hot keys 60 and 61, Ctrl+Space by default) and the
  globe key when System Settings says "Change Input Source" switch the
  Mac's input source (`TISSelectInputSource`) instead of going to the VM.
  Today both go to the VM while it has the keyboard
  (omacvm-cocoa-system-shortcuts.patch, omacvm-cocoa-globe-key.patch), so
  without this the user could not switch to their input method inside the
  VM.

### Where it shows

One row, same style as the other experimental ones, nothing new: the line
in `src/features.tsv`

```
mac-ime  off  vm  experimental,app-only  -  Mac input methods  type Chinese, Japanese and Korean in Omarchy with your Mac's own input methods and candidate window (OmacVM.app only)
```

gives the control centre's row (the app's Features… opens it), `omacvm
features` and `omacvm enable/disable mac-ime`. One switch row "Mac input
methods (experimental)" next to "Fast network (experimental)" in the app's
settings. A check row (addon built for the running Fcitx5, port open,
next-login settings in place). An entry in docs/features.md. No prompt, no
permission: AppKit's input context needs none.

## Consequences

- Works where a guest Fcitx5 engine works today, with the Mac's input
  method instead: Japanese (Kotoeri, Google Japanese Input), Chinese
  (Pinyin, Zhuyin, Cangjie, Wubi), Korean, and others that use marked text.
- Caret exact in Qt, GTK (with the GTK_IM_MODULE line), kitty and XWayland
  apps; window-anchored in Chromium, Electron, foot and alacritty until
  Hyprland gives the caret. A floating GTK window with client-side shadows
  is off by the shadow's width.
- Text fields in layer surfaces (launcher, menus) anchor at the layer's
  box at best.
- macOS features that read the document (reconversion, context-aware
  prediction) do not work: the Mac never sees guest text.
- Input-method shortcuts with Ctrl (Kotoeri's Ctrl+J/K/L) go to the VM,
  as every Ctrl chord does now.
- Password fields stay on scancodes.
- A guest Fcitx5 engine keeps working: with a plain Mac layout keys go as
  scancodes and Fcitx5 composes as before.
- Fcitx5 updates may need the addon rebuilt; until then the feature is
  quietly off and the check says why.
- No new entitlement, no injection, no helper: AppKit and HIToolbox calls
  in QEMU's own process, signed as now.

## Security

- The guest sends only focus, a field kind and rectangles. The Mac uses
  them for one thing: where the candidate window goes, and whether keys go
  as text or as scancodes. A lying guest can misplace the candidate
  window or keep keys as scancodes; it cannot read Mac state or start
  anything.
- The Mac sends only text the user typed into this VM's window, while
  that window has the keyboard, never in a password field.
- In the VM the port belongs to the desktop user. A program of that user
  could open it before Fcitx5 and get the composed text, but the same
  program can already replace Fcitx5 as the input method and see every
  key: no new boundary.

## Tests

- Offline: the line parser and rectangle mapping as a host test (fuzzed
  lines, wrong types, huge numbers, the 4 KiB limit), the addon's message
  handling against a fake port (`src/tests/ime/`), the patch in the build
  check.
- Real typing only on the MacBook Air (rule 61: no synthetic input on the
  Mac the user works on), test identity, test VM: Japanese (Kotoeri
  Romaji: preedit, Space conversion, clause moves, Return, Esc),
  Chinese Pinyin (candidates, full-width punctuation), Korean 2-set, in
  ghostty, a Qt app, Chromium with the flag, foot; Cmd chords, Hyprland
  binds and key repeat unchanged; the input-source shortcut and globe key;
  a password field; feature off byte-identical key path; two displays and
  the notch layout for the candidate position.
