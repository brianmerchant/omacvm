// Offline test (test.sh): each Gestures takes only its own OmacVM app's VMs.
// OmacVM.app (org.omacvm.app) and OmacVM Test.app (org.omacvm.app.test) both
// run their VMs as processes named OmacVM; the normal Gestures takes the
// first's, the test identity's Gestures (built with GESTURES_TEST_IDENTITY)
// the second's, and a VM of no known app (a development build's QEMU) stays
// every Gestures'. Made-up app bundles in a temporary folder (the plist read
// and its cache are the helper's own) and a real process outside any bundle
// (the kernel's path). The escape combo in the other identity's VM is passed
// on (its own Gestures acts on it); in its launcher it goes back into ours.
// No permissions, no VM.
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <copyfile.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;
static int fail;
static char dir[64];
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}
static void cleanup(void) {
  if (!dir[0]) return;
  char cmd[128];
  snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
  if (system(cmd)) {}
}

static void mkdirs(const char *path) {
  char p[1024];
  snprintf(p, sizeof p, "%s", path);
  for (char *s = p + 1; *s; s++)
    if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
  mkdir(p, 0755);
}

// <dir>/<name>.app/Contents/Info.plist with this bundle id and `pad` bytes of
// comment (a large plist). Only paths into it are asked about: a new
// executable in an app bundle can wait many seconds for macOS's first-run
// check before it runs.
static int writePlist(const char *name, const char *id, int pad) {
  char p[1024];
  snprintf(p, sizeof p, "%s/%s.app/Contents", dir, name);
  mkdirs(p);
  snprintf(p, sizeof p, "%s/%s.app/Contents/Info.plist", dir, name);
  FILE *f = fopen(p, "w");
  if (!f) return 0;
  fprintf(f, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>");
  if (pad > 0) {
    fprintf(f, "<!-- ");
    for (int i = 0; i < pad; i++) fputc('x', f);
    fprintf(f, " -->");
  }
  fprintf(f, "<key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n", id);
  return fclose(f) == 0;
}
static void makeApp(const char *name, const char *id) {
  char p[1024];
  snprintf(p, sizeof p, "%s/%s.app/Contents/MacOS", dir, name);
  mkdirs(p);
  if (id && !writePlist(name, id, 0)) check(0, "write a plist");
}
static void exe(char *out, size_t cap, const char *name, int launcher) {
  snprintf(out, cap, "%s/%s.app/Contents/%s", dir, name, launcher ? "MacOS/OmacVM" : "Resources/runtime/bin/OmacVM");
}
static void forgetFailures(void) { for (int i = 0; i < APP_IDS; i++) appIds[i].failedAt -= 10; }

static int fakeWindow(pid_t pid, CGWindowID win) { (void)win; return pid > 0; }
static int fakeNoMC(void) { return 0; }
static CGEventRef combo(int down) {
  CGEventRef e = CGEventCreateKeyboardEvent(NULL, ESC_KEYCODE, down);
  CGEventSetFlags(e, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
  CGEventSetIntegerValueField(e, kCGEventSourceStateID, kCGEventSourceStateHIDSystemState);
  return e;
}
// The combo pressed with this front app (as updateCapture classifies it):
// 1 = handled here (back into our full-screen VM), 0 = passed on.
static int comboHere(const char *exePath) {
  int foreign;
  int net = vmNetOf("OmacVM", exePath, &foreign);
  frontForeign = foreign;
  frontChanged(700, net, 0, "", 0, net < 0);
  int before = pendingSteps;
  CGEventRef d = combo(1), u = combo(0);
  CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL);
  tapCb(NULL, kCGEventKeyUp, u, NULL);
  int here = rd == NULL && pendingSteps == before + 1;
  CFRelease(d); CFRelease(u);
  lastComboAt = -1;   // no double press
  return here;
}

int main(void) {
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  char app[256];
  check(vmAppPath("/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM", app, sizeof app) &&
          !strcmp(app, "/Applications/OmacVM.app"), "the app of a VM's QEMU");
  check(vmAppPath("/Users/a/Applications/OmacVM Test.app/Contents/MacOS/OmacVM", app, sizeof app) &&
          !strcmp(app, "/Users/a/Applications/OmacVM Test.app"), "the app of its launcher");
  check(!vmAppPath("/Users/a/qemu/build/qemu-system-aarch64", app, sizeof app), "a development build: no app");
  check(vmOursRule("org.omacvm.app", 0) && !vmOursRule("org.omacvm.app", 1), "OmacVM.app's VM: the normal Gestures'");
  check(!vmOursRule(TEST_APP_ID, 0) && vmOursRule(TEST_APP_ID, 1), "OmacVM Test.app's VM: the test Gestures'");
  check(vmOursRule(NULL, 0) && vmOursRule(NULL, 1), "an unknown VM: every Gestures'");
  check(vmOursRule("org.example.renamed", 0) && !vmOursRule("org.example.renamed", 1),
        "another bundle id (a renamed copy): the normal Gestures'");
  check(identityTest == 0, "built without GESTURES_TEST_IDENTITY: the normal identity");

  snprintf(dir, sizeof dir, "/tmp/omacvm-gestures-identity.XXXXXX");
  if (!mkdtemp(dir)) { dir[0] = 0; printf("FAIL no temporary folder\n"); return 1; }
  atexit(cleanup);
  makeApp("OmacVM", "org.omacvm.app");
  makeApp("OmacVM Test", TEST_APP_ID);
  makeApp("Broken", NULL);   // no Info.plist: unknown
  char prodQemu[512], prodLauncher[512], testQemu[512], testLauncher[512], brokenQemu[512], p[512];
  exe(prodQemu, sizeof prodQemu, "OmacVM", 0);
  exe(prodLauncher, sizeof prodLauncher, "OmacVM", 1);
  exe(testQemu, sizeof testQemu, "OmacVM Test", 0);
  exe(testLauncher, sizeof testLauncher, "OmacVM Test", 1);
  exe(brokenQemu, sizeof brokenQemu, "Broken", 0);
  int foreign;

  identityTest = 0;   // the normal Gestures
  check(vmNetOf("OmacVM", prodQemu, &foreign) == NET_APP && !foreign &&
        vmNetOf("OmacVM", prodLauncher, &foreign) == NET_APP && !foreign,
        "normal Gestures: OmacVM.app's VM and launcher are its own");
  check(vmNetOf("OmacVM", testQemu, &foreign) < 0 && foreign, "normal Gestures: OmacVM Test.app's VM is the other one's");
  check(vmNetOf("OmacVM", testLauncher, &foreign) < 0 && !foreign,
        "normal Gestures: OmacVM Test.app's launcher is just another app");
  check(vmNetOf("OmacVM", brokenQemu, &foreign) == NET_APP, "normal Gestures: a VM of an unreadable app stays its own");
  identityTest = 1;   // the test identity's Gestures
  check(vmNetOf("OmacVM", testQemu, &foreign) == NET_APP && vmNetOf("OmacVM", testLauncher, &foreign) == NET_APP,
        "test Gestures: OmacVM Test.app's VM and launcher are its own");
  check(vmNetOf("OmacVM", prodQemu, &foreign) < 0 && foreign, "test Gestures: OmacVM.app's VM is the other one's");
  check(vmNetOf("OmacVM", brokenQemu, &foreign) == NET_APP, "test Gestures: a VM of an unreadable app stays its own");
  check(vmNetOf("OmacVM", "", &foreign) == NET_APP && vmNetOf("UTM", prodQemu, &foreign) == NET_UTM &&
        vmNetOf("prl_client_app", "", &foreign) == 0 && vmNetOf("Safari", "", &foreign) < 0,
        "no path: as before; Parallels, UTM and other apps as before");

  // The plist cache: a failed read is kept a few seconds, then read again;
  // an app replaced at the same path is read again; a large plist is read whole.
  identityTest = 0;
  makeApp("Late", NULL);
  exe(p, sizeof p, "Late", 0);
  check(ourExe(p), "an app without Info.plist yet: unknown, its own");
  writePlist("Late", TEST_APP_ID, 0);
  check(ourExe(p), "... its plist written now: the failed read is kept for a few seconds");
  forgetFailures();
  check(!ourExe(p), "... then read again: the test app's, not the normal Gestures'");
  sleep(1);   // a new change time
  writePlist("Late", "org.omacvm.app", 0);
  check(ourExe(p), "the app replaced at the same path (another bundle id): read again");
  makeApp("Big", NULL);
  writePlist("Big", TEST_APP_ID, 200000);
  exe(p, sizeof p, "Big", 0);
  check(!ourExe(p), "a 200 KB plist is read whole");

  // A real process (the kernel's path): a development build's QEMU, outside
  // any bundle, is every Gestures' (a copy of sleep stands in for it).
  snprintf(p, sizeof p, "%s/qemu-system-aarch64", dir);
  copyfile("/bin/sleep", p, NULL, COPYFILE_ALL);
  pid_t devQemu = 0;
  char *argv[] = {p, "30", NULL};
  posix_spawn(&devQemu, p, NULL, NULL, argv, environ);
  for (int i = 0; i < 100; i++) { char e[PROC_PIDPATHINFO_MAXSIZE]; if (proc_pidpath(devQemu, e, sizeof e) > 0) break; usleep(20000); }
  identityTest = 0;
  check(isQemu(devQemu) && vmNet(devQemu, "OmacVM", &foreign) == NET_APP, "normal Gestures: a development build's QEMU is its own");
  identityTest = 1;
  check(isQemu(devQemu) && vmNet(devQemu, "OmacVM", &foreign) == NET_APP, "test Gestures: a development build's QEMU is its own");
  if (devQemu > 0) { kill(devQemu, SIGKILL); waitpid(devQemu, NULL, 0); }

  // The escape combo with one of ours full screen on another Space, through
  // the same classification as the capture check.
  identityTest = 0;
  vmWindowFn = fakeWindow; missionControlOpenFn = fakeNoMC;
  frontChanged(getppid(), NET_APP, 1, "Omarchy", 0, 0);   // ours in front, full screen (a live pid)
  check(!comboHere(testQemu), "the combo in the other identity's VM: passed on, not back into ours");
  check(comboHere(testLauncher), "... in the other identity's launcher (no VM): back into ours");
  check(comboHere("/Applications/Safari.app/Contents/MacOS/Safari"), "... in any other app: back into ours, as before");
  return fail;
}
