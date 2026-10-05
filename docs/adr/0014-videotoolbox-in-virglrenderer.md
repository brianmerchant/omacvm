# 0014: VideoToolbox inside virglrenderer's video path

Status: accepted. Built on `video-decode` (`virgl-videotoolbox-decode.patch`),
not merged.

## Context

Guest browsers and players decode video with VA-API. Mesa's virgl driver
already forwards VA-API to the host as virgl video commands, and
virglrenderer's video path (`virgl_video.h`) decodes them with VA-API on a
Linux host. macOS has no VA-API; the Mac's media engine is reached through
VideoToolbox.

## Options

1. A VideoToolbox backend behind `virgl_video.h` (new `virgl_video_vt.c`).
   The guest side stays stock Mesa; decoded frames land in the guest's own
   plane textures inside vrend.
2. A separate virtio device (virtio-video / virtio-media) with a QEMU
   backend. Not in Linux mainline for this use, no Mesa/VA-API driver, frames
   would need a second path into the GPU.
3. A guest V4L2 stateless driver over a custom channel. Google Chrome arm64
   for Linux decodes through VA-API (Arch's chromium is built without it), and
   Firefox uses VA-API too.
4. Software decode only (status quo): ~1.2-1.6 guest cores for 4K60 VP9.

## Decision

Option 1. The VideoToolbox backend rebuilds what VideoToolbox needs from
VA-API's picture parameters (H.264 SPS/PPS, VP9 frames one at a time, AV1
frame OBUs, HEVC), decodes with a real-time hardware session, and copies the
IOSurface planes into the guest's textures with a GL blit.

## Consequences

- Stock Mesa in the guest; Chrome uses it without flags. Firefox and mpv
  need the small VA shim that hides I420/YV12.
- 4K60 VP9: guest 0.34 cores, QEMU 0.45 (software: 1.21 / 1.71).
- We own bitstream parsing that the guest controls: it needs a fuzz harness
  and strict bounds (planned).
- Mesa 26 changed profile numbers; the backend maps both
  (`OMACVM_VIRGL_VIDEO_ABI=legacy`). Upstream virglrenderer's video path is
  broken with Mesa 26 for the same reason.
- HEVC with SPS short-term RPS indexes cannot be fully rebuilt from VA-API
  data (Mesa dropped the bits); x265-style streams may fail.
- Decoding waits on QEMU's main loop (~5 ms per 4K frame); two 4K streams
  contend. Moving the wait off the main loop is the next step.
- `OMACVM_VIDEO_DECODE=0` turns it off; the guest then falls back to software.
