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
echo "check-boot-splash: the display agent counts by its hello when the window talks to it"
