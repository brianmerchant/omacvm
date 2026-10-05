// Which scroll events macOS-native scroll momentum takes: a trackpad's
// (built-in or Magic Trackpad) and nothing else. Decided per event, from what
// the event says and which trackpad has fingers on it; no AppKit, so
// test-scroll.c checks it with made-up event sequences.
//
// A trackpad's two-finger scroll comes with scroll phases (began, changed,
// ended) while fingers touch, then momentum phases after they lift. A mouse
// wheel sends discrete steps (not continuous); a smooth-scrolling mouse
// (Logitech MX with SmartShift or Logi Options+, high-resolution wheels) sends
// continuous steps without phases (or posted by its app, with or without
// them); a Magic Mouse sends phases too. In none of these has a trackpad
// fingers on it, which is what decides. All of these pass to
// the VM app untouched (its own 1:1 scrolling), so nothing follows after the
// wheel stops.
#ifndef OMACVM_SCROLL_MODEL_H
#define OMACVM_SCROLL_MODEL_H

enum { SCROLL_PASS = 0, SCROLL_TOUCH = 1, SCROLL_MOMENTUM = 2 };

// What one scroll event says (CGEvent fields).
typedef struct {
  int continuous;   // kCGScrollWheelEventIsContinuous
  int phase;        // kCGScrollWheelEventScrollPhase: 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin
  int momentum;     // kCGScrollWheelEventMomentumPhase: 1 begin, 2 continue, 3 end
  double now;       // seconds
} ScrollEvent;

// What the trackpads said lately, and the gesture under way.
typedef struct {
  int fingers;           // fingers on the trackpad that touches now (any trackpad)
  double lastTouch;      // when a trackpad last had two or more fingers on it
  int gesture;           // the phased scroll under way is a trackpad's: -1 not known yet, 0 no, 1 yes
  int momentum;          // the momentum under way follows a trackpad's scroll
  double ended;          // when the last phased scroll ended (phase 4)
} ScrollState;

// Fingers may lift a moment before macOS's last touch-phase event arrives.
#define SCROLL_TOUCH_GRACE 0.25
// macOS's momentum begins right after the fingers' scroll ended; a momentum
// that begins later is not that scroll's (a scroll that ended without one).
#define SCROLL_MOMENTUM_GAP 0.3

static inline void scrollStateInit(ScrollState *s) {
  s->fingers = 0; s->lastTouch = -1e9; s->gesture = -1; s->momentum = 0; s->ended = -1e9;
}

// A trackpad's frame: n fingers touching at time now.
static inline void scrollFingers(ScrollState *s, int n, double now) {
  s->fingers = n;
  if (n >= 2) s->lastTouch = now;
}

// SCROLL_TOUCH: the fingers' own scroll (with macOS's acceleration);
// SCROLL_MOMENTUM: macOS's momentum after a trackpad's fingers lifted;
// SCROLL_PASS: not a trackpad's: the VM app scrolls it as it is.
static inline int scrollRoute(ScrollState *s, const ScrollEvent *e) {
  if (!e->continuous) return SCROLL_PASS;
  if (e->phase) {
    int trackpad = s->fingers >= 2 || e->now - s->lastTouch <= SCROLL_TOUCH_GRACE;
    if (e->phase == 1 || e->phase == 128 || s->gesture < 0) s->gesture = trackpad;
    s->momentum = 0;
    int route = s->gesture == 1 ? SCROLL_TOUCH : SCROLL_PASS;
    if (e->phase == 8) s->gesture = -1;          // cancelled: no momentum follows
    if (e->phase == 4) s->ended = e->now;
    return route;
  }
  if (e->momentum) {
    if (e->momentum == 1) s->momentum = s->gesture == 1 && e->now - s->ended <= SCROLL_MOMENTUM_GAP;
    int route = s->momentum ? SCROLL_MOMENTUM : SCROLL_PASS;
    if (e->momentum == 3) { s->momentum = 0; s->gesture = -1; }
    return route;
  }
  return SCROLL_PASS;   // continuous without phases: a smooth-scrolling mouse
}

#endif
