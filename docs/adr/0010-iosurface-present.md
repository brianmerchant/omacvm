# 0010: Show the guest's frames as IOSurfaces

Status: accepted. Built on `gpu-native` (`qemu-cocoa-gl-present-on-flush.patch`,
`qemu-cocoa-gl-present-iosurface.patch`), not merged.

## Context

OmacVM.app's QEMU shows the guest's GL scanout with the Cocoa display. It
drew the scanout in a `CAOpenGLLayer` on the AppKit main thread, holding
QEMU's big lock (BQL) while it drew, and only on QEMU's 30 ms GUI refresh
tick. The window showed at most 33 frames a second while Omarchy rendered at
120, and the main thread and QEMU's thread waited on each other every frame.

## Options

1. Keep `CAOpenGLLayer`, redraw on each flush. Simple, but GL drawing and
   the BQL stay on the main thread.
2. Blit the scanout into IOSurfaces on QEMU's thread and set them as a plain
   `CALayer`'s contents. One GPU copy, no GL and no BQL on the main thread;
   Core Animation composites the surface directly.
3. Make the guest's scanout textures IOSurfaces (no copy at all). CGL binds
   IOSurfaces only as `GL_TEXTURE_RECTANGLE`; the guest samples its textures
   as 2D, so virglrenderer would need a rectangle-aware path for every
   shader that reads a scanout (screencopy, blur). Too invasive for now.
4. A `CAMetalLayer` fed from GL through IOSurfaces: same copy as 2, plus a
   Metal device and queue, no gain over 2.

## Decision

Option 2, after option 1 as a separate patch (redraw on flush), so either
can be taken alone. Three surfaces, reused only when `IOSurfaceIsInUse` says
Core Animation is done; a serial queue waits for the blit's fence before the
main thread gets the surface; at most one surface per display refresh.

## Consequences

- The window follows the guest's frame rate up to the display's refresh
  (60/s measured on a 60 Hz display; the old path redrew at most 33 times a
  second by the code). On a 120 Hz panel about 108 of 120 frames reach the
  screen, because frames arrive at a free-running phase; `pacing-hdr` paces
  them on the display's refresh.
- The main thread never waits for the BQL to draw.
- One GPU copy per shown frame stays (cheap next to Apple's per-draw cost).
- The guest sets the scanout size, so the surfaces are capped at the
  largest display and made again at most twice a second; a guest switching
  sizes on every frame gets its frames scaled into the surfaces it has.
  Before (review of 2026-10-04) only 16384x16384 capped them: 3 x 1 GiB, and
  three new surfaces per frame when the size alternated.
- The present queue tests the blit's fence and naps 100 us between tests;
  Apple's `glClientWaitSync` would spin a core for each frame.
- `OMACVM_GL_PRESENT=layer` keeps the old layer; if the IOSurface contexts
  cannot be made the window falls back by itself.
- The head windows of [0015](0015-one-window-per-display.md) still use
  `CAOpenGLLayer` on their branch; merging gives every head this path.
- Option 3 stays open if the copy ever shows up in profiles.
