// Offline test of the escape combo (test.sh): Ctrl+Option+Cmd+Esc in the VM
// swipes the display under the pointer to the Space beside the VM's, in macOS
// back into the VM; when a swipe cannot be made or does not land, the app
// switch, then hiding the VM's app (never a trap). Drives the helper's own
// tapCb with made-up key events and its capture logic (frontChanged) with
// made-up front apps, against a made-up world of displays and Spaces: the
// window server is not asked, nothing is swiped or activated. No permissions,
// no VM.
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <fcntl.h>
#include <sys/wait.h>

static int fail, peer;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

// ---- the made-up world ----
typedef struct { CGDirectDisplayID id; CGRect b; uint64_t sp[8]; int n; uint64_t cur; } World;
static World world[2];
static int nWorld;
#define MAX_SPACE_ID 512
static pid_t owner[MAX_SPACE_ID];        // the app that is in front when this Space shows
static CGWindowID winOn[MAX_SPACE_ID];   // its window there
static pid_t front, finder;
static CGPoint pointer;
static int worldSign = 1;     // 1: the Dock swipes as the helper thinks; -1: the other way
static int swipesIgnored;     // the Dock does nothing with the swipe
static int refuse, hidden, all, saved, vmAlive = 1;
static int swipes, went;
static CGDirectDisplayID swipedOn[4];
static pid_t wentTo; static CGWindowID wentWin;

static World *worldOf(CGDirectDisplayID id) {
  for (int i = 0; i < nWorld; i++) if (world[i].id == id) return &world[i];
  return NULL;
}
static int idx(World *w, uint64_t s) { for (int i = 0; i < w->n; i++) if (w->sp[i] == s) return i; return -1; }

static int fakeSpaces(DisplaySpaces *out, int cap) {
  int k = 0;
  for (int i = 0; i < nWorld && k < cap; i++, k++) {
    memset(&out[k], 0, sizeof out[k]);
    out[k].id = world[i].id; out[k].bounds = world[i].b; out[k].current = world[i].cur; out[k].n = world[i].n;
    memcpy(out[k].spaces, world[i].sp, sizeof world[i].sp);
  }
  return k;
}
static uint64_t fakeWindowSpace(CGWindowID win) {
  for (int s = 0; s < MAX_SPACE_ID; s++) if (win && winOn[s] == win) return (uint64_t)s;
  return 0;
}
// The Dock: one Space over on that display; a full-screen Space brings its app.
// The Dock swipes the display the pointer is on, whatever the events say.
static World *underPointer(void) {
  for (int i = 0; i < nWorld; i++) if (CGRectContainsPoint(world[i].b, pointer)) return &world[i];
  return NULL;
}
static int warps;
static void fakeWarp(CGPoint p) { pointer = p; warps++; }
static int fakeSwipe(CGDirectDisplayID d, CGRect b, int dir) {
  (void)b; (void)d;
  World *w = underPointer();
  if (swipes < 4) swipedOn[swipes] = w ? w->id : 0;
  swipes++;
  if (!w || swipesIgnored) return 1;
  int i = idx(w, w->cur), j = i + dir * swipeSign * worldSign;
  if (i < 0 || j < 0 || j >= w->n) return 1;   // the edge: macOS bounces
  w->cur = w->sp[j];
  if (owner[w->cur] && owner[w->cur] != finder) front = owner[w->cur];
  return 1;
}
static CGPoint fakePointer(void) { return pointer; }
// The VM's on-screen windows: full screen on each display that shows its Space.
static int fakeVMWindows(pid_t pid, CGRect *out, int cap) {
  int k = 0;
  for (int i = 0; i < nWorld && k < cap; i++) if (owner[world[i].cur] == pid) out[k++] = world[i].b;
  return k;
}
static pid_t fakeTopApp(CGRect b, pid_t skip, CGWindowID *win) {
  for (int i = 0; i < nWorld; i++)
    if (CGRectEqualToRect(world[i].b, b) && owner[world[i].cur] != skip) {
      *win = winOn[world[i].cur];
      return owner[world[i].cur];
    }
  return 0;
}
// Activation: the app comes to the front, its window's Space shows.
static int fakeActivate(pid_t pid, CGWindowID win) {
  wentTo = pid; wentWin = win; went++;
  if (refuse) return 0;
  front = pid;
  uint64_t s = fakeWindowSpace(win);
  for (int i = 0; s && i < nWorld; i++) if (idx(&world[i], s) >= 0) world[i].cur = s;
  return 1;
}
static int fakeHide(pid_t pid) { hidden++; if (front == pid) front = finder; return 1; }
static pid_t fakeFront(void) { return front; }
static pid_t fakeFinder(void) { return finder; }
static int fakeAll(void) { return all; }
static void fakeSave(void) { saved++; }
static int fakeVMWindow(pid_t pid, CGWindowID win) { (void)win; return vmAlive && alive(pid); }
static pid_t launcher;   // OmacVM.app's launcher: the VMs' process name, but no QEMU
static int fakeIsQemu(pid_t pid) { return pid != launcher; }
// Out of full screen: each display showing the VM's Space goes to its first
// one. Into it: the first display shows the VM's Space again.
static int unfs, refs;
static int fakeFullScreen(pid_t pid, int on) {
  if (!on) {
    unfs++;
    for (int i = 0; i < nWorld; i++) if (owner[world[i].cur] == pid) world[i].cur = world[i].sp[0];
    return 1;
  }
  refs++;
  for (int i = 0; i < nWorld; i++)
    for (int j = 0; j < world[i].n; j++) if (owner[world[i].sp[j]] == pid) { world[i].cur = world[i].sp[j]; return 1; }
  return 0;
}

// What the guest got since the last call, lines joined by '|'.
static const char *sent(void) {
  static char out[256];
  out[0] = 0; usleep(2000);
  ssize_t n = read(peer, out, sizeof out - 1);
  out[n > 0 ? n : 0] = 0;
  for (char *c = out; *c; c++) if (*c == '\n') *c = '|';
  return out;
}

static CGEventRef key(int down, CGEventFlags f, int64_t state, int repeat) {
  CGEventRef e = CGEventCreateKeyboardEvent(NULL, ESC_KEYCODE, down);
  CGEventSetFlags(e, f);
  CGEventSetIntegerValueField(e, kCGEventSourceStateID, state);
  if (repeat) CGEventSetIntegerValueField(e, kCGKeyboardEventAutorepeat, 1);
  return e;
}

// Runs the main queue until the combo's steps are all done (a slow CI
// machine takes longer than this Mac), at most 5 s.
static void settleSteps(void) {
  for (int i = 0; i < 250 && (i < 2 || pendingSteps > 0); i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
}

// Press and release; 1 if both were eaten, 0 if both passed, -1 mixed. Runs
// the main queue so the swipe, its check and the fallbacks happen.
static int press(CGEventFlags f, int64_t state, int repeat) {
  went = swipes = hidden = 0;
  CGEventRef d = key(1, f, state, repeat), u = key(0, f, state, 0);
  CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL), ru = tapCb(NULL, kCGEventKeyUp, u, NULL);
  CFRelease(d); CFRelease(u);
  settleSteps();
  return !rd && !ru ? 1 : rd && ru ? 0 : -1;
}

// What the capture check would find now (front app, its full-screen window).
static void settle(pid_t vm, int net) {
  if (front == vm) frontChanged(vm, net, 1, "Omarchy", vmWin, 0);
  else frontChanged(front, -1, 0, "", front == finder ? 0 : 11, 1);
}

static pid_t child(void) { pid_t p = fork(); if (p == 0) { pause(); _exit(0); } return p; }
static void end(pid_t p) { kill(p, SIGKILL); waitpid(p, NULL, 0); }

static void layout(int displays, const uint64_t *a, int na, const uint64_t *b, int nb) {
  nWorld = displays;
  memset(world, 0, sizeof world);
  world[0].id = 1; world[0].b = CGRectMake(0, 0, 2560, 1440);
  memcpy(world[0].sp, a, sizeof *a * (size_t)na); world[0].n = na;
  if (displays > 1) {
    world[1].id = 2; world[1].b = CGRectMake(2560, 0, 1920, 1200);
    memcpy(world[1].sp, b, sizeof *b * (size_t)nb); world[1].n = nb;
  }
  memset(left, 0, sizeof left);
}

int main(void) {
  activateFn = fakeActivate; finderFn = fakeFinder; frontFn = fakeFront; vmWindowFn = fakeVMWindow;
  spacesFn = fakeSpaces; windowSpaceFn = fakeWindowSpace; swipeFn = fakeSwipe; pointerFn = fakePointer;
  vmWindowsFn = fakeVMWindows; topAppFn = fakeTopApp; hideFn = fakeHide; escapeAllFn = fakeAll; saveSignFn = fakeSave;
  warpFn = fakeWarp; warpSettle = 0; isQemuFn = fakeIsQemu; fullScreenFn = fakeFullScreen;
  verifyAfter = 0.01; restoreGrace = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  int sv[2]; socketpair(AF_UNIX, SOCK_STREAM, 0, sv); peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1;
  snprintf(clients[0].name, sizeof clients[0].name, "Omarchy");
  snprintf(clients[0].ip, sizeof clients[0].ip, "127.0.0.1");
  const CGEventFlags C = kCGEventFlagMaskControl, O = kCGEventFlagMaskAlternate, M = kCGEventFlagMaskCommand;
  const int64_t HID = kCGEventSourceStateHIDSystemState, POSTED = kCGEventSourceStateCombinedSessionState;
  pid_t terminal = child(), vm = child(), parallels = child(), safari = child();
  finder = child();

  // ---- A Mac mini with one display: Desktop 1 (Terminal), the VM's full-screen Space ----
  const uint64_t mini[] = { 101, 102 };
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
  pointer = CGPointMake(1000, 700);
  front = terminal; world[0].cur = 101;
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(C|O|M, HID, 0) == 0 && !went && !swipes, "in macOS before any VM: the combo passes, nothing happens");
  front = vm; world[0].cur = 102;
  frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);
  check(!strcmp(sent(), "S on|"), "VM full screen in front: captured");

  check(press(C|O|M, HID, 0) == 1, "mini: combo in the VM: eaten (down and up)");
  check(!strcmp(sent(), "S esc|") && !capturing, "... Omarchy lets go (S esc), capture off at once");
  check(swipes == 1 && swipedOn[0] == 1 && world[0].cur == 101, "... the display swipes to Desktop 1");
  check(front == terminal && !went && !hidden, "... the keyboard is Terminal's (no app switch needed)");
  settle(vm, NET_APP);
  check(!escaped && !strcmp(sent(), ""), "on Desktop 1: nothing more sent, capture re-arms");

  check(press(C|O|M, HID, 0) == 1, "mini: combo in macOS: eaten");
  check(swipes == 1 && world[0].cur == 102 && front == vm && !went, "... the display swipes back to the VM, which has the keyboard");
  settle(vm, NET_APP);
  check(capturing && !strcmp(sent(), "S on|"), "... and it is captured again");

  // Only two Spaces and the swipe's sign the wrong way round (the mini's usual
  // layout): the swipe bounces at the edge, nothing to learn from. The other
  // direction is tried once, lands and is kept: no app switch.
  worldSign = -1; saved = 0;
  check(press(C|O|M, HID, 0) == 1 && swipes == 2 && world[0].cur == 101 && !went && saved == 1 && swipeSign == -1,
        "mini, sign the wrong way: the bounce is retried the other way, lands, is kept");
  sent(); settle(vm, NET_APP);
  check(press(C|O|M, HID, 0) == 1 && swipes == 1 && world[0].cur == 102 && front == vm && !went,
        "... back into the VM with one swipe");
  settle(vm, NET_APP); sent();
  check(press(C|O|M, HID, 0) == 1 && swipes == 1 && world[0].cur == 101 && !went, "... and out with one swipe from now on");
  sent(); settle(vm, NET_APP);
  front = vm; world[0].cur = 102; settle(vm, NET_APP); sent();
  worldSign = 1; swipeSign = 1; saved = 0;

  // The swipe does nothing (macOS ignores it): one try the other way, then the app switch of RC8.
  swipesIgnored = 1;
  check(press(C|O|M, HID, 0) == 1 && swipes == 2 && went == 1 && wentTo == terminal && wentWin == 11,
        "swipe ignored (both ways): the app from before comes to the front instead");
  check(swipeSign == 1 && saved == 0, "... and the direction stays as it was");
  check(front == terminal && world[0].cur == 101 && !hidden, "... with its Space");
  sent(); settle(vm, NET_APP);
  check(press(C|O|M, HID, 0) == 1 && went >= 1 && wentTo == vm && front == vm && world[0].cur == 102,
        "... and back: switched to the VM instead of the swipe");
  settle(vm, NET_APP); sent();

  // Neither the swipe nor the switch: the VM's app is hidden, macOS has the keyboard.
  refuse = 1;
  unfs = 0;
  check(press(C|O|M, HID, 0) == 1 && !capturing && hidden >= 1 && front != vm,
        "swipe ignored and the switch refused: the VM is hidden (never a trap)");
  check(unfs == 1 && world[0].cur == 101, "... its full screen still showed: out of full screen too");
  refuse = 0; swipesIgnored = 0; refs = 0;
  sent(); settle(vm, NET_APP);
  check(restoreFull && press(C|O|M, HID, 0) == 1 && wentTo == vm && front == vm && refs == 1 && world[0].cur == 102 && !swipes,
        "... the combo in macOS: the VM back, full screen again (no swipe)");
  check(!restoreFull, "... once");
  settle(vm, NET_APP); sent();

  // The swipe went the other way (the event's sign): learned and kept, the switch fixes this time.
  const uint64_t three[] = { 101, 102, 103 };
  layout(1, three, 3, NULL, 0);
  owner[103] = safari; winOn[103] = 33;
  world[0].cur = 101; front = terminal; settle(vm, NET_APP);   // Terminal was in front before the VM
  world[0].cur = 102; front = vm; settle(vm, NET_APP); sent();
  worldSign = -1; saved = 0;
  check(press(C|O|M, HID, 0) == 1 && saved == 1 && swipeSign == -1, "a swipe that went the other way teaches the direction (kept)");
  check(went >= 1 && wentTo == terminal && world[0].cur == 101, "... and the app switch takes over this time");
  sent(); settle(vm, NET_APP); front = vm; world[0].cur = 102; settle(vm, NET_APP); sent();
  check(press(C|O|M, HID, 0) == 1 && world[0].cur == 101 && !went && saved == 1, "... the next combo swipes the right way");
  sent(); settle(vm, NET_APP);
  worldSign = 1; swipeSign = 1;

  // No Spaces information (an older or newer macOS without the call): the app switch.
  nWorld = 0; front = vm; settle(vm, NET_APP); sent();
  check(press(C|O|M, HID, 0) == 1 && !swipes && went >= 1 && wentTo == terminal, "no Spaces information: the app switch (RC8)");
  sent(); settle(vm, NET_APP);

  // ---- A MacBook and an external display, the VM full screen on both ----
  const uint64_t inner[] = { 201, 202 }, outer[] = { 301, 302 };
  layout(2, inner, 2, outer, 2);
  owner[201] = terminal; winOn[201] = 11; owner[202] = vm; winOn[202] = 22;
  owner[301] = safari; winOn[301] = 44; owner[302] = vm; winOn[302] = 23;
  world[0].cur = 202; world[1].cur = 302; front = vm;
  pointer = CGPointMake(3000, 600);   // on the external display
  settle(vm, NET_APP); sent();
  // The Dock leaves the VM in front here (its other window): the keyboard must follow the pointer.
  owner[301] = finder;   // the external's desktop shows no app: Finder
  check(press(C|O|M, HID, 0) == 1 && swipes == 1 && swipedOn[0] == 2, "two displays: only the display under the pointer swipes");
  check(world[1].cur == 301 && world[0].cur == 202, "... the external shows its desktop, the MacBook still the VM");
  check(went == 1 && wentTo == finder && front == finder, "... the keyboard follows the pointer (Finder, the desktop there)");
  settle(vm, NET_APP);
  check(press(C|O|M, HID, 0) == 1 && swipes == 1 && swipedOn[0] == 2 && world[1].cur == 302, "... the combo there swipes it back");
  check(front == vm, "... and the VM has the keyboard");
  settle(vm, NET_APP); sent();
  owner[301] = safari;

  // The pointer on a display without the VM: nothing swipes, the keyboard goes there.
  world[1].cur = 301;
  check(press(C|O|M, HID, 0) == 1 && !swipes && went == 1 && wentTo == safari && wentWin == 44 && world[0].cur == 202,
        "pointer on a display without the VM: no swipe, the keyboard goes to what it shows");
  sent(); settle(vm, NET_APP);
  world[1].cur = 302; front = vm; settle(vm, NET_APP); sent();

  // "Swipe all monitors": the Dock swipes the pointer's display only, so the
  // pointer visits the other display for its swipe and comes back.
  all = 1; warps = 0;
  CGPoint before = pointer;
  check(press(C|O|M, HID, 0) == 1 && swipes == 2 && world[0].cur == 201 && world[1].cur == 301, "all: both displays swipe out of the VM");
  check(swipedOn[0] != swipedOn[1] && warps == 2 && pointer.x == before.x && pointer.y == before.y,
        "all: ... one swipe on each display (the pointer went there and back)");
  sent(); settle(vm, NET_APP);
  check(press(C|O|M, HID, 0) == 1 && swipes == 2 && world[0].cur == 202 && world[1].cur == 302 && front == vm,
        "all: ... and both back into it");
  settle(vm, NET_APP); sent();
  all = 0;

  // "Displays have separate Spaces" off: one list of Spaces for both displays.
  const uint64_t shared[] = { 401, 402 };
  layout(2, shared, 2, shared, 2);
  owner[401] = terminal; winOn[401] = 11; owner[402] = vm; winOn[402] = 22;
  world[0].cur = world[1].cur = 402; front = vm; all = 1;
  settle(vm, NET_APP); sent();
  check(press(C|O|M, HID, 0) == 1 && swipes == 1, "Spaces shared by the displays, all: one swipe, not two");
  sent(); settle(vm, NET_APP);
  all = 0;

  // ---- Not the real keyboard, a held key, other combos: as before ----
  front = finder; world[0].cur = 201; world[1].cur = 301;
  frontChanged(finder, -1, 0, "", 0, 1); sent();
  check(press(C|O|M, POSTED, 0) == 0 && !went && !swipes, "combo posted by an app in macOS: passes, nothing happens");
  check(press(C|O|M, HID, 1) == -1 && !went && !swipes, "a held combo (autorepeat): its repeats eaten, nothing happens");
  check(press(O|M, HID, 0) == 0 && !went, "Option+Cmd+Esc (Force Quit) passes");
  check(press(C|M, HID, 0) == 0 && !went, "Ctrl+Cmd+Esc passes");

  // ---- Parallels: the same way out and back ----
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = parallels; winOn[102] = 55;
  pointer = CGPointMake(1000, 700); world[0].cur = 102; front = parallels;
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();
  check(press(C|O|M, HID, 0) == 1 && swipes == 1 && world[0].cur == 101 && front == terminal, "Parallels VM: swiped out");
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(C|O|M, HID, 0) == 1 && swipes == 1 && world[0].cur == 102 && front == parallels, "... and into the Parallels VM again");
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();

  // The same VM app in front in a window (it left full screen): the combo is the VM's, as before.
  frontChanged(parallels, 0, 0, "", 0, 0);
  check(press(C|O|M, HID, 0) == 0 && !went && !swipes, "the VM's app in front in a window: the combo passes to it");

  // Parallels outlives its VM: its window gone, the combo in macOS is macOS's again.
  front = terminal; world[0].cur = 101;
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); frontChanged(terminal, -1, 0, "", 11, 1); sent();
  vmAlive = 0;
  check(press(C|O|M, HID, 0) == 0 && !went && !swipes, "the VM's window is gone (app still running): the combo passes");
  vmAlive = 1;

  // The VM has quit: the combo in macOS is macOS's again.
  end(parallels);
  check(press(C|O|M, HID, 0) == 0 && !went && !swipes, "the last VM has quit: the combo passes in macOS");

  // ---- Never stuck (Mac mini, 12:58): the swipe did nothing and Finder took
  // the front without a window, so the VM's full-screen Space still showed ----
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
  pointer = CGPointMake(1000, 700); front = vm; world[0].cur = 102;
  frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
  end(terminal); terminal = child(); owner[101] = terminal;   // the app from before has quit: Finder is next
  swipesIgnored = 1; unfs = 0;
  check(press(C|O|M, HID, 0) == 1 && swipes == 2 && wentTo == finder, "mini, nothing swipes: back to Finder (no window)");
  settleSteps();
  check(unfs == 1 && hidden == 1 && world[0].cur == 101 && front != vm,
        "... the VM's Space still showed: out of full screen and hidden, the user is out");
  swipesIgnored = 0;
  frontChanged(finder, -1, 0, "", 0, 1);
  // Brought back another way (the Dock: a window now): the next combo in macOS is no restore.
  restoreGrace = 1.5;
  front = vm; frontChanged(vm, NET_APP, 0, "", 22, 0);
  check(restoreFull, "... the VM in front in a window while it is hidden (within 1.5 s): still to be restored");
  restoreGrace = 0;
  frontChanged(vm, NET_APP, 0, "", 22, 0);
  check(!restoreFull, "... the VM in front again later (the Dock, a click): no full screen forced on it");
  front = vm; world[0].cur = 102; frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
  unfs = 0;
  check(press(C|O|M, HID, 0) == 1 && world[0].cur == 101, "a swipe that lands: out");
  settleSteps();
  check(!unfs && !hidden, "... and nothing more (no un-full-screen, no hiding)");
  sent(); settle(vm, NET_APP);
  front = vm; world[0].cur = 102; settle(vm, NET_APP); sent();
  frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; world[0].cur = 101;

  // ---- An OmacVM VM in a window with the keyboard: the combo gives it to
  // the app from before; in macOS it brings that window back ----
  pid_t winvm = child();
  front = winvm;
  frontChanged(winvm, NET_APP, 0, "", 77, 0); sent();
  check(press(C|O|M, HID, 0) == 1 && went == 1 && wentTo == terminal && wentWin == 11 && front == terminal && !swipes,
        "VM in a window: the combo gives the keyboard to the app from before (Terminal), no swipe");
  check(!capturing && !strcmp(sent(), ""), "... nothing sent to the guest");
  check(leftWinPid == winvm && leftWinWin == 77, "... and that window is remembered");
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(C|O|M, HID, 0) == 1 && went == 1 && wentTo == winvm && wentWin == 77 && front == winvm,
        "in macOS: the combo brings the VM window back, with the keyboard");
  frontChanged(winvm, NET_APP, 0, "", 77, 0);
  check(!leftWinPid, "... in it again: forgotten");
  check(press(C|O|M, HID, 1) == -1 && !went && !leftWinPid && front == winvm, "VM in a window: a held combo (autorepeat): its repeats eaten, nothing happens");
  check(press(C|O|M, POSTED, 0) == 0 && !leftWinPid && front == winvm, "VM in a window: a posted combo passes, not remembered");
  // The switch refused: the VM's app is hidden, macOS has the keyboard.
  refuse = 1;
  check(press(C|O|M, HID, 0) == 1 && hidden == 1 && front != winvm, "VM in a window, the switch refused: hidden (never a trap)");
  refuse = 0;
  frontChanged(front, -1, 0, "", 0, 1);
  check(press(C|O|M, HID, 0) == 1 && wentTo == winvm && front == winvm, "... the combo brings it back");
  frontChanged(winvm, NET_APP, 0, "", 77, 0);
  // Left with a click (no combo): the combo in macOS is not the window's.
  front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
  wentTo = 0;
  check(press(C|O|M, HID, 0) >= 0 && wentTo != winvm && !leftWinPid, "a VM window left with a click: the combo does not take it back");
  sent(); front = terminal; world[0].cur = 101; frontChanged(terminal, -1, 0, "", 11, 1);
  // The window left by the combo, then a full-screen VM entered: that one is the newer.
  front = winvm; frontChanged(winvm, NET_APP, 0, "", 77, 0);
  press(C|O|M, HID, 0);
  check(leftWinPid == winvm, "window left by the combo");
  front = vm; world[0].cur = 102; frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
  check(!leftWinPid, "... then a full-screen VM in front: the window is no longer the way back");
  frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; world[0].cur = 101; sent(); escaped = 0;
  // The launcher (OmacVM.app's start window) has the VMs' name, but is no VM.
  launcher = child(); front = launcher;
  frontChanged(launcher, NET_APP, 0, "", 88, 0);
  check(!winVMPid, "OmacVM.app's launcher in front: no VM window");
  front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
  // The window gone (VM quit): the combo in macOS is not the window's.
  front = winvm; frontChanged(winvm, NET_APP, 0, "", 77, 0); press(C|O|M, HID, 0);
  front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
  end(winvm);
  check(press(C|O|M, HID, 0) == 0 || wentTo != winvm, "the VM window's VM has quit: the combo does not go there");
  end(launcher); launcher = 0;

  // Which apps the combo goes back to.
  check(isOther(terminal, -1, "Terminal", 1), "back to: a regular app");
  check(!isOther(terminal, -1, "Raycast", 0), "... not an accessory app (Raycast, Alfred, Spotlight, a quick panel)");
  check(!isOther(terminal, -1, "loginwindow", 1) && !isOther(vm, NET_APP, "OmacVM", 1), "... not the lock screen, not a VM app");

  // The swipe plan on its own.
  DisplaySpaces d = { .n = 3, .spaces = { 1, 2, 3 }, .current = 2 };
  check(stepOut(&d) == -1, "plan: out of a Space in the middle: to the left");
  d.current = 1;
  check(stepOut(&d) == 1, "plan: out of the first Space: to the right");
  d.n = 1;
  check(stepOut(&d) == 0, "plan: a single Space: no swipe");
  d.n = 3; d.current = 1;
  check(stepToward(&d, 2) == 1 && stepToward(&d, 3) == 0 && stepToward(&d, 9) == 0,
        "plan: back only to a Space right beside (else the switch)");

  end(terminal); end(vm); end(safari); end(finder);
  return fail;
}
