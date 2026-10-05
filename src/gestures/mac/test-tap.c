// Offline test of when the helper creates its event tap again (test.sh): no
// permissions, no real tap. CGEventTapCreate is a stand-in that returns a
// plain Mach port, so installTap's swap (new tap in, old one out) and the
// re-arm rules run as they do in the helper.
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
static int created, failNext, enabled = 1;
static CFMachPortRef fakeTapCreate(CGEventTapLocation l, CGEventTapPlacement p, CGEventTapOptions o, CGEventMask m,
                                   CGEventTapCallBack cb, void *u) {
  (void)l; (void)p; (void)o; (void)m; (void)cb; (void)u;
  if (failNext) return NULL;
  created++;
  return CFMachPortCreate(NULL, NULL, NULL, NULL);
}
static bool fakeIsEnabled(CFMachPortRef t) { (void)t; return enabled; }
static void fakeEnable(CFMachPortRef t, bool on) { (void)t; enabled = on; }
#define CGEventTapCreate fakeTapCreate
#define CGEventTapIsEnabled fakeIsEnabled
#define CGEventTapEnable fakeEnable
#define main helper_main
#include "omacvm-gestures.c"
#undef main

static int fail;
static int fakeQemu(pid_t pid) { return pid != 1200; }   // 1200: OmacVM.app's launcher
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

int main(void) {
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  isQemuFn = fakeQemu;
  check(installTap() && created == 1, "the first tap");
  CFMachPortRef first = tapPort; CFRetain(first);
  // Front app, network, full screen, title, window, other: as updateCapture finds them.
  frontChanged(500, -1, 0, "", 0, 0);                    // Terminal
  check(created == 1, "no new tap for an app that is no VM");
  frontChanged(600, NET_APP, 1, "Omarchy", 0, 0);          // an OmacVM VM goes full screen
  check(created == 2, "new tap when an OmacVM VM comes to the front");
  check(!CFMachPortIsValid(first) && CFMachPortIsValid(tapPort), "the old tap is gone, the new one live");
  CFRelease(first);
  frontChanged(600, NET_APP, 1, "Omarchy", 0, 0);
  frontChanged(600, NET_APP, 1, "Omarchy", 0, 0);
  check(created == 2, "not again while the same VM stays in front (checked every 0.2 s)");
  frontChanged(700, NET_APP, 1, "Work", 0, 0);             // straight to a second VM (another QEMU)
  check(created == 3, "new tap for a second OmacVM VM, straight from the first");
  frontChanged(700, NET_APP, 0, "", 0, 0);                 // its window left full screen
  frontChanged(800, NET_APP, 1, "Omarchy", 0, 0);          // the app was restarted: a new QEMU
  check(created == 4, "new tap after OmacVM.app was restarted");
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(900, 0, 1, "Omarchy", 0, 0);                // Parallels: its app outlives its VMs
  check(created == 4, "no new tap for Parallels");
  CFMachPortInvalidate(tapPort);                     // macOS took it away
  frontChanged(900, 0, 1, "Omarchy", 0, 0);
  check(created == 5 && CFMachPortIsValid(tapPort), "new tap when macOS invalidated ours");
  enabled = 0;
  frontChanged(900, 0, 1, "Omarchy", 0, 0);
  check(created == 5 && enabled, "a disabled tap is enabled again, not created again");
  // Permission taken away: the old tap stays.
  failNext = 1;
  CFMachPortRef keep = tapPort;
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1000, NET_APP, 1, "Omarchy", 0, 0);
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1001, NET_APP, 1, "Omarchy", 0, 0);
  check(tapPort == keep && CFMachPortIsValid(keep), "a failed re-creation keeps the old tap");
  failNext = 0;
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1002, NET_APP, 1, "Omarchy", 0, 0);
  check(created == 6 && tapPort != keep, "works again once permitted");
  // An OmacVM VM in a window: its tap too (the escape combo is ours there).
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1100, NET_APP, 0, "", 0, 0);
  check(created == 7, "new tap when an OmacVM VM window comes to the front");
  frontChanged(1100, NET_APP, 1, "Omarchy", 0, 0);
  frontChanged(1100, NET_APP, 0, "", 0, 0);
  check(created == 7, "not again when that VM goes full screen and back (the same QEMU)");
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1200, NET_APP, 0, "", 0, 0);
  check(created == 7, "no new tap for OmacVM.app's launcher window");
  return fail;
}
