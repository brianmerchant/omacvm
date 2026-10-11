#!/bin/bash
# FullPanel's rules (omacvm-cocoa-fullpanel-logic.patch): the patch makes
# ui/omacvm-fullpanel.h in an empty folder (with ui/omacvm-clean-size.h for
# the guest's size), and test-fullpanel.c runs against it on every notched
# MacBook's size, external displays and a window moving between them. No
# QEMU, no display, no notch. CI and the runtime build run it.
# With ui/cocoa.m as argument (the runtime build, after the wiring patch):
# also that the wiring is there and every way in goes through the rules.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fullpanel.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-fullpanel-logic.patch"
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-clean-size-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" \
  "$here/test-fullpanel.c" -o "$work/test-fullpanel"
"$work/test-fullpanel"

if (( $# )); then
  m=$1
else
  # CI has no QEMU checkout: inspect the resulting lines of the two wiring
  # patches. The runtime build still checks the fully patched cocoa.m.
  m=$work/wiring.m
  for patch in omacvm-cocoa-clean-size.patch omacvm-cocoa-fullpanel.patch; do
    awk '/^@@/ {on=1; next} on && /^-/ {next} on {print substr($0, 2)}' \
      "$patches/$patch" >> "$m"
  done
fi
fail() { echo "test-fullpanel: $m: $*" >&2; exit 1; }
# Asked for per start only, through the header's rule.
[[ $(grep -c 'getenv("OMACVM_FULLPANEL")' "$m") == 1 ]] || fail "OMACVM_FULLPANEL is not read once"
grep -q 'return omacvm_fp_requested(getenv("OMACVM_FULLPANEL"));' "$m" || fail "the start's switch is not omacvm_fp_requested"
# The three places that size the guest and the area ask the window first.
[[ $(grep -c 'omacvm_fullpanel_window_usable(' "$m") -ge 5 ]] || fail "screenSafeAreaSize, the full-screen size or the display box does not ask FullPanel"
grep -q 'if (below_notch && !omacvm_fullpanel_window_usable(\[cocoaView window\])) {' "$m" || fail "the display box ignores FullPanel"
# The guest's size: default uncut; explicit opt-in through the same rule.
grep -q 'full = omacvm_fp_cut_rows(isFullscreen, omacvm_present_layer(),' "$m" || fail "clean-size does not use the FullPanel cut rule"
[[ $(grep -c 'getenv("OMACVM_FULLPANEL_CLEAN_SIZE")' "$m") == 1 ]] || fail "clean-size opt-in is not read at its one selection site"
grep -qF 'omacvm_fp_requested(getenv("OMACVM_FULLPANEL_CLEAN_SIZE")));' "$m" || fail "clean-size opt-in does not require exactly 1"
cut=$(grep -A3 -F 'full = omacvm_fp_cut_rows(' "$m")
grep -qF '[[[self window] screen] safeAreaInsets].top,' <<< "$cut" || fail "clean-size ignores this display's notch"
grep -qF 'omacvm_fullpanel_window_usable([self window]),' <<< "$cut" || fail "clean-size ignores this window's FullPanel state"
# Reuse clean-size's picture alignment, driven by the surface actually shown.
for line in \
  'backingScale, full);' \
  'omacvm_full_cut = full ? (backingFrameSize.height - clean.h) / backingScale : 0;' \
  'fabs(screen.height - (area.height - omacvm_full_cut) * scale) < 0.5;' \
  '[self omacvmGuestAtTop:top];' \
  '[[self window] setContentSize:area];' \
  'band = omacvm_top_band(lround(b.width * s), lround(b.height * s),' \
  '(long)IOSurfaceGetHeight(surf), s);' \
  'g = [layer contentsAreFlipped] ? kCAGravityBottom : kCAGravityTop;' \
  'qatomic_xchg(&omacvm_shown_band, band)' \
  'qatomic_read(&omacvm_shown_band) / scale' \
  'position.y += [self omacvmBlackRows];' \
  'CGFloat d = (CGFloat)screen.height / ([self frame].size.height - cut);' \
  'p.y = MAX(0, p.y - cut);' \
  'size.height -= black;' \
  'p.y = MAX(0, p.y - black);' \
  'omacvm_mac_box[0].h -= [cocoaView omacvmBlackRows];'; do
  grep -qF "$line" "$m" || fail "clean-size alignment missing: $line"
done
[[ $(grep -cF 'omacvm_present_gravity(layer, surf);' "$m") == 2 ]] || fail "both IOSurface presentation paths must align the picture"
# Both window classes: prepared on the way into full screen, frames kept.
[[ $(grep -c 'omacvm_fullpanel_prepare_window(self);' "$m") == 2 ]] || fail "QemuWindow and OmacVMHeadWindow are not both prepared"
[[ $(grep -c 'if (omacvm_fullpanel_keep_frame(self, ' "$m") == 10 ]] || fail "not every frame setter of both windows goes through omacvm_fullpanel_keep_frame"
# The decisions are the tested ones.
for f in omacvm_fp_display_ok omacvm_fp_cut_rows omacvm_fp_frame omacvm_fp_keep omacvm_fp_strip_lost omacvm_fp_reveal_allowed omacvm_fp_presentation; do
  grep -q "$f(" "$m" || fail "$f is not used"
done
# Private interfaces only looked up at run time (no link to SkyLight).
grep -q 'dlopen(' "$m" && grep -q '"SLSTransactionSetMenuBarSystemOverrideAlpha"' "$m" || fail "SkyLight is not looked up at run time"
grep -q '"_frameForFullScreenMode"' "$m" || fail "the frame hook is not looked up by name"
# SLSTransactionCommit returns nothing (macOS 27: w0 left over): never read as a status.
grep -q 'typedef void (\*OmacVMSLSTransactionCommitFn)(CFTypeRef, int32_t);' "$m" || fail "SLSTransactionCommit is not declared void"
! grep -q '= omacvm_fullpanel_sls_transaction_commit(' "$m" || fail "SLSTransactionCommit's leftover w0 is read as a status"
# The menu bar's presentation goes through the tested rule, AppKit's bits checked.
grep -q 'if (!omacvm_fp_presentation(&in, &options)) {' "$m" || fail "the presentation options are not omacvm_fp_presentation's"
[[ $(grep -c 'QEMU_BUILD_BUG_ON(NSApplicationPresentation' "$m") == 5 ]] || fail "the presentation bits are not checked against AppKit's"
# What omacvm check reads.
grep -q '"omacvm: full panel: strip covered: ' "$m" || fail "no 'strip covered' line for omacvm check"
echo "test-fullpanel: $m: wiring ok"
