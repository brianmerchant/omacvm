# A/V sync measurements

How far the sound is from the picture when a video plays in an OmacVM.app VM
(av-sync track, 3.0.1). Test VMs only: these tools play sound and take the
screen.

## Tools

- `mkclip.sh OUTDIR [SECONDS]`: test clips. Every second the whole picture
  turns white for 100 ms and a 1 kHz beep plays for 50 ms, both on the
  second. H.264 + AAC (MP4) and VP9 + Opus (WebM), 1280x720 at 60 fps, plus
  `av.html`, which plays one full screen and logs dropped frames.
- `clip2csv.sh CLIP OUT.csv`: decodes a clip with FFmpeg, to check the clip
  itself (H.264: 0 ms, VP9/Opus: -7 ms as FFmpeg decodes it).
- `avcap.swift`: records the Mac's screen and the Mac's sound together with
  ScreenCaptureKit (one clock for both): per frame the brightness of the
  centre of the screen, per millisecond of sound the loudest sample. Needs
  Screen Recording (an SSH session on the test Mac has it).
- `avsync.py FILE.csv`: pairs each flash with its beep. Offset = sound minus
  picture, positive when the sound is late. Prints median, spread and drift.
  `--selftest` checks it on a synthetic recording.
- `outlat.swift`: the output latency CoreAudio reports for the Mac's default
  output (what a Mac app adds to its own A/V sync, and what QEMU's sound path
  never tells the VM).
- `mini/`: the run on the Mac mini (plain QEMU from a copy of the test app's
  runtime, with the app's options; native Chrome on the Mac as reference).
  `mini/fix.sh` (after the matrix): the 3.0.1 fix, re-measured: installs
  `omacvm-audio-latency` in the test VM, sets the delay as the app would and
  plays the clips again (expected: about minus the device's latency, since
  avcap takes the sound before the device). `QPART` sets QEMU's part,
  `TAG` a label suffix; `mini/confirm.sh` waits for the mini lock and runs
  it twice with 115 ms.

## Results (Mac mini M4, LG UltraFine 12.8 ms, 2026-10-06)

Sound minus picture at macOS's mixer, ms (add 12.8 for the ear):

| run | median |
|---|---|
| native Chrome on the Mac, H.264 / VP9 | +2.3 / -1.7 |
| 3.0.0, H.264 hardware / software decode | 143.4 / 151.0 |
| 3.0.0, VP9 | 113.6 |
| 3.0.0, H.264 with glmark2 stalls | 114 (p10 69, p90 140) |
| audioClassic, H.264 / with stalls | 112.0 / 107 |
| Vulkan, H.264 / VP9 | 146.9 / 126.0 |
| fix, QEMU part 115 (told 128), run a: H.264 / VP9 / stalls | -12.6 / -1.0 / -11.8 |
| fix, run b (VM restarted): H.264 / VP9 / stalls | +16.3 / +29.2 / -14.1 |

Steady within a run (sd 0.1-7 ms); from run to run QEMU's part moves
106-151 ms. After stalls the sound comes up to the stall's length earlier
for a few seconds.

ScreenCaptureKit takes the sound before the output device and the picture
before the display's scan-out: add the device latency `outlat` prints for
what you hear.
