// Offline test of which scrolling scroll momentum takes (test.sh): the
// helper's real event-tap callback gets made-up scroll events, its frame
// callback made-up trackpad frames, and what it sends the guest is read back
// from a socket pair. No permissions, no device, nothing posted.
//   wheel mouse (discrete steps)              -> the VM app, nothing to the guest
//   smooth-scrolling mouse (continuous, no phases: MX Vertical, Logi Options+)
//                                             -> the VM app, nothing to the guest
//   the same with phases and momentum (an app mimicking a trackpad), Magic Mouse
//                                             -> the VM app (no trackpad fingers)
//   trackpad two-finger scroll + momentum     -> "A" while touching, "W" after
//   a Magic Trackpad connected later          -> taken from its first touch on
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <fcntl.h>

static int fail, peer;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

// What the guest got since the last call: counts of A and W lines.
static void drain(int *a, int *w) {
  char buf[8192]; *a = *w = 0;
  for (;;) {
    ssize_t n = read(peer, buf, sizeof buf - 1);
    if (n <= 0) break;
    buf[n] = 0;
    for (char *l = buf; *l; ) {
      if (l[0] == 'A') (*a)++;
      if (l[0] == 'W') (*w)++;
      char *nl = strchr(l, '\n');
      if (!nl) break;
      l = nl + 1;
    }
  }
}

// One scroll event through the tap: 1 = passed on to the VM app.
static int scroll(int continuous, int phase, int momentum, double dy) {
  CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, 0);
  CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, continuous);
  CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, phase);
  CGEventSetIntegerValueField(e, kCGScrollWheelEventMomentumPhase, momentum);
  CGEventSetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1, dy);
  CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1, dy > 0 ? 1 : dy < 0 ? -1 : 0);
  CGEventRef out = tapCb(NULL, kCGEventScrollWheel, e, NULL);
  CFRelease(e);
  return out != NULL;
}

// One trackpad frame with n fingers from device dev.
static void touch(MTDeviceRef dev, int n) {
  MTTouch t[4]; memset(t, 0, sizeof t);
  for (int i = 0; i < n; i++) {
    t[i].state = 4; t[i].zTotal = 0.5f; t[i].pathIndex = i + 1;
    t[i].normalized.pos.x = 0.4f + 0.1f * (float)i; t[i].normalized.pos.y = 0.5f;
  }
  frameCb(dev, t, n, 0, 0);
}

static void addPad(MTDeviceRef dev, int w, int h) {
  pads[nPads].dev = dev; pads[nPads].id = (uint64_t)(uintptr_t)dev; pads[nPads].w = w; pads[nPads].h = h;
  if (activePad < 0) activePad = nPads;
  nPads++;
}

// The model on its own: made-up event sequences, no tap.
static void modelChecks(void) {
  ScrollState s; scrollStateInit(&s);
  ScrollEvent e = { 1, 0, 0, 10.0 };
  check(scrollRoute(&s, &e) == SCROLL_PASS, "model: continuous without phases (smooth mouse) passes");
  e.continuous = 0; e.phase = 1;
  check(scrollRoute(&s, &e) == SCROLL_PASS, "model: a discrete wheel step passes, whatever else it says");
  scrollFingers(&s, 2, 10.0);
  ScrollEvent b = { 1, 1, 0, 10.01 }, c = { 1, 2, 0, 10.02 }, end = { 1, 4, 0, 10.2 };
  check(scrollRoute(&s, &b) == SCROLL_TOUCH && scrollRoute(&s, &c) == SCROLL_TOUCH, "model: two fingers: touch");
  scrollFingers(&s, 0, 10.1);
  check(scrollRoute(&s, &end) == SCROLL_TOUCH, "model: the ended phase right after the lift is still the touch");
  ScrollEvent m1 = { 1, 0, 1, 10.25 }, m2 = { 1, 0, 2, 10.3 }, m3 = { 1, 0, 3, 11.0 };
  check(scrollRoute(&s, &m1) == SCROLL_MOMENTUM && scrollRoute(&s, &m2) == SCROLL_MOMENTUM &&
        scrollRoute(&s, &m3) == SCROLL_MOMENTUM, "model: its momentum, begin to end");
  ScrollEvent mm = { 1, 0, 2, 11.1 };
  check(scrollRoute(&s, &mm) == SCROLL_PASS, "model: momentum after the end belongs to nobody: passes");
  ScrollEvent mouse1 = { 1, 1, 0, 20.0 }, mouseM = { 1, 0, 1, 20.3 };
  check(scrollRoute(&s, &mouse1) == SCROLL_PASS && scrollRoute(&s, &mouseM) == SCROLL_PASS,
        "model: phases and momentum with no trackpad fingers (Magic Mouse, posted): pass");
  scrollFingers(&s, 2, 30.0);
  ScrollEvent cb = { 1, 1, 0, 30.01 }, cc = { 1, 8, 0, 30.02 }, cm = { 1, 0, 1, 30.3 };
  scrollRoute(&s, &cb); scrollRoute(&s, &cc); scrollFingers(&s, 0, 30.05);
  check(scrollRoute(&s, &cm) == SCROLL_PASS, "model: a cancelled touch has no momentum");
  // A trackpad scroll that ended without momentum (fingers stopped first),
  // then later a momentum stream with no scroll before it: not the trackpad's.
  scrollFingers(&s, 2, 40.0);
  ScrollEvent tb = { 1, 1, 0, 40.01 }, te = { 1, 4, 0, 40.2 }, lm = { 1, 0, 1, 41.0 }, lm2 = { 1, 0, 2, 41.05 };
  scrollRoute(&s, &tb); scrollFingers(&s, 0, 40.15); scrollRoute(&s, &te);
  check(scrollRoute(&s, &lm) == SCROLL_PASS && scrollRoute(&s, &lm2) == SCROLL_PASS,
        "model: momentum long after a trackpad scroll ended without one: passes");
}

int main(void) {
  modelChecks();

  // A VM in front, captured, that wants gestures and scroll momentum.
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { perror("socketpair"); return 1; }
  peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1; clients[0].glide = 1; clients[0].target = 1;
  strcpy(clients[0].ip, "127.0.0.1");
  frontNet = NET_APP; capturing = 1; trackpad = 1;
  scrollStateInit(&scrollSt);
  int a, w, passed;

  // 1. A wheel mouse on a Mac with no trackpad (Mac mini): every notch to the
  //    VM app, one to one; nothing goes to the guest, nothing after it stops.
  passed = 0;
  for (int i = 0; i < 30; i++) passed += scroll(0, 0, 0, -10);
  drain(&a, &w);
  check(passed == 30 && a == 0 && w == 0, "wheel mouse: all 30 notches to the VM app, none to the guest");

  // 2. A smooth-scrolling mouse (MX Vertical): continuous steps, no phases.
  passed = 0;
  for (int i = 0; i < 40; i++) passed += scroll(1, 0, 0, -3.5);
  drain(&a, &w);
  check(passed == 40 && a == 0 && w == 0, "smooth-scrolling mouse: all 40 steps to the VM app, none to the guest");

  // 3. Scrolling with phases and momentum but no trackpad fingers (a Magic
  //    Mouse; an app that posts trackpad-like scrolling for a mouse).
  passed = scroll(1, 128, 0, 0) + scroll(1, 1, 0, -2);
  for (int i = 0; i < 10; i++) passed += scroll(1, 2, 0, -4);
  passed += scroll(1, 4, 0, 0) + scroll(1, 0, 1, -8);
  for (int i = 0; i < 20; i++) passed += scroll(1, 0, 2, -3);
  passed += scroll(1, 0, 3, 0);
  drain(&a, &w);
  check(passed == 35 && a == 0 && w == 0, "phases and momentum without trackpad fingers: all to the VM app");

  // 4. The built-in trackpad: two fingers scroll, lift, macOS's momentum.
  MTDeviceRef builtin = (MTDeviceRef)(uintptr_t)0x1001;
  addPad(builtin, 15600, 9600);
  touch(builtin, 2);
  passed = scroll(1, 1, 0, -2);
  for (int i = 0; i < 10; i++) { touch(builtin, 2); passed += scroll(1, 2, 0, -5); }
  touch(builtin, 0);
  passed += scroll(1, 4, 0, 0);
  drain(&a, &w);
  check(passed == 0 && a == 11 && w == 0, "trackpad: the touch goes to the guest (11 A), not to the VM app");
  passed = scroll(1, 0, 1, -9);
  for (int i = 0; i < 25; i++) passed += scroll(1, 0, 2, -3);
  passed += scroll(1, 0, 3, -0.5);
  drain(&a, &w);
  check(passed == 0 && w == 27 && a == 0, "trackpad: macOS's momentum goes to the guest (27 W)");

  // 5. The mouse right after: one to one again, nothing extra.
  passed = 0;
  for (int i = 0; i < 5; i++) passed += scroll(0, 0, 0, -10);
  for (int i = 0; i < 5; i++) passed += scroll(1, 0, 0, -3);
  drain(&a, &w);
  check(passed == 10 && a == 0 && w == 0, "mouse after the trackpad: to the VM app again");

  // 6. A Magic Trackpad connected later (a Mac mini): before, its scrolling
  //    would be nobody's; from its first touch on it is a trackpad's.
  MTDeviceRef magic = (MTDeviceRef)(uintptr_t)0x2002;
  addPad(magic, 16000, 11500);
  touch(magic, 2);
  passed = scroll(1, 1, 0, -2) + scroll(1, 2, 0, -6);
  touch(magic, 0);
  passed += scroll(1, 4, 0, 0) + scroll(1, 0, 1, -7) + scroll(1, 0, 3, -0.5);
  drain(&a, &w);
  check(passed == 0 && a == 2 && w == 2, "Magic Trackpad connected later: its scroll and momentum go to the guest");
  check(tpW == 16000 && tpH == 11500, "the guest learns the Magic Trackpad's size when it touches");

  // 7. Not captured (macOS in front, or the VM in a window): everything passes.
  capturing = 0;
  touch(builtin, 2);
  passed = scroll(1, 1, 0, -2) + scroll(1, 2, 0, -2);
  touch(builtin, 0);
  drain(&a, &w);
  check(passed == 2 && a == 0 && w == 0, "not captured: the trackpad's scrolling stays with the VM app");

  printf("%s\n", fail ? "FAIL scroll" : "ok   scroll: only a trackpad's scrolling gets momentum");
  return fail;
}
