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

ScreenCaptureKit takes the sound before the output device and the picture
before the display's scan-out: add the device latency `outlat` prints for
what you hear.
