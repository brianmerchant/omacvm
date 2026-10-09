// Offline test of clearOldGrants (#306): when a permission is missing at
// start, the helper clears its own entry for it once per build (an entry
// macOS kept for another build's signature), never one it has. tccutil is a
// stand-in that records the calls; nothing is reset on this Mac.
#define main helper_main
#include "omacvm-gestures.c"
#undef main

static char calls[512];
static int fakeReset(const char *service, const char *id) {
  strlcat(calls, service, sizeof calls); strlcat(calls, ":", sizeof calls);
  strlcat(calls, id, sizeof calls); strlcat(calls, " ", sizeof calls);
  return 1;
}
static int fail;
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) fail = 1;
}

int main(void) {
  tccResetFn = fakeReset;
  char dir[] = "/tmp/omacvm-tcc-XXXXXX";
  if (!mkdtemp(dir)) return 1;
  char stamp[256]; snprintf(stamp, sizeof stamp, "%s/stamp", dir);
  const char *id = "org.omacvm.gestures";

  calls[0] = 0;
  check(clearOldGrants(0, id, stamp, "100-1") == 3 &&
        !strcmp(calls, "Accessibility:org.omacvm.gestures PostEvent:org.omacvm.gestures ListenEvent:org.omacvm.gestures "),
        "both missing: its Accessibility, PostEvent and ListenEvent entries cleared");
  calls[0] = 0;
  check(clearOldGrants(0, id, stamp, "100-1") == 0 && !calls[0], "the same build again: nothing (asked once per build)");
  calls[0] = 0;
  check(clearOldGrants(PERM_AX, id, stamp, "200-2") == 1 && !strcmp(calls, "ListenEvent:org.omacvm.gestures "),
        "a new build with Accessibility granted: only Input Monitoring's entry");
  calls[0] = 0;
  check(clearOldGrants(PERM_IM, id, stamp, "300-3") == 2 &&
        !strcmp(calls, "Accessibility:org.omacvm.gestures PostEvent:org.omacvm.gestures "),
        "Input Monitoring granted: only Accessibility's entries");
  calls[0] = 0;
  check(clearOldGrants(PERM_AX | PERM_IM, id, stamp, "400-4") == 0 && !calls[0], "both granted: nothing touched");
  calls[0] = 0;
  check(clearOldGrants(0, NULL, stamp, "500-5") == 0 && !calls[0], "no bundle identifier (not the app): nothing");
  unlink(stamp); rmdir(dir);
  return fail;
}
