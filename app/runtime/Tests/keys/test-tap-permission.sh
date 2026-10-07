#!/bin/bash
# QEMU's full-grab tap without Accessibility (omacvm-cocoa-tap-permission.patch,
# issue #192): reenableEventTap and omacvmKeepTap run in a small program with
# a made-up tap (a plain Mach port on the run loop) and a made-up
# Accessibility switch. Taken away: never enabled again, and the tap, its port
# and run-loop source are gone right after the callback; granted: enabled
# again and kept. No QEMU, no permissions.
#   test-tap-permission.sh                       (CI: the methods from the patch)
#   test-tap-permission.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-tap-permission.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [[ $# -ge 1 ]]; then
  src=$1
else
  # The patch's new side: context and added lines, without the removed ones.
  src=$work/new.m
  awk '/^@@/ {on=1; next} on && /^-/ {next} on {print substr($0, 2)}' \
    "$patches/omacvm-cocoa-tap-permission.patch" > "$src"
fi
body() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
reenable=$(body "$src" '- (void) reenableEventTap')
keep=$(body "$src" '- (BOOL) omacvmKeepTap')
[[ -n $reenable && -n $keep ]] || { echo "FAIL reenableEventTap or omacvmKeepTap not found in $src"; exit 1; }
fail=0
need() { if grep -qF "$2" "$src"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
need "setFullGrab looks every second (common modes)" 'NSTimer *permission = [NSTimer timerWithTimeInterval:1.0 repeats:YES'
need "... and on macOS's Accessibility list changing" 'addObserverForName:@"com.apple.accessibility.api"'
need "... with the run loop's common modes" '[[NSRunLoop mainRunLoop] addTimer:permission forMode:NSRunLoopCommonModes];'
cat > "$work/test.m" <<OBJC
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
static int trusted = 1, enabled, warned;
static Boolean fakeTrusted(void) { return trusted; }
static void fakeEnable(CFMachPortRef t, bool on) { (void)t; enabled = on; }
#define AXIsProcessTrusted fakeTrusted
#define CGEventTapEnable fakeEnable
#define warn_report(...) (warned++)
@interface View : NSObject { @public CFMachPortRef eventsTap; }
- (void) reenableEventTap;
- (BOOL) omacvmKeepTap;
@end
@implementation View
$reenable
$keep
@end
static int failed;
static void check(int ok, const char *what) { printf("%s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) failed = 1; }
static void drain(void) { for (int i = 0; i < 5; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false); }
int main(void) {
  View *v = [View new];
  CFMachPortRef port = CFMachPortCreate(NULL, NULL, NULL, NULL);
  CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, port, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
  v->eventsTap = port; CFRetain(port);
  [v reenableEventTap];
  check(enabled && v->eventsTap == port, "disabled by macOS, Accessibility there: enabled again");
  check([v omacvmKeepTap] && v->eventsTap == port && CFMachPortIsValid(port), "the check keeps it");
  enabled = 0; trusted = 0;
  [v reenableEventTap];
  check(!enabled, "disabled by macOS, Accessibility gone: not enabled again");
  drain();
  check(!v->eventsTap && !CFMachPortIsValid(port) && !CFRunLoopSourceIsValid(src) &&
        !CFRunLoopContainsSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode) && warned == 1,
        "... the tap, its port and run-loop source gone right after the callback, said once");
  trusted = 1;
  [v reenableEventTap];
  check(!enabled && ![v omacvmKeepTap], "no tap any more: nothing enabled, the check says so (its timer stops)");
  View *w = [View new];
  CFMachPortRef p2 = CFMachPortCreate(NULL, NULL, NULL, NULL);
  w->eventsTap = p2; CFRetain(p2);
  trusted = 0;
  check(![w omacvmKeepTap] && !w->eventsTap && !CFMachPortIsValid(p2) && warned == 2,
        "the check (every second, or the Accessibility list changed) removes it at once");
  CFRelease(port); CFRelease(p2); CFRelease(src);
  return failed;
}
OBJC
cc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter "$work/test.m" -framework Foundation -framework ApplicationServices \
  -o "$work/test" || { echo "FAIL the methods do not compile"; exit 1; }
"$work/test" || fail=1
exit $fail
