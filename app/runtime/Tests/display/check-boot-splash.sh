#!/bin/bash
# check-boot-splash.sh: the boot splash's offline checks without QEMU's source
# (CI runs it): the logo's cells, the start animation's table and its core are
# in ui/omacvm-splash.h, a new file of omacvm-cocoa-boot-splash.patch, so they
# are taken from the patch; so is the logo layer's no-action list (ui/cocoa.m). build-qemu-gpu-runtime.sh runs the same checks on
# the patched source.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
runtime=$(cd "$here/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ui/omacvm-splash.h is a new file in the patch: its lines without the +.
awk '/^\+\+\+ b\/ui\/omacvm-splash.h$/ { on = 1; next } on && /^(diff|--- )/ { exit }
     on && /^\+/ { print substr($0, 2) }' \
  "$runtime/patches/omacvm-cocoa-boot-splash.patch" > "$tmp/omacvm-splash.h"
python3 "$here/test-boot-splash-cells.py" "$tmp/omacvm-splash.h"
python3 "$runtime/boot-logo/make-splash-morph.py" --check "$tmp/omacvm-splash.h"
cc -Wall -Wextra -Werror -I"$tmp" "$here/test-boot-splash-morph.c" -o "$tmp/test-boot-splash-morph"
"$tmp/test-boot-splash-morph"
# The logo layer's no-action list, from ui/cocoa.m's part of the patch: the
# fade into the desktop must run once (no implicit opacity animation).
awk '/NSDictionary \*none = @\{/ { on = 1 } on { sub(/^\+/, ""); print } on && /\};$/ { exit }' \
  "$runtime/patches/omacvm-cocoa-boot-splash.patch" |
  sed -e 's/.*NSDictionary \*none = //' -e 's/};$/}/' > "$tmp/intro-actions.inc"
cc -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -I"$tmp" \
  "$here/test-boot-splash-fade.m" -framework Foundation -framework QuartzCore -framework OpenGL \
  -o "$tmp/test-boot-splash-fade"
"$tmp/test-boot-splash-fade"
# Through the launcher QEMU's window has the display agent's port open, and
# the firmware then opens it too (EDK2's VirtioSerialDxe answers the host's
# open): an open port is no desktop. With the channel only the agent's hello
# counts; the hello sets it, a reset clears it.
p="$runtime/patches/omacvm-cocoa-boot-splash.patch"
awk '/^\+static bool omacvm_splash_agent_up\(void\)$/ { on = 1 } on { print } on && /^\+}$/ { exit }' "$p" \
  > "$tmp/agent-up.inc"
grep -q 'getenv("OMACVM_DISPLAY_SOCKET")' "$tmp/agent-up.inc" &&
  grep -q 'return qatomic_read(&omacvm_display_hello);' "$tmp/agent-up.inc" ||
  { echo "FAIL: the display agent counts by its open port, not its hello" >&2; exit 1; }
awk '/^\+static void omacvm_splash_reset\(void \*opaque\)$/ { on = 1 } on { print } on && /^\+}$/ { exit }' "$p" |
  grep -q 'qatomic_set(&omacvm_display_hello, false);' ||
  { echo "FAIL: a guest reset does not forget the agent's hello" >&2; exit 1; }
grep -A3 '^ *if (d\[@"hello"\]) {$' "$p" | grep -q '^+ *qatomic_set(&omacvm_display_hello, true);' ||
  { echo "FAIL: the agent's hello does not reach the boot logo" >&2; exit 1; }
# The window's logo goes as omacvm_splash_look says (test-boot-splash-morph.c
# tests it: it waits for the wallpaper after the hello). After the time limit
# the tick keeps looking and marks the desktop when it comes, so an output it
# turns off later is black, not the logo.
awk '/^\+static void omacvm_hold_tick\(void \*opaque\)$/ { on = 1 } on { print } on && /^\+}$/ { exit }' "$p" \
  > "$tmp/hold-tick.inc"
grep -q 'omacvm_splash_look(' "$tmp/hold-tick.inc" ||
  { echo "FAIL: the boot logo does not go by omacvm_splash_look" >&2; exit 1; }
awk '/^\+ *if \(omacvm_watching\) \{$/ { on = 1 } on { print } on && /^\+ *return;$/ { exit }' "$tmp/hold-tick.inc" |
  grep -q 'omacvm_desktop_up = true;' ||
  { echo "FAIL: a desktop after the time limit is not marked (its screen off shows the logo)" >&2; exit 1; }
grep -A3 '^+ *case SPLASH_LOOK_LIMIT:$' "$tmp/hold-tick.inc" | grep -q 'omacvm_watching = true;' ||
  { echo "FAIL: the time limit stops looking for the desktop" >&2; exit 1; }
# A window that is not visible gets no display-link frames: the fade must not
# wait for the animation's last frame then.
awk '/^\+- \(void\)reveal:\(BOOL\)now$/ { on = 1 } on { print } on && /^\+}$/ { exit }' "$p" |
  grep -q 'fadeIfStalled' && grep -q '^+    if (left <= 0 && CACurrentMediaTime() - last_tick > 0.25) {$' "$p" ||
  { echo "FAIL: the logo waits for display-link frames a hidden window never gets" >&2; exit 1; }
# A display link that stops while the animation runs is replaced (and logged).
awk '/^\+- \(void\)play$/ { on = 1 } on { print } on && /^\+}$/ { exit }' "$p" | grep -q 'watchLink' &&
  awk '/^\+- \(void\)watchLink$/ { on = 1 } on { print } on && /^\+}$/ { exit }' "$p" | grep -q 'makeLink' ||
  { echo "FAIL: a display link that stops mid-animation is not replaced" >&2; exit 1; }
# The logo layer holds its display link: one that only the run loop held was
# freed inside its -invalidate and QEMU aborted (a link without frames in a
# window that is not visible). Only -dropLink invalidates it.
awk '/^\+- \(void\)(makeLink|dropLink)$/ { on = 1 } on { print substr($0, 2) } on && /^\+}$/ { on = 0; print "" }' \
  "$p" > "$tmp/link.inc"
[ "$(grep -c '\[link invalidate\]' "$p")" = 1 ] && grep -q '\[link invalidate\]' "$tmp/link.inc" ||
  { echo "FAIL: the boot logo invalidates its display link outside -dropLink" >&2; exit 1; }
cc -fno-objc-arc -Wall -Wextra -Werror -I"$tmp" "$here/test-boot-splash-link.m" \
  -framework Cocoa -framework QuartzCore -o "$tmp/test-boot-splash-link"
"$tmp/test-boot-splash-link"
echo "check-boot-splash: the display agent counts by its hello when the window talks to it"
echo "check-boot-splash: the logo waits for the wallpaper; a desktop after the time limit is marked"
