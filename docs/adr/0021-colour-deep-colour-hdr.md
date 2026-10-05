# 0021: Colour-tagged frames, deep colour and HDR through the IOSurface present

Status: accepted. Built on `pacing-hdr` (`qemu-cocoa-gl-present-color.patch`,
guest `src/app/guest/virtio-gpu/`), not merged. HDR is off by default.

## Context

- The present IOSurfaces carried no colour space. Core Animation then shows
  them as display RGB: on a P3 MacBook the guest's sRGB colours were
  stretched to P3 (guest `#ff0000` measured as P3 (255,0,0)).
- The Mac's built-in display is an XDR panel (EDR headroom up to 16x SDR
  white). Hyprland 0.56 in Omarchy has colour management and HDR output
  (`cm = "hdr"`, `bitdepth = 10`), and mpv/Chrome speak the Wayland colour
  management protocol. The guest's virtio-gpu driver offered only
  XRGB8888 for scanout, so Hyprland could not go 10-bit.
- virtio-gpu has no way to say which colour space a scanout is in.

## Options

1. Tag the surfaces sRGB and keep 8 bits. Fixes colours, no HDR.
2. Deep colour: the guest scans out 10-bit; QEMU keeps the depth in
   half-float IOSurfaces. Needs a guest driver that offers 10-bit planes.
3. HDR: the 10-bit output is BT.2100 PQ; QEMU tags the surfaces PQ and the
   layer asks for EDR. How QEMU learns that the output is PQ:
   a. a setting on both sides (the app turns HDR on in the guest's monitor
      rule and in QEMU's environment);
   b. the guest driver passes the connector's `Colorspace` /
      `HDR_OUTPUT_METADATA` to the host (needs a virtio-gpu extension);
   c. the EDID QEMU makes carries HDR metadata and the Mac's luminance, and
      the guest tells the host over the display port which mode it chose.
4. A `CAMetalLayer` with an extended colour space. Same result as tagging a
   plain layer's IOSurface contents; tried, more latency (ADR 0020).

## Decision

1 always, 2 when the scanout is 10-bit, 3a now (`OMACVM_GL_HDR=1`), 3b/3c
later. The guest driver change is small and upstreamable
(`linux-virtio-gpu-deep-color.patch`: 10-bit formats on the primary plane
when virgl 3D is on); until a stock kernel has it, OmacVM builds the module
in the guest (`omacvm-virtio-gpu-build`, needs the kernel headers).

## Consequences

- Colours are right on every Mac display (P3 or sRGB); `OMACVM_GL_COLOR=native`
  restores the old look.
- A 10-bit scanout costs half-float surfaces (8 bytes a pixel, 5 surfaces:
  187 MB at 2880x1620 instead of 93 MB). If they cannot be made, QEMU falls
  back to 8-bit surfaces, logs it once and does not try again.
- The app decides HDR once, at VM start, from "any display has EDR
  headroom", not from the display the window is on. That is enough: the
  guest only switches to its 10-bit HDR output at boot, so a change needs a
  VM restart anyway.
- HDR works end to end with a guest monitor rule (`bitdepth = 10,
  cm = "hdr", supports_hdr = 1, max_luminance = 1600, sdr_max_luminance =
  203`), which `omacvm-display-sync` writes by itself when the app's hidden
  `hdr` switch is on and the 10-bit module runs: the MacBook's EDR headroom
  goes to 4.2-16, PQ 203 nits is SDR white on the Mac. Proof with a client
  that sends a PQ image description (GStreamer `waylandsink`): bars at
  100/203/400/600/1000 nits show at 0.37/0.60/0.89/1.10/1.50 times SDR
  white (Hyprland 0.56 compresses the top).
- Most players do not send one yet: mpv 0.41 on OpenGL only reads the
  preferred description (its hint needs a Vulkan swapchain, so Venus), Chrome
  154 clips CSS `rec2100-pq` at SDR white. They show as SDR. (An earlier note
  here said mpv showed up to 2.9x; that run had Hyprland's `sdrbrightness`
  left at 3 from the test before.)
- With 3a a wrong combination (QEMU told HDR, guest 10-bit SDR) shows wrong
  colours; 3b/3c remove that. The guest module is rebuilt for new kernels by
  a pacman hook once HDR was turned on.
