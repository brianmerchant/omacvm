#!/bin/bash
# The Mac's input methods in the VM (mac-ime): the rules
# (omacvm-cocoa-ime-logic.patch makes ui/omacvm-ime.h in an empty folder,
# test-ime.c runs against it) and the hooks omacvm-cocoa-ime.patch puts into
# ui/cocoa.m: with the feature off (no OMACVM_IME_SOCKET) nothing of it runs
# and every key takes QEMU's path as before. No QEMU, no display.
#   test-ime.sh                       (CI: the hooks from the patch)
#   test-ime.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-ime.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-ime-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$work/ui" \
  "$here/test-ime.c" -o "$work/test-ime" -lm
"$work/test-ime"
if [[ $# -ge 1 ]]; then
  src=$1
else
  # The patch's new side: context and added lines, without the removed ones.
  src=$work/new.m
  awk '/^@@/ {on=1; next} on && /^-/ {next} on {print substr($0, 2)}' \
    "$patches/omacvm-cocoa-ime.patch" > "$src"
fi
fail=0
body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
has() { if grep -qF -- "$3" <<<"$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
# handleEvent: right after the marked-key check, before QEMU's own handling (BQL).
ev=$(grep -B4 -A3 -F 'if (omacvm_ime_on && omacvm_ime_key(event)) {' "$src" || true)
has "handleEvent: asks mac-ime only when it is on" "$ev" 'if (omacvm_ime_on && omacvm_ime_key(event)) {'
order=$(grep -nF -e 'if (omacvm_key_for_macos(event)) {' -e 'if (omacvm_ime_on && omacvm_ime_key(event)) {' -e 'return bool_with_bql(^{' <<<"$ev" | cut -d: -f1 | tr '\n' ' ')
[[ $(wc -w <<<"$order") -eq 3 && $order == "$(tr ' ' '\n' <<<"$order" | grep . | sort -n | tr '\n' ' ')" ]] &&
  echo "ok   ... after the keys for macOS, before QEMU's own handling" ||
  { echo "FAIL handleEvent: the mac-ime hook is not between the macOS-key check and QEMU's handling"; fail=1; }
[[ $(grep -cF 'omacvm_ime_key(' "$src") -eq 3 ]] && echo "ok   ... the only call (declaration, definition, handleEvent:)" ||
  { echo "FAIL omacvm_ime_key is called somewhere else too"; fail=1; }
init=$(body "$src" 'static void omacvm_ime_init(void)')
has "omacvm_ime_on only with OMACVM_IME_SOCKET" "$init" 'if (!path || !*path) {'
on_line=$(grep -nF 'omacvm_ime_on = true;' <<<"$init" | cut -d: -f1)
ret_line=$(grep -nF 'if (!path || !*path) {' <<<"$init" | cut -d: -f1)
[[ -n $on_line && -n $ret_line && $on_line -gt $ret_line ]] && echo "ok   ... set after that check" ||
  { echo "FAIL omacvm_ime_init sets omacvm_ime_on before checking OMACVM_IME_SOCKET"; fail=1; }
n=$(grep -c 'omacvm_ime_on = ' "$src" || true)
[[ $n -eq 1 ]] && echo "ok   ... and nowhere else" || { echo "FAIL omacvm_ime_on is set in $n places"; fail=1; }
has "the globe key: mac-ime only when on" "$(cat "$src")" '!(omacvm_ime_on && omacvm_ime_globe())) {'
has "the view's input context: none while off" "$(body "$src" '- (NSTextInputContext *)inputContext')" 'return omacvm_ime_on && omacvm_ime_active(&omacvm_ime) ? omacvm_ime_ctx : nil;'
[[ $(grep -A1 -xF '    omacvm_globe_init();' "$src" | tail -1) == '    omacvm_ime_init();' ]] &&
  echo "ok   started with the display (after the globe key)" || { echo "FAIL omacvm_ime_init() is not called after omacvm_globe_init()"; fail=1; }
as=$(body "$src" '- (NSAttributedString *)attributedSubstringForProposedRange:')
has "the input method reads back only its own marked text" "$as" 'if (!omacvm_ime_marked || range.location == NSNotFound) {'
has "... never more than it" "$as" 'r = NSIntersectionRange(range, NSMakeRange(0, [omacvm_ime_marked length]));'
has "the guest's caret is checked before use" "$(cat "$src")" 'omacvm_ime_rect_ok(x, y, w, h)'
# A caret as tall as its field (a GTK entry taller than its line): the candidate
# window goes to the field's middle, where GTK draws the line, not its top.
has "a caret taller than a line: its middle" "$(body "$src" 'static NSRect omacvm_ime_caret(void)')" 'r.origin.y = NSMidY(r) - 20;'
exit $fail
