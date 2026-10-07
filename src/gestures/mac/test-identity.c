// Offline test (test.sh): each Gestures takes only its own OmacVM app's VMs.
// OmacVM.app (org.omacvm.app) and OmacVM Test.app (org.omacvm.app.test) both
// run their VMs as processes named OmacVM; the normal Gestures takes the
// first's, the test identity's Gestures (org.omacvm.test.gestures) the
// second's, and a VM of no known app (a development build's QEMU) stays
// every Gestures'. Made-up app bundles in a temporary folder (the bundle read
// is the helper's own) and a real process outside any bundle (the kernel's
// path). The escape combo pressed in the other identity's VM is
// passed on (its own Gestures acts on it). No permissions, no VM.
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <copyfile.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern char **environ;
static int fail;
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

static void mkdirs(const char *path) {
  char p[1024];
  snprintf(p, sizeof p, "%s", path);
  for (char *s = p + 1; *s; s++)
    if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
  mkdir(p, 0755);
}

// <dir>/<name>.app with this bundle id (NULL: no Info.plist). Only paths
// into it are asked about: a new executable in an app bundle can wait many
// seconds for macOS's first-run check before it runs.
static void makeApp(const char *dir, const char *name, const char *id) {
  char p[1024];
  snprintf(p, sizeof p, "%s/%s.app/Contents/MacOS", dir, name); mkdirs(p);
  snprintf(p, sizeof p, "%s/%s.app/Contents/Resources/runtime/bin", dir, name); mkdirs(p);
  if (id) {
    snprintf(p, sizeof p, "%s/%s.app/Contents/Info.plist", dir, name);
    FILE *f = fopen(p, "w");
    fprintf(f, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
               "<key>CFBundleIdentifier</key><string>%s</string>"
               "<key>CFBundleExecutable</key><string>OmacVM</string></dict></plist>\n", id);
    fclose(f);
  }
}

static pid_t run(const char *path) {
  pid_t pid = 0;
  char *argv[] = {(char *)path, "30", NULL};
  if (posix_spawn(&pid, path, NULL, NULL, argv, environ)) return 0;
  return pid;
}

static void stop(pid_t pid) { if (pid > 0) { kill(pid, SIGKILL); waitpid(pid, NULL, 0); } }

static int fakeWindow(pid_t pid, CGWindowID win) { (void)win; return pid > 0; }
static int fakeNoMC(void) { return 0; }

static CGEventRef combo(int down) {
  CGEventRef e = CGEventCreateKeyboardEvent(NULL, ESC_KEYCODE, down);
  CGEventSetFlags(e, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
  CGEventSetIntegerValueField(e, kCGEventSourceStateID, kCGEventSourceStateHIDSystemState);
  return e;
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
  identityTest = -1;
  check(testIdentity() == 0, "this test (no bundle) is the normal identity");

  char tmpl[] = "/tmp/omacvm-gestures-identity.XXXXXX";
  char *dir = mkdtemp(tmpl);
  if (!dir) { printf("FAIL no temporary folder\n"); return 1; }
  makeApp(dir, "OmacVM", "org.omacvm.app");
  makeApp(dir, "OmacVM Test", TEST_APP_ID);
  makeApp(dir, "Broken", NULL);   // no Info.plist: unknown
  char prodQemu[1024], prodLauncher[1024], testQemu[1024], testLauncher[1024], brokenQemu[1024], p[1024];
  snprintf(prodQemu, sizeof prodQemu, "%s/OmacVM.app/Contents/Resources/runtime/bin/OmacVM", dir);
  snprintf(prodLauncher, sizeof prodLauncher, "%s/OmacVM.app/Contents/MacOS/OmacVM", dir);
  snprintf(testQemu, sizeof testQemu, "%s/OmacVM Test.app/Contents/Resources/runtime/bin/OmacVM", dir);
  snprintf(testLauncher, sizeof testLauncher, "%s/OmacVM Test.app/Contents/MacOS/OmacVM", dir);
  snprintf(brokenQemu, sizeof brokenQemu, "%s/Broken.app/Contents/Resources/runtime/bin/OmacVM", dir);

  identityTest = 0;   // the normal Gestures
  check(ourExe(prodQemu) && ourExe(prodLauncher), "normal Gestures: OmacVM.app's VM and launcher are its own");
  check(!ourExe(testQemu) && !ourExe(testLauncher), "normal Gestures: OmacVM Test.app's are not");
  check(ourExe(brokenQemu), "normal Gestures: a VM of an unreadable app stays its own");
  identityTest = 1;   // the test identity's Gestures
  check(ourExe(testQemu) && ourExe(testLauncher), "test Gestures: OmacVM Test.app's VM and launcher are its own");
  check(!ourExe(prodQemu) && !ourExe(prodLauncher), "test Gestures: OmacVM.app's are not");
  check(ourExe(brokenQemu), "test Gestures: a VM of an unreadable app stays its own");

  // The bundle id is read again after a failed read (an app being swapped).
  identityTest = 0;
  makeApp(dir, "Late", NULL);
  snprintf(p, sizeof p, "%s/Late.app/Contents/Resources/runtime/bin/OmacVM", dir);
  check(ourExe(p), "an app without Info.plist yet: unknown, its own");
  char plist[1024];
  snprintf(plist, sizeof plist, "%s/Late.app/Contents/Info.plist", dir);
  FILE *f = fopen(plist, "w");
  fprintf(f, "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key>"
             "<string>" TEST_APP_ID "</string></dict></plist>\n");
  fclose(f);
  check(!ourExe(p), "... once it has one (the test app's), read again: not the normal Gestures'");

  // A real process (the kernel's path): a development build's QEMU, outside
  // any bundle, is every Gestures' (a copy of sleep stands in for it).
  snprintf(p, sizeof p, "%s/qemu-system-aarch64", dir);
  copyfile("/bin/sleep", p, NULL, COPYFILE_ALL);
  pid_t devQemu = run(p);
  for (int i = 0; i < 100; i++) { char e[PROC_PIDPATHINFO_MAXSIZE]; if (proc_pidpath(devQemu, e, sizeof e) > 0) break; usleep(20000); }
  identityTest = 0;
  check(isQemu(devQemu) && vmNet(devQemu, "OmacVM") == NET_APP, "normal Gestures: a development build's QEMU is its own");
  identityTest = 1;
  check(isQemu(devQemu) && vmNet(devQemu, "OmacVM") == NET_APP, "test Gestures: a development build's QEMU is its own");
  check(vmNet(devQemu, "UTM") == NET_UTM && vmNet(devQemu, "prl_client_app") == 0 && vmNet(devQemu, "Safari") < 0,
        "Parallels, UTM and other apps as before");
  stop(devQemu);

  // The escape combo in the other identity's full-screen VM, with one of ours
  // full screen on another Space: passed on, nothing done here.
  identityTest = 0;
  vmWindowFn = fakeWindow; missionControlOpenFn = fakeNoMC;
  frontChanged(getppid(), NET_APP, 1, "Omarchy", 0, 0);   // ours in front, full screen (a live pid)
  frontChanged(700, -1, 0, "", 0, 1);               // the test app's VM: any other app
  frontForeign = 1;
  CGEventRef d = combo(1), u = combo(0);
  CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL), ru = tapCb(NULL, kCGEventKeyUp, u, NULL);
  check(rd == d && ru == u && pendingSteps == 0 && !capturing,
        "the combo in the other identity's VM: passed on, not back into ours");
  frontForeign = 0;
  CGEventRef d2 = combo(1), u2 = combo(0);
  CGEventRef rd2 = tapCb(NULL, kCGEventKeyDown, d2, NULL);
  tapCb(NULL, kCGEventKeyUp, u2, NULL);
  check(rd2 == NULL && pendingSteps == 1, "... in any other app: back into ours, as before");
  CFRelease(d); CFRelease(u); CFRelease(d2); CFRelease(u2);

  char cmd[1100];
  snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
  if (system(cmd)) {}
  return fail;
}
