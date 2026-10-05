// Offline test of the escape combo (test.sh): Ctrl+Option+Cmd+Esc in the VM
// moves the display under the pointer one Space toward the one it showed
// before the VM, with macOS's own "Move left/right a space" shortcut (as the
// user set it in com.apple.symbolichotkeys); in macOS back into the VM. Each
// move is checked: not moved -> a Dock swipe -> Mission Control. The VM is
// never taken out of full screen and never hidden. Drives the helper's own
// tapCb with made-up key events and its capture logic (frontChanged) with
// made-up front apps, against a made-up world of displays and Spaces whose
// "macOS" acts on the user's binding: the window server is not asked,
// nothing is posted, swiped or activated. No permissions, no VM.
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
static int swipesIgnored;     // the Dock does nothing with a swipe (macOS 27)
static int keysIgnored;       // the Space shortcut reaches nothing (a VM app took it)
static int refuse, hidden, all, saved, vmAlive = 1;
static int swipes, went, keys, spaceKeys, mcKeys, mcApp;
static CGDirectDisplayID movedOn[4];
static pid_t wentTo; static CGWindowID wentWin;
static Hotkey lastKey;
static CFMutableDictionaryRef binding;   // the user's com.apple.symbolichotkeys (NULL: never changed)
static int heldPolls, heldAsked;         // the combo's keys still down for this many looks

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
// macOS acts on the display the pointer is on.
static World *underPointer(void) {
  for (int i = 0; i < nWorld; i++) if (CGRectContainsPoint(world[i].b, pointer)) return &world[i];
  return NULL;
}
static void moveSpace(World *w, int dir) {
  if (!w) return;
  int i = idx(w, w->cur), j = i + dir;
  if (i < 0 || j < 0 || j >= w->n) return;   // the edge: nothing
  w->cur = w->sp[j];
  // With "Displays have separate Spaces" off, every display shows it.
  for (int k = 0; k < nWorld; k++) if (&world[k] != w && idx(&world[k], w->sp[j]) >= 0 && world[k].sp[0] == w->sp[0]) world[k].cur = w->cur;
  if (owner[w->cur] && owner[w->cur] != finder) front = owner[w->cur];
}
static int warps;
static void fakeWarp(CGPoint p) { pointer = p; warps++; }
static int fakeSwipe(CGDirectDisplayID d, CGRect b, int dir) {
  (void)b; (void)d;
  World *w = underPointer();
  swipes++;
  if (!w || swipesIgnored) return 1;
  moveSpace(w, dir * swipeSign * worldSign);
  return 1;
}
static int same(Hotkey a, Hotkey b) { return a.enabled && b.enabled && a.keycode == b.keycode && a.flags == b.flags; }
// "macOS": the key is one of the user's Space shortcuts (as set now) -> that move.
static int fakeKey(Hotkey k) {
  keys++; lastKey = k;
  Hotkey l = hotkeyFrom(binding, HOTKEY_SPACE_LEFT), r = hotkeyFrom(binding, HOTKEY_SPACE_RIGHT);
  Hotkey mc = hotkeyFrom(binding, HOTKEY_MISSION_CONTROL);
  World *w = underPointer();
  if (same(k, l) || same(k, r)) {
    if (spaceKeys < 4) movedOn[spaceKeys] = w ? w->id : 0;
    spaceKeys++;
    if (!keysIgnored) moveSpace(w, same(k, l) ? -1 : 1);
  } else if (same(k, mc)) mcKeys++;
  return 1;
}
static CFDictionaryRef fakeHotkeys(void) { return binding ? CFRetain(binding) : NULL; }
static CGEventFlags fakeHeld(void) {
  heldAsked++;
  if (heldPolls > 0) { heldPolls--; return kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand; }
  return 0;
}
static int fakeMissionApp(void) { mcApp++; return 1; }
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

// The user's shortcut table: one entry.
static void setKey(int id, CFTypeRef enabled, int64_t code, int64_t mods) {
  if (!binding) binding = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int64_t ch = 65535;
  CFNumberRef p[3] = { CFNumberCreate(NULL, kCFNumberSInt64Type, &ch), CFNumberCreate(NULL, kCFNumberSInt64Type, &code),
                       CFNumberCreate(NULL, kCFNumberSInt64Type, &mods) };
  CFArrayRef params = CFArrayCreate(NULL, (const void **)p, 3, &kCFTypeArrayCallBacks);
  const void *vk[] = { CFSTR("parameters"), CFSTR("type") }, *vv[] = { params, CFSTR("standard") };
  CFDictionaryRef value = CFDictionaryCreate(NULL, vk, vv, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  const void *ek[] = { CFSTR("enabled"), CFSTR("value") }, *ev[] = { enabled, value };
  CFDictionaryRef entry = CFDictionaryCreate(NULL, ek, ev, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  char name[16]; snprintf(name, sizeof name, "%d", id);
  CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
  CFDictionarySetValue(binding, key, entry);
  CFRelease(key); CFRelease(entry); CFRelease(value); CFRelease(params);
  for (int i = 0; i < 3; i++) CFRelease(p[i]);
}
static void unsetKeys(void) { if (binding) CFRelease(binding); binding = NULL; }

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
// the main queue so the moves, their checks and the fallbacks happen.
static int press(CGEventFlags f, int64_t state, int repeat) {
  went = swipes = hidden = keys = spaceKeys = mcKeys = mcApp = 0;
  CGEventRef d = key(1, f, state, repeat), u = key(0, f, state, 0);
  CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL), ru = tapCb(NULL, kCGEventKeyUp, u, NULL);
  CFRelease(d); CFRelease(u);
  settleSteps();
  return !rd && !ru ? 1 : rd && ru ? 0 : -1;
}

// What the capture check would find now (front app, its full-screen window).
static void settle(pid_t vm, int net) {
  if (front == vm) frontChanged(vm, net, 1, "Omarchy", vmWin, 0);
  else frontChanged(front, -1, 0, "", front == finder ? 0 : winOn[world[0].cur], 1);
}

// The VM full screen in front on display 1's Space s, captured; nothing pending.
static void inVM(pid_t vm, uint64_t s) {
  front = vm; world[0].cur = s;
  frontChanged(vm, NET_APP, 1, "Omarchy", winOn[s], 0); sent();
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
  memset(cameFrom, 0, sizeof cameFrom);
}

int main(void) {
  activateFn = fakeActivate; finderFn = fakeFinder; frontFn = fakeFront; vmWindowFn = fakeVMWindow;
  spacesFn = fakeSpaces; windowSpaceFn = fakeWindowSpace; swipeFn = fakeSwipe; pointerFn = fakePointer;
  vmWindowsFn = fakeVMWindows; topAppFn = fakeTopApp; hideFn = fakeHide; escapeAllFn = fakeAll; saveSignFn = fakeSave;
  warpFn = fakeWarp; warpSettle = 0; isQemuFn = fakeIsQemu;
  hotkeysFn = fakeHotkeys; keyFn = fakeKey; heldFn = fakeHeld; missionAppFn = fakeMissionApp;
  verifyAfter = 0.01; cameFromEvery = 0;
  initKeymap();
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  int sv[2]; socketpair(AF_UNIX, SOCK_STREAM, 0, sv); peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1;
  snprintf(clients[0].name, sizeof clients[0].name, "Omarchy");
  snprintf(clients[0].ip, sizeof clients[0].ip, "127.0.0.1");
  const CGEventFlags C = kCGEventFlagMaskControl, O = kCGEventFlagMaskAlternate, M = kCGEventFlagMaskCommand;
  const CGEventFlags FN = kCGEventFlagMaskSecondaryFn, PAD = kCGEventFlagMaskNumericPad;
  const int64_t HID = kCGEventSourceStateHIDSystemState, POSTED = kCGEventSourceStateCombinedSessionState;
  pid_t terminal = child(), vm = child(), parallels = child(), safari = child();
  finder = child();

  // ---- The user's binding, as macOS keeps it ----
  Hotkey h = hotkeyFrom(NULL, HOTKEY_SPACE_LEFT);
  check(h.enabled && h.keycode == 123 && h.flags == (C | FN), "binding: never changed: Move left a space is Ctrl+Left, on");
  h = hotkeyFrom(NULL, HOTKEY_SPACE_RIGHT);
  check(h.enabled && h.keycode == 124, "binding: ... Move right a space Ctrl+Right");
  h = hotkeyFrom(NULL, HOTKEY_MISSION_CONTROL);
  check(h.enabled && h.keycode == 126, "binding: ... Mission Control Ctrl+Up");
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanTrue, 123, 8650752);   // as the mini has it
  h = hotkeyFrom(binding, HOTKEY_SPACE_LEFT);
  check(h.enabled && h.keycode == 123 && h.flags == (C | FN), "binding: the mini's 79 (123, 8650752): Ctrl+Left, on");
  int one = 1, zero = 0;
  CFNumberRef n1 = CFNumberCreate(NULL, kCFNumberIntType, &one), n0 = CFNumberCreate(NULL, kCFNumberIntType, &zero);
  setKey(HOTKEY_SPACE_LEFT, n0, 123, 8650752);
  check(!hotkeyFrom(binding, HOTKEY_SPACE_LEFT).enabled, "binding: enabled = 0 (a number): off");
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanFalse, 123, 8650752);
  check(!hotkeyFrom(binding, HOTKEY_SPACE_LEFT).enabled, "binding: enabled = false: off");
  setKey(HOTKEY_SPACE_LEFT, n1, 65535, 0);
  check(!hotkeyFrom(binding, HOTKEY_SPACE_LEFT).enabled, "binding: no key set (65535): off");
  setKey(HOTKEY_SPACE_LEFT, n1, 33, 0x180000);   // Option+Cmd+[
  h = hotkeyFrom(binding, HOTKEY_SPACE_LEFT);
  check(h.enabled && h.keycode == 33 && h.flags == (O | M), "binding: changed to Option+Cmd+[: that key, those modifiers");
  check(hotkeyFrom(binding, HOTKEY_SPACE_RIGHT).enabled && hotkeyFrom(binding, HOTKEY_SPACE_RIGHT).keycode == 124,
        "binding: ... the right one not listed: still the default");
  CFMutableDictionaryRef odd = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(odd, CFSTR("79"), CFSTR("junk"));
  check(hotkeyFrom(odd, HOTKEY_SPACE_LEFT).keycode == 123 && hotkeyFrom((CFDictionaryRef)CFSTR("x"), 79).keycode == 123,
        "binding: junk in the file: the default");
  CFRelease(odd);
  unsetKeys();

  // ---- The posted key: the shape macOS gets from a keyboard, marked as ours ----
  h = hotkeyFrom(NULL, HOTKEY_SPACE_LEFT);
  CGEventRef kd = hotkeyEvent(h, 1), ku = hotkeyEvent(h, 0);
  check(kd && ku && CGEventGetType(kd) == kCGEventKeyDown && CGEventGetType(ku) == kCGEventKeyUp,
        "posted key: a key down, then a key up");
  check(CGEventGetIntegerValueField(kd, kCGKeyboardEventKeycode) == 123 && CGEventGetIntegerValueField(ku, kCGKeyboardEventKeycode) == 123,
        "posted key: ... the binding's key (123, Left)");
  check((CGEventGetFlags(kd) & HOTKEY_MODS) == (C | FN | PAD) && (CGEventGetFlags(ku) & HOTKEY_MODS) == (C | FN | PAD),
        "posted key: ... Ctrl + fn + keypad (an arrow key, as the keyboard sends it), no Option/Cmd");
  check(CGEventGetIntegerValueField(kd, kCGEventSourceUserData) == OMACVM_KEY_MARKER &&
        CGEventGetIntegerValueField(ku, kCGEventSourceUserData) == OMACVM_KEY_MARKER, "posted key: ... with our marker");
  CFRelease(kd); CFRelease(ku);
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanTrue, 33, 0x180000);
  kd = hotkeyEvent(hotkeyFrom(binding, HOTKEY_SPACE_LEFT), 1);
  check(CGEventGetIntegerValueField(kd, kCGKeyboardEventKeycode) == 33 && (CGEventGetFlags(kd) & HOTKEY_MODS) == (O | M),
        "posted key: a changed binding: its key and modifiers, no fn (not an arrow)");
  // Our tap lets it through even while it would take Cmd keys for the VM.
  frontNet = NET_APP; capturing = 1;
  pthread_mutex_lock(&sendLock); clients[0].target = 1; pthread_mutex_unlock(&sendLock);
  check(tapCb(NULL, kCGEventKeyDown, kd, NULL) == kd && !strcmp(sent(), ""), "posted key: our tap lets it through (no Super to the VM)");
  CGEventRef plain = CGEventCreateKeyboardEvent(NULL, 33, 1);
  CGEventSetFlags(plain, O | M);
  check(tapCb(NULL, kCGEventKeyDown, plain, NULL) == NULL, "... the same keys from the keyboard while captured: the VM's (Super)");
  CGEventRef plainUp = CGEventCreateKeyboardEvent(NULL, 33, 0);
  tapCb(NULL, kCGEventKeyUp, plainUp, NULL); sent();
  CFRelease(kd); CFRelease(plain); CFRelease(plainUp);
  capturing = 0;
  unsetKeys();

  // ---- A Mac mini with one display: Desktop 1 (Terminal), the VM's full-screen Space ----
  const uint64_t mini[] = { 101, 102 };
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
  pointer = CGPointMake(1000, 700);
  front = terminal; world[0].cur = 101;
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(C|O|M, HID, 0) == 0 && !went && !keys && !swipes, "in macOS before any VM: the combo passes, nothing happens");
  front = vm; world[0].cur = 102;
  frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);
  check(!strcmp(sent(), "S on|"), "VM full screen in front: captured");

  check(press(C|O|M, HID, 0) == 1, "mini: combo in the VM: eaten (down and up)");
  check(!strcmp(sent(), "S esc|") && !capturing, "... Omarchy lets go (S esc), capture off at once");
  check(spaceKeys == 1 && lastKey.keycode == 123 && world[0].cur == 101, "... macOS's Move left a space (Ctrl+Left): Desktop 1");
  check(!swipes && !mcKeys && !mcApp, "... no Dock swipe, no Mission Control");
  check(front == terminal && !went && !hidden, "... the keyboard is Terminal's (no app switch), the VM not hidden");
  settle(vm, NET_APP);
  check(!escaped && !strcmp(sent(), ""), "on Desktop 1: nothing more sent, capture re-arms");

  check(press(C|O|M, HID, 0) == 1, "mini: combo in macOS: eaten");
  check(spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 102 && front == vm && !went,
        "... Move right a space: back to the VM, which has the keyboard");
  settle(vm, NET_APP);
  check(capturing && !strcmp(sent(), "S on|"), "... and it is captured again");

  // The combo's keys still down: the shortcut waits until they are up.
  heldPolls = 5; heldAsked = 0;
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 101 && heldAsked >= 6,
        "keys still held: the shortcut goes once they are up");
  sent(); settle(vm, NET_APP);
  heldPolls = 1000; heldAsked = 0;
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 102 && heldAsked == 50,
        "... held on and on: after 1 s it goes anyway");
  heldPolls = 0;
  settle(vm, NET_APP); sent();

  // A changed binding: the user's own keys are posted.
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanTrue, 33, 0x180000);
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && lastKey.keycode == 33 && lastKey.flags == (O | M) && world[0].cur == 101,
        "binding changed to Option+Cmd+[: that is what is posted, it moves");
  unsetKeys(); sent(); settle(vm, NET_APP); inVM(vm, 102);

  // ---- Toward the Space the user came from ----
  const uint64_t three[] = { 101, 102, 103 };
  layout(1, three, 3, NULL, 0);
  owner[103] = safari; winOn[103] = 33;
  front = safari; world[0].cur = 103; settle(vm, NET_APP);   // Safari's Space before the VM
  inVM(vm, 102);
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 103 && front == safari,
        "came from the Space on the right (Safari): Move right a space, back to it");
  settle(vm, NET_APP); sent();
  check(press(C|O|M, HID, 0) == 1 && lastKey.keycode == 123 && world[0].cur == 102 && front == vm, "... and back in: Move left");
  settle(vm, NET_APP); sent();
  front = terminal; world[0].cur = 101; settle(vm, NET_APP);   // now from Terminal's, on the left
  inVM(vm, 102);
  check(press(C|O|M, HID, 0) == 1 && lastKey.keycode == 123 && world[0].cur == 101 && front == terminal,
        "came from the Space on the left (Terminal): Move left a space");
  settle(vm, NET_APP); sent();
  // Unknown (the helper started with the VM in front): left, else right.
  memset(cameFrom, 0, sizeof cameFrom); inVM(vm, 102);
  check(press(C|O|M, HID, 0) == 1 && lastKey.keycode == 123 && world[0].cur == 101, "not known where from: left");
  settle(vm, NET_APP); sent();
  const uint64_t vmFirst[] = { 102, 101 };
  layout(1, vmFirst, 2, NULL, 0);
  inVM(vm, 102);
  check(press(C|O|M, HID, 0) == 1 && lastKey.keycode == 124 && world[0].cur == 101, "... the VM's Space the first one: right");
  settle(vm, NET_APP); sent();
  DisplaySpaces d = { .n = 4, .spaces = { 1, 2, 3, 4 }, .current = 2 };
  check(leaveDir(&d, 4) == 1 && leaveDir(&d, 1) == -1 && leaveDir(&d, 2) == -1 && leaveDir(&d, 9) == -1 && leaveDir(&d, 0) == -1,
        "plan: toward where from (two away: one step that way); from = the VM's, gone or unknown: left");
  d.current = 1;
  check(leaveDir(&d, 0) == 1, "plan: ... from the first Space: right");
  d.n = 1;
  check(leaveDir(&d, 0) == 0, "plan: a single Space: no move");

  // ---- Checked, with fallbacks; never out of full screen, never hidden ----
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; owner[102] = vm;
  front = terminal; world[0].cur = 101; settle(vm, NET_APP); inVM(vm, 102);
  // The shortcut reaches nothing (an old VM runtime took it): the Dock swipe.
  keysIgnored = 1;
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && swipes == 1 && world[0].cur == 101 && front == terminal,
        "shortcut did not move: a Dock swipe, it lands");
  check(!mcKeys && !mcApp && !hidden && !went, "... no Mission Control, nothing hidden");
  settle(vm, NET_APP); sent();
  // Back in, the shortcut ignored: the VM's window to the front (its Space shows).
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && !swipes && went >= 1 && wentTo == vm && world[0].cur == 102 && front == vm,
        "back in, the shortcut did not move: the VM's window to the front instead");
  settle(vm, NET_APP); sent();
  // The shortcut off: straight to the Dock swipe.
  keysIgnored = 0;
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanFalse, 123, 8650752);
  check(press(C|O|M, HID, 0) == 1 && !keys && swipes == 1 && world[0].cur == 101, "Move left a space off: nothing posted, a Dock swipe");
  unsetKeys(); settle(vm, NET_APP); sent();
  inVM(vm, 102);

  // Only two Spaces and the swipe's sign the wrong way round: the swipe
  // bounces at the edge, the other direction is tried once, lands and is kept.
  keysIgnored = 1; worldSign = -1; saved = 0;
  check(press(C|O|M, HID, 0) == 1 && swipes == 2 && world[0].cur == 101 && saved == 1 && swipeSign == -1 && !mcKeys && !mcApp,
        "shortcut ignored, swipe the wrong way: bounced, retried the other way, lands, kept");
  settle(vm, NET_APP); sent(); inVM(vm, 102);
  worldSign = 1; swipeSign = 1; saved = 0;

  // macOS 27 on the mini: the shortcut and the swipe do nothing -> Mission
  // Control (its shortcut: OmacVM.app's QEMU lets it through). The VM stays.
  swipesIgnored = 1;
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && swipes == 2 && mcKeys == 1 && !mcApp,
        "shortcut and swipe do nothing: Mission Control (Ctrl+Up), the user picks a Space");
  check(world[0].cur == 102 && !hidden && !went && swipeSign == 1 && !saved,
        "... the VM stays full screen and is not hidden, no app switch, the swipe's sign as before");
  check(!capturing && escaped, "... capture stays off (the trackpad and keys are macOS's for Mission Control)");
  // Mission Control's shortcut off: its app.
  setKey(HOTKEY_MISSION_CONTROL, kCFBooleanFalse, 126, 8650752);
  sent();
  int r = press(C|O|M, HID, 0); const char *got = sent();
  check(r == 1 && capturing && !keys && !swipes && !strcmp(got, "S on|"),
        "... the combo again there: captured again, nothing moves");
  inVM(vm, 102);
  check(press(C|O|M, HID, 0) == 1 && !mcKeys && mcApp == 1 && world[0].cur == 102 && !hidden,
        "Mission Control's shortcut off: the Mission Control app instead");
  unsetKeys();
  // Everything off and ignored: no key at all, still Mission Control.
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanFalse, 123, 8650752); setKey(HOTKEY_SPACE_RIGHT, kCFBooleanFalse, 124, 8650752);
  setKey(HOTKEY_MISSION_CONTROL, kCFBooleanFalse, 126, 8650752);
  press(C|O|M, HID, 0); sent(); inVM(vm, 102);
  check(press(C|O|M, HID, 0) == 1 && !keys && swipes == 2 && mcApp == 1 && world[0].cur == 102 && !hidden,
        "every shortcut off, the swipe ignored: Mission Control's app, nothing hidden");
  unsetKeys();
  keysIgnored = 0; swipesIgnored = 0;
  press(C|O|M, HID, 0); sent(); inVM(vm, 102);

  // The Mac mini at 12:58 and 15:25: nothing moved and Finder had no window.
  // Now: Mission Control, the VM never leaves full screen.
  end(terminal); terminal = child(); owner[101] = terminal;   // the app from before has quit
  keysIgnored = swipesIgnored = 1;
  check(press(C|O|M, HID, 0) == 1 && mcKeys == 1 && !went && !hidden && world[0].cur == 102,
        "mini, nothing moves (the app from before has quit): Mission Control, not Finder, not hidden");
  keysIgnored = swipesIgnored = 0;
  press(C|O|M, HID, 0); sent(); inVM(vm, 102);

  // No Spaces information (an older or newer macOS without the call): Mission Control.
  int saveN = nWorld; nWorld = 0;
  check(press(C|O|M, HID, 0) == 1 && !spaceKeys && !swipes && mcKeys == 1 && !went && !hidden,
        "no Spaces information: Mission Control");
  nWorld = saveN;
  press(C|O|M, HID, 0); sent(); inVM(vm, 102);

  // ---- A MacBook and an external display, the VM full screen on both ----
  const uint64_t inner[] = { 201, 202 }, outer[] = { 301, 302 };
  layout(2, inner, 2, outer, 2);
  owner[201] = terminal; winOn[201] = 11; owner[202] = vm; winOn[202] = 22;
  owner[301] = safari; winOn[301] = 44; owner[302] = vm; winOn[302] = 23;
  world[0].cur = 202; world[1].cur = 302; front = vm;
  pointer = CGPointMake(3000, 600);   // on the external display
  settle(vm, NET_APP); sent();
  owner[301] = finder;   // the external's desktop shows no app: Finder
  warps = 0;
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 2 && !warps,
        "two displays: only the display under the pointer moves (no warp needed)");
  check(world[1].cur == 301 && world[0].cur == 202, "... the external shows its desktop, the MacBook still the VM");
  check(went == 1 && wentTo == finder && front == finder && !hidden, "... the keyboard follows the pointer (Finder, the desktop there)");
  settle(vm, NET_APP);
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 2 && world[1].cur == 302, "... the combo there moves it back");
  check(front == vm, "... and the VM has the keyboard");
  settle(vm, NET_APP); sent();
  owner[301] = safari;

  // The pointer on a display without the VM: nothing moves, the keyboard goes there.
  world[1].cur = 301;
  check(press(C|O|M, HID, 0) == 1 && !keys && !swipes && went == 1 && wentTo == safari && wentWin == 44 && world[0].cur == 202,
        "pointer on a display without the VM: no move, the keyboard goes to what it shows");
  sent(); settle(vm, NET_APP);
  world[1].cur = 302; front = vm; settle(vm, NET_APP); sent();

  // "Swipe all monitors": macOS moves the pointer's display only, so the
  // pointer visits the other display for its shortcut and comes back.
  all = 1; warps = 0;
  CGPoint before = pointer;
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 2 && world[0].cur == 201 && world[1].cur == 301, "all: both displays move out of the VM");
  check(movedOn[0] != movedOn[1] && warps == 2 && pointer.x == before.x && pointer.y == before.y,
        "all: ... one shortcut on each display (the pointer went there and back)");
  sent(); settle(vm, NET_APP);
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 2 && world[0].cur == 202 && world[1].cur == 302 && front == vm,
        "all: ... and both back into it");
  settle(vm, NET_APP); sent();
  // One display does not move: only that one gets the Dock swipe.
  keysIgnored = 1;
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 2 && swipes == 2 && world[0].cur == 201 && world[1].cur == 301 && !mcKeys,
        "all, the shortcut ignored: each display swiped, both out");
  keysIgnored = 0;
  sent(); settle(vm, NET_APP); front = vm; world[0].cur = 202; world[1].cur = 302; settle(vm, NET_APP); sent();
  all = 0;

  // "Displays have separate Spaces" off: one list of Spaces for both displays.
  const uint64_t shared[] = { 401, 402 };
  layout(2, shared, 2, shared, 2);
  owner[401] = terminal; winOn[401] = 11; owner[402] = vm; winOn[402] = 22;
  world[0].cur = world[1].cur = 402; front = vm; all = 1;
  settle(vm, NET_APP); sent();
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1, "Spaces shared by the displays, all: one shortcut, not two");
  sent(); settle(vm, NET_APP);
  all = 0;

  // ---- Not the real keyboard, a held key, other combos: as before ----
  front = finder; world[0].cur = 401; world[1].cur = 401;
  frontChanged(finder, -1, 0, "", 0, 1); sent();
  check(press(C|O|M, POSTED, 0) == 0 && !went && !keys, "combo posted by an app in macOS: passes, nothing happens");
  check(press(C|O|M, HID, 1) == -1 && !went && !keys, "a held combo (autorepeat): its repeats eaten, nothing happens");
  check(press(O|M, HID, 0) == 0 && !went, "Option+Cmd+Esc (Force Quit) passes");
  check(press(C|M, HID, 0) == 0 && !went, "Ctrl+Cmd+Esc passes");

  // ---- Parallels: the same way out and back; Mission Control by its app ----
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = parallels; winOn[102] = 55;
  pointer = CGPointMake(1000, 700); world[0].cur = 101; front = terminal;
  frontChanged(terminal, -1, 0, "", 11, 1);
  world[0].cur = 102; front = parallels;
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 101 && front == terminal, "Parallels VM: moved out");
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 102 && front == parallels, "... and into the Parallels VM again");
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();
  keysIgnored = swipesIgnored = 1;
  check(press(C|O|M, HID, 0) == 1 && !mcKeys && mcApp == 1 && world[0].cur == 102 && !hidden,
        "Parallels, nothing moves: Mission Control's app (Parallels may take keys), nothing hidden");
  keysIgnored = swipesIgnored = 0;
  press(C|O|M, HID, 0); frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();

  // The same VM app in front in a window (it left full screen): the combo is the VM's, as before.
  frontChanged(parallels, 0, 0, "", 0, 0);
  check(press(C|O|M, HID, 0) == 0 && !went && !keys, "the VM's app in front in a window: the combo passes to it");

  // Parallels outlives its VM: its window gone, the combo in macOS is macOS's again.
  front = terminal; world[0].cur = 101;
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); frontChanged(terminal, -1, 0, "", 11, 1); sent();
  vmAlive = 0;
  check(press(C|O|M, HID, 0) == 0 && !went && !keys, "the VM's window is gone (app still running): the combo passes");
  vmAlive = 1;

  // The VM has quit: the combo in macOS is macOS's again.
  end(parallels);
  check(press(C|O|M, HID, 0) == 0 && !went && !keys, "the last VM has quit: the combo passes in macOS");

  // Back in when the VM's Space is not right beside: its window to the front.
  const uint64_t far[] = { 101, 103, 102 };
  layout(1, far, 3, NULL, 0);
  owner[101] = terminal; owner[103] = safari; owner[102] = vm; winOn[102] = 22;
  front = terminal; world[0].cur = 101; settle(vm, NET_APP);
  inVM(vm, 102);
  frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; world[0].cur = 101; sent();
  check(press(C|O|M, HID, 0) == 1 && !keys && went >= 1 && wentTo == vm && world[0].cur == 102,
        "in macOS, the VM's Space two away: its window to the front (no shortcut)");
  settle(vm, NET_APP); sent();
  frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; world[0].cur = 101; escaped = 0;
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;

  // ---- An OmacVM VM in a window with the keyboard: the combo gives it to
  // the app from before; in macOS it brings that window back ----
  pid_t winvm = child();
  front = winvm;
  frontChanged(winvm, NET_APP, 0, "", 77, 0); sent();
  check(press(C|O|M, HID, 0) == 1 && went == 1 && wentTo == terminal && wentWin == 11 && front == terminal && !keys,
        "VM in a window: the combo gives the keyboard to the app from before (Terminal), no Space move");
  check(!capturing && !strcmp(sent(), ""), "... nothing sent to the guest");
  check(leftWinPid == winvm && leftWinWin == 77, "... and that window is remembered");
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(C|O|M, HID, 0) == 1 && went == 1 && wentTo == winvm && wentWin == 77 && front == winvm,
        "in macOS: the combo brings the VM window back, with the keyboard");
  frontChanged(winvm, NET_APP, 0, "", 77, 0);
  check(!leftWinPid, "... in it again: forgotten");
  check(press(C|O|M, HID, 1) == -1 && !went && !leftWinPid && front == winvm, "VM in a window: a held combo (autorepeat): its repeats eaten, nothing happens");
  check(press(C|O|M, POSTED, 0) == 0 && !leftWinPid && front == winvm, "VM in a window: a posted combo passes, not remembered");
  // The switch refused: the VM's app is hidden, macOS has the keyboard (a window, not full screen).
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

  // The plan on its own.
  DisplaySpaces p = { .n = 3, .spaces = { 1, 2, 3 }, .current = 2 };
  check(stepOut(&p) == -1, "plan: out of a Space in the middle (not known where from): to the left");
  p.current = 1;
  check(stepOut(&p) == 1, "plan: out of the first Space: to the right");
  check(stepToward(&p, 2) == 1 && stepToward(&p, 3) == 0 && stepToward(&p, 9) == 0,
        "plan: back only to a Space right beside (else the VM's window)");

  CFRelease(n0); CFRelease(n1);
  end(terminal); end(vm); end(safari); end(finder);
  return fail;
}
