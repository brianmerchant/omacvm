#!/bin/bash
# The pixels behind omacvm-cocoa-borderless-no-rim.patch, on a Mac with
# macOS 26 or newer (macOS 15 draws no rim, so there it proves nothing).
# Builds rim-probe.m with the patch's omacvm_set_borderless and shows a small
# black borderless window outside every display, twice: made borderless as
# 3.0.3 did (setStyleMask alone, shadow kept) and through the helper. Passes
# when the helper's window has no light edge; says whether the old one had
# the rim (the proof that this Mac draws it). No VM, no QEMU, no input; the
# window never shows on a display and never takes the focus.
#   test-borderless-rim-live.sh            (in a GUI login session; over SSH too)
#   RIM_PROBE_AT="x,y" test-borderless-rim-live.sh   (the window on screen there)
#   test-borderless-rim-live.sh --build-only          (CI: the probe builds with the patch's helper)
# When the probe cannot capture its own window it asks for `screencapture -l`;
# RIM_NO_SCREENCAPTURE=1 skips that (over SSH it can raise macOS's screen
# capture prompt).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patch_file="$here/../../patches/omacvm-cocoa-borderless-no-rim.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-rim-live.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The helper exactly as the patch adds it.
awk '/^\+static void omacvm_set_borderless\(NSWindow \*w, NSWindowStyleMask extra\)$/{on=1}
     on{sub(/^\+/, ""); print} on && /^}$/{exit}' "$patch_file" > "$work/borderless-helper.inc"
grep -q 'setHasShadow:NO' "$work/borderless-helper.inc" || { echo "FAIL no omacvm_set_borderless in the patch"; exit 1; }
cc -fobjc-arc -Wall -Wextra -Werror -I"$work" "$here/rim-probe.m" -framework AppKit -o "$work/rim-probe"
if [[ ${1:-} == --build-only ]]; then echo "ok   rim-probe builds with the patch's omacvm_set_borderless"; exit 0; fi

run() {   # MODE: prints the probe's line
  local mode=$1 png="$work/$1.png" line
  rm -f "$png"
  exec 3< <("$work/rim-probe" "$mode" "$png")
  while IFS= read -r line <&3; do
    case $line in
      wid=*) [[ -n ${RIM_NO_SCREENCAPTURE:-} ]] ||
               { /usr/sbin/screencapture -x -l "${line#wid=}" "$png.tmp" && mv "$png.tmp" "$png"; } ;;
      *) echo "$line" ;;
    esac
  done
  exec 3<&-
}

echo "macOS $(sw_vers -productVersion)"
old=$(run old); echo "     $old"
fixed=$(run fixed); echo "     $fixed"
[[ $fixed == *" rim="* ]] || { echo "FAIL the probe could not measure its window"; exit 1; }
[[ $fixed == *" shadow=no "* ]] || { echo "FAIL the helper left the shadow on"; exit 1; }
[[ $fixed == *" rim=no" ]] || { echo "FAIL the borderless window still has a light edge"; exit 1; }
if [[ $old == *" rim=yes" ]]; then
  echo "ok   this Mac draws the rim on a borderless window with a shadow; without the shadow, none"
else
  echo "ok   no rim with the helper (this Mac drew none without it either: the proof needs macOS 26+)"
fi
