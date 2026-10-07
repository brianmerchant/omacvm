#!/bin/bash
# No light line around a borderless window (omacvm-cocoa-borderless-no-rim.patch),
# checked in the patched ui/cocoa.m. macOS 26 draws a 1 pt rim (white at
# about 20 %) with a window's shadow; a window made titled and then switched
# borderless keeps its shadow, so the rim ran around the whole display:
#   - every switch to borderless goes through omacvm_set_borderless, which
#     drops the shadow (no other setStyleMask:NSWindowStyleMaskBorderless);
#   - the main window's borderless full screen (tests) and the other displays'
#     borderless windows (tests) use it;
#   - leaving the main window's borderless full screen gives the shadow back
#     (the windowed look keeps macOS's frame and shadow).
# The pixels themselves: test-borderless-rim-live.sh on a Mac with macOS 26+.
#   test-borderless-rim.sh <patched ui/cocoa.m>   (the runtime build)
#   test-borderless-rim.sh --self-test            (CI: the checks catch the old code)
set -uo pipefail

body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }

# Prints what is wrong with FILE, nothing if it is right.
problems() {
  local f=$1 helper toggle head
  helper=$(body "$f" 'static void omacvm_set_borderless(NSWindow *w, NSWindowStyleMask extra)')
  toggle=$(body "$f" 'static void omacvm_toggle_notch_full_screen(void)')
  head=$(body "$f" 'static void omacvm_head_on(OmacVMHead *hd, NSScreen *s)')
  if [[ -z $helper ]]; then
    echo "no omacvm_set_borderless"
  else
    grep -q '\[w setStyleMask:NSWindowStyleMaskBorderless | extra\];' <<<"$helper" ||
      echo "omacvm_set_borderless does not make the window borderless"
    awk '/setStyleMask:NSWindowStyleMaskBorderless/{m=NR} /\[w setHasShadow:NO\];/{s=NR} END{exit !(m && s && m < s)}' \
      <<<"$helper" || echo "omacvm_set_borderless keeps the shadow (macOS 26 draws its rim around the display)"
  fi
  [[ $(grep -c 'setStyleMask:NSWindowStyleMaskBorderless' "$f") -le 1 ]] ||
    echo "a window is made borderless outside omacvm_set_borderless (it keeps its shadow and rim)"
  [[ -n $toggle ]] || echo "no omacvm_toggle_notch_full_screen"
  [[ -z $toggle ]] || {
    grep -q 'omacvm_set_borderless(w, NSWindowStyleMaskResizable);' <<<"$toggle" ||
      echo "the borderless full screen does not drop the shadow"
    awk '/notchSavedShadow = \[w hasShadow\];/{a=NR} /omacvm_set_borderless\(w,/{b=NR}
         END{exit !(a && b && a < b)}' <<<"$toggle" || echo "the shadow is not saved before it is dropped"
    awk '/\[w setStyleMask:notchSavedMask\];/{a=NR} /\[w setHasShadow:notchSavedShadow\];/{b=NR}
         END{exit !(a && b && a < b)}' <<<"$toggle" ||
      echo "leaving the borderless full screen does not give the window its shadow back"
  }
  [[ -n $head ]] || echo "no omacvm_head_on"
  [[ -z $head ]] || grep -q 'omacvm_set_borderless(hd->window, 0);' <<<"$head" ||
    echo "another display's borderless window keeps its shadow"
}

if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-rim.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  fail=0
  good() { cat <<'EOF'
static NSWindowStyleMask notchSavedMask;
static BOOL notchSavedShadow;

static void omacvm_set_borderless(NSWindow *w, NSWindowStyleMask extra)
{
    [w setStyleMask:NSWindowStyleMaskBorderless | extra];
    [w setHasShadow:NO];
}

static void omacvm_toggle_notch_full_screen(void)
{
    NSWindow *w = [cocoaView window];
    if (!notchFull) {
        notchFull = YES;
        notchSavedMask = [w styleMask];
        notchSavedShadow = [w hasShadow];
        omacvm_set_borderless(w, NSWindowStyleMaskResizable);
        [w setFrame:[target frame] display:YES];
    } else {
        notchFull = NO;
        [w setStyleMask:notchSavedMask];
        [w setHasShadow:notchSavedShadow];
        [w setFrame:notchSavedFrame display:YES];
    }
}

static void omacvm_head_on(OmacVMHead *hd, NSScreen *s)
{
    if (omacvm_test_mode()) {
        omacvm_set_borderless(hd->window, 0);
        [hd->window setFrame:r display:YES];
    }
}
EOF
  }
  case_() {   # WHAT WANT(ok|fail) FILE
    local p; p=$(problems "$3")
    if [[ $2 == ok && -z $p ]] || [[ $2 == fail && -n $p ]]; then echo "ok   $1${p:+ ($p)}"
    else echo "FAIL $1: want $2, got: ${p:-no problem}"; fail=1; fi
  }
  good > "$T/good.m"
  case_ "the fixed code" ok "$T/good.m"
  # 3.0.3: setStyleMask alone, the shadow (and macOS 26's rim) stays.
  good | sed -e 's/^        omacvm_set_borderless(w, NSWindowStyleMaskResizable);$/        [w setStyleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable];/' \
    -e '/notchSavedShadow/d' > "$T/main.m"
  case_ "the main window made borderless with its shadow (3.0.3)" fail "$T/main.m"
  good | sed 's/^        omacvm_set_borderless(hd->window, 0);$/        [hd->window setStyleMask:NSWindowStyleMaskBorderless];/' > "$T/head.m"
  case_ "another display's window made borderless with its shadow (3.0.3)" fail "$T/head.m"
  good | sed '/^    \[w setHasShadow:NO\];$/d' > "$T/helper.m"
  case_ "a helper that keeps the shadow" fail "$T/helper.m"
  good | sed '/^        \[w setHasShadow:notchSavedShadow\];$/d' > "$T/restore.m"
  case_ "windowed again without a shadow" fail "$T/restore.m"
  good | sed '/^        notchSavedShadow = \[w hasShadow\];$/d' > "$T/save.m"
  case_ "the shadow not saved first" fail "$T/save.m"
  exit $fail
fi

[[ -f ${1:-} ]] || { echo "usage: $0 <patched ui/cocoa.m> | --self-test" >&2; exit 2; }
p=$(problems "$1")
if [[ -n $p ]]; then printf 'FAIL %s\n' "$p"; exit 1; fi
echo "ok   borderless windows have no shadow (no macOS 26 rim); windowed again with it"
