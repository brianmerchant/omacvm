# 0015: One window per Mac display

Status: accepted. Built on `app-displays` (`omacvm-cocoa-displays.patch`,
`qemu-virtio-gpu-display-event-race.patch`, guest `omacvm-displays`), tested
on virtual displays only, not merged.

## Context

In full screen with an external monitor, users want Omarchy on every Mac
display at that display's resolution and scale, arranged as on the Mac,
following plug and unplug. QEMU's Cocoa display shows one console in one
window.

## Options

1. One big window spanning all displays, one guest output. macOS gives each
   display its own Space in full screen; a spanning window does not work
   there, and scale differs per display.
2. One window per display, one virtio-gpu output (console) per window.
3. One window, several guest outputs drawn side by side in it. Same Spaces
   problem as 1.

## Decision

Option 2: the main window is `Virtual-1`; each other Mac display gets a head
window with its own `DisplayChangeListener` and layer, sharing the main GL
context. Heads exist only in full screen, only after the guest agent said
hello, and only with "Use external displays" on. Positions and the toggle
travel over the virtio-serial port `org.omacvm.display` (Linux virtio-gpu has
no suggested position). One virtio-tablet; QEMU maps the pointer into the
bounding box of all monitors the guest reported.

## Consequences

- Native resolution and scale per display; arrangement and plug/unplug
  follow live.
- More windows means more focus and pointer-grab cases (only grab while the
  app is active; key window handover). Real full screen with Spaces on a real
  monitor still needs a person at the screen.
- The guest sends JSON that QEMU parses: numbers are type-checked and
  bounded, updates are rate-limited to one a second.
- Up to 5 outputs (`max_outputs=5`).
- Heads use `CAOpenGLLayer` today; with [0010](0010-iosurface-present.md)
  merged they should use the IOSurface present too.
