// Offline test of the wait for the permissions at start (#330): the helper
// waits on the run loop and looks every 3 s; a grant given while it waits
// makes the tap and starts the listener without a restart; a new process that
// may while this one may not makes it start again, once (an hour apart, or
// another build), through its LaunchAgent or open. The permissions, the tap
// and the new process are stand-ins: nothing is asked of macOS.
#define main helper_main
#include "omacvm-gestures.c"
#undef main

static int fail;
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) fail = 1;
}

static int fakePerm;
static int fakePermFn(void) { return fakePerm; }
static int fakeFresh = -1;
static int fakeFreshFn(void) { return fakeFresh; }

static int fakeSlowFn(void) { return fakePerm & ~PERM_AX; }
static int fakeTap(void) { return (fakePerm & PERM_AX) != 0; }
static int started, relaunched;
static void fakeStart(void) { waiting = 0; started++; }
static void fakeRelaunch(void) { relaunched++; }

// Runs the main run loop for a while (the fresh answers come back through it).
static void spin(double s) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, s, false); }

int main(void) {
  char dir[] = "/tmp/omacvm-wait-XXXXXX";
  if (!mkdtemp(dir)) return 1;
  char stamp[256]; snprintf(stamp, sizeof stamp, "%s/relaunched", dir);

  // mayRelaunch: once per build, again after an hour.
  check(mayRelaunch(stamp, "100-1", 1000) == 1, "first time: it may start again (stamp written)");
  check(mayRelaunch(stamp, "100-1", 1100) == 0, "the same build within the hour: not again (never a loop)");
  check(mayRelaunch(stamp, "100-1", 1000 + 3600) == 1, "an hour later: once more");
  check(mayRelaunch(stamp, "200-2", 1000 + 3601) == 1, "another build: once more");
  check(mayRelaunch("/nonexistent-dir/x", "300-3", 1) == 0, "no stamp can be written: never");

  // relaunchHow: its LaunchAgent, a copy macOS or open started, or neither.
  const char *id = "org.omacvm.gestures", *app = "/Users/x/Applications/OmacVMGestures.app";
  check(relaunchHow("org.omacvm.gestures", id, app) == RELAUNCH_LAUNCHD, "LaunchAgent job (label = bundle id): exit, KeepAlive starts it");
  check(relaunchHow("application.org.omacvm.gestures.123.456", id, app) == RELAUNCH_OPEN,
        "started by macOS (\"Quit & Reopen\") or open: a new copy through open");
  check(relaunchHow("application.org.omacvm.gestures.1.2", id, "/usr/local/bin/omacvm-gestures") == 0, "no app bundle: neither");
  check(relaunchHow("0", id, app) == 0, "a shell: neither");
  check(relaunchHow("org.other.job", id, app) == 0, "someone else's job: neither");
  check(relaunchHow("application.org.omacvm.gesturesx.1", id, app) == 0, "another id that starts the same: neither");
  check(relaunchHow(NULL, id, app) == 0 && relaunchHow("org.omacvm.gestures", "", app) == 0, "nothing known: neither");

  // The wait: missing, then granted while it waits -> the tap and the start.
  // The tap, the start (listeners, trackpads) and the restart are stand-ins:
  // this test never takes the keyboard or a port.
  permFn = fakePermFn;
  freshPermFn = fakeFreshFn;
  slowPermFn = fakeSlowFn;
  installTapFn = fakeTap;
  startRunningFn = fakeStart;
  relaunchFn = fakeRelaunch;
  fakePerm = 0;
  waiting = 1;
  waitTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 3, 0, 0, waitTick, NULL);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), waitTimer, kCFRunLoopCommonModes);
  for (int i = 0; i < 6; i++) { waitLook(); spin(0.05); }
  check(waiting && !started && !relaunched, "nothing granted: still waiting, no tap, no listener, no restart");
  fakeFresh = 0;
  for (int i = 0; i < 9; i++) { waitLook(); spin(0.05); }
  check(waiting && !relaunched, "a new process may not either: waits on (no restart)");
  // Granted while waiting: the next look (3 s, or macOS's Accessibility
  // notification) makes the tap and starts the listener; no restart.
  fakePerm = PERM_AX | PERM_IM;
  accessibilityChanged(NULL, NULL, NULL, NULL, NULL);
  check(!waiting && started == 1 && !relaunched && !CFRunLoopTimerIsValid(waitTimer),
        "granted while waiting: tap made and listener started on the next look, the wait timer gone");
  waitLook();
  check(started == 1, "after the start: the wait does nothing more");

  // macOS tells only a new process: this one keeps "missing", a new one says
  // granted twice in a row -> started again (once: relaunchOnce's stamp).
  fakePerm = 0; started = 0; waiting = 1; fakeFresh = PERM_AX;
  waitTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 3, 0, 0, waitTick, NULL);
  for (int i = 0; i < 9 && !relaunched; i++) { waitLook(); spin(0.05); }
  check(relaunched == 1 && !started, "a new process may, this one may not (twice): started again");
  // Only Input Monitoring in the new one: the tap needs Accessibility, no restart.
  relaunched = 0; fakeFresh = PERM_IM;
  for (int i = 0; i < 12; i++) { waitLook(); spin(0.05); }
  check(!relaunched, "a new process has only Input Monitoring: no restart (the tap needs Accessibility)");
  unlink(stamp); rmdir(dir);
  return fail;
}
