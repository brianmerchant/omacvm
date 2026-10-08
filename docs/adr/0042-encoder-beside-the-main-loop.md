# 0042: Capture mode: the video encoder works beside QEMU's main loop, guest fences wait for its frames

Status: accepted, built (`capture-perf`, 3.0.7).

## Context

A user found the VM laggy, with the sound crackling, whenever Omarchy's
capture mode was on (screenshots and screen recording). Measured on a
MacBook Air M2, test VM at 2940x1840 60 Hz (`work/tracks/capture-perf.md`):

1. Screen recording (gpu-screen-recorder, `h264_vaapi`, constant QP, 60
   frames a second) kept QEMU's main loop busy 93 % of the time: 78 % in
   `VTCompressionSessionEncodeFrame` (the low-latency session used for
   constant QP waits 12-13 ms for each frame) and 6.6 % in `glFinish` after
   the picture copy. The main loop also runs the VM's sound timers and its
   display: the display fell to 12 frames a second, the Mac got 6.8 s of
   sound in 20 s.
2. The frozen screen (hyprpicker -r -z) drew every display again on every
   frame; each frame Hyprland uploaded the whole screen (21.6 MB) through
   virgl: 47-51 % of the main loop in that upload.

The guest reads an encoded frame (its feedback and coded data) after the
fence of the command buffer that ended the frame. Mesa's virgl driver
uses one fence timeline for the whole VM (no context rings), and the
guest kernel signals every fence up to the one QEMU reports.

## Options

1. Encode on vrend's thread as before, only faster: a normal session with
   the QP range instead of the low-latency one moves the wait from
   EncodeFrame to CompleteFrames; the main loop still waits 12-15 ms a frame.
2. Encode beside the main loop and hold the guest's fences: a frame closed
   at END_FRAME goes to the encoder once its GPU copy is done, its result is
   written when the encoder is done, and every fence made after END_FRAME
   signals only then. The guest never reads a frame half done; the main loop
   never waits. Cost: while a frame encodes, every later fence in the VM
   waits too (one timeline), so the desktop's frames wait with it.
3. Signal the fence at once and let the guest wait for the feedback some
   other way: Mesa reads the feedback right after the fence and takes
   "not done" as a failed frame (FFmpeg stops). It would need a changed Mesa
   or a VA-API shim that knows Mesa's internals.
4. Per-context fence rings: Mesa's virgl driver (not Venus) does not use
   them; a guest change outside OmacVM's reach.
5. Encode the recording on the VM's CPU (x264): gpu-screen-recorder falls
   back to it on its own when VA-API is missing; 4 vCPUs cannot keep 60
   frames a second of a Retina display.

## Decision

Option 2 (`virgl-videotoolbox-encode-async.patch`), with option 1's session
for constant QP (the low-latency session stays as the fallback for encoders
that refuse the range). The fence wait is bounded (2 s, then a warning and
the fence signals). For the frozen screen: hyprpicker draws only when
something changed (OmacVM.app VMs build it, `src/app/guest/hyprpicker/`),
and big texture uploads go through a pixel unpack buffer
(`virgl-transfer-upload-pbo.patch`), which halves the main loop's time for
any upload from the CPU.

## Consequences

- Recording, same VM and test: main loop busy 93 % → 14 %, the sound whole
  (20.7 s of 20.7 s), gpu-screen-recorder 87 % → 8 % of a vCPU, the
  recording 60 frames a second and playable. The VM's display runs at 29
  instead of 12 frames a second while recording, not 60: the fences wait
  for the media engine (option 2's cost).
- Frozen screen: Hyprland 41-46 % → 11 % of a vCPU, hyprpicker 17 % → 0,
  1,234 → 30 new GPU resources in 20 s. The selection rectangle (slurp)
  still draws its whole surface when the pointer moves.
- A guest app that ends a frame and never waits for it holds no fence
  longer than the encoder takes; one that never ends a frame gets a failed
  frame at its next BEGIN_FRAME, as before.
- The start of a recording still makes the encoder's session and copies the
  first picture on the main loop (20-40 ms of sound once).
- Upstream hyprpicker draws on every frame by design of its frame loop; the
  fix is small and could go upstream (not posted: the user decides).
