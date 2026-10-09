# Benchmarks

How OmacVM measures the four ways (Parallels, UTM, VMware Fusion, OmacVM.app)
against the Mac itself, so anyone can run
the same tests and get numbers that compare. The results so far are at the
end. The tools are in [`src/bench/`](../../src/bench).

## What we measure

| Test | What it tells you | Mac | VMs |
|---|---|---|---|
| Geekbench 7 CPU | CPU, single-core and multi-core | ✓ | ✓ (Linux ARM preview) |
| Speedometer 3.1 | web apps: browser and CPU together | ✓ | ✓ |
| MotionMark 1.3.1 | 2D graphics drawn through the browser | ✓ | ✓ |
| WebGL Aquarium, 30,000 fish | 3D in the browser, frames per second | ✓ | ✓ |
| Basemark Web 3.0 | the GPU in the browser: WebGL, canvas, SVG, plus some JavaScript and page tests | ✓ | ✓ |
| Geekbench 7 GPU | GPU compute | ✓ (Metal, OpenCL) | only OmacVM.app with Venus, see below |
| WebGPU matmul (`browser-bench.py webgpu`) | GPU compute in the browser, GFLOPS | ✓ | only OmacVM.app with Venus |
| glmark2 | OpenGL ES in the VM, absolute score | ✗ no macOS build | ✓ |

**GPU compute needs Vulkan or OpenCL in the VM.** Parallels, UTM and VMware
Fusion offer neither to a Linux guest: Geekbench 7's Linux ARM preview lists
no GPU there, and `bench.sh` records that as "not available in this VM".
OmacVM.app with the vulkan feature (`omacvm enable vulkan`, experimental)
has both: OpenCL through
rusticl and WebGPU in Firefox and in the "Chromium (WebGPU)" launcher (ADR
0022). One locked batch on the M4 Max: Geekbench 7 GPU OpenCL 42486 in the
VM vs 95380 for the Mac's own OpenCL; WebGPU matmul 5071 GFLOPS in the VM's
Chromium vs 6038 in Chrome on the Mac. Geekbench 7 for Linux has no Vulkan
backend, so the VM has no Metal-like score.
The browser tests (MotionMark, WebGL Aquarium, Basemark Web 3.0) and glmark2
measure graphics, not compute. glmark2 has no Mac version, so it has no Mac
baseline: compare its score between the routes only.

## The setup

Do all of this, or the numbers won't compare:

| | |
|---|---|
| Mac | MacBook Pro M4 Max, macOS 15.7.4 (ours; use yours and say which) |
| Each VM | 16 CPUs, 48 GB memory. On Parallels that needs Pro or the trial: Standard stops at 4 CPUs and 8 GB |
| One VM at a time | the VM under test runs alone. Quit the other VM apps, Parallels' background service included: `pgrep -l prl_` should print nothing while you test UTM or Fusion |
| Full screen | the VM app in full screen on the built-in display. `bench.sh` also starts Chrome full screen, on the Mac without the toolbar, so the page is the same size everywhere (1728x1080 at 2x on a 16" MacBook Pro). In a VM that also has an external display (Parallels, Fusion), Chrome must open on the built-in one: move the focus there first (`hyprctl dispatch focusmonitor Virtual-1`) |
| No screensaver | Omarchy's screensaver and lock off: `omacvm enable no-idle-lock --vm NAME`. It can start in the middle of a run otherwise |
| Google Chrome everywhere | Google Chrome on the Mac and in the VM. Arch's Chromium is much slower than Chrome (Parallels: 35.4 with Chromium 153 vs about 45 with Chrome), so it would not compare |
| Chrome's flags | in a VM, `bench.sh` starts Chrome with the flags in `/etc/chrome-flags.conf` and Omarchy's `~/.config/chrome-flags.conf`. On Fusion one of them must have `--ignore-gpu-blocklist` (OmacVM puts it in `/etc`), or Chrome draws in software ([why](../troubleshooting.md#2-fusion-browsers-draw-everything-in-software)) |
| Runs | 3 of each test (`bench.sh`'s default), report the median. Single runs land within 2 to 3 % of each other. The published [results](#results) say where they are single runs |

## Run it

### On the Mac

You need Google Chrome and Geekbench 7 in `/Applications`.

```bash
cd ~/.omacvm                      # or your clone of OmacVM
src/bench/bench.sh ~/bench/mac.jsonl
```

### In a VM

OmacVM copies its tools into the VM, so they are in
`/usr/local/share/omacvm/bench/` after `omacvm update` (or `omacvm apply`).

1. Install Google Chrome for Linux ARM (Arch Linux ARM has no package; this
   unpacks Google's own `.deb` to `/opt/google/chrome`). Run it again to update:

   ```bash
   sudo /usr/local/share/omacvm/bench/install-chrome.sh
   ```

2. For glmark2 and the renderer line, also install `glmark2` and `mesa-utils`
   with pacman.
3. Put the VM in full screen, open a terminal in Omarchy (as your desktop user,
   in the session, not over SSH) and run:

   ```bash
   /usr/local/share/omacvm/bench/bench.sh \
     --only geekbench,speedometer,motionmark,aquarium,basemark,gpu,glmark2 ~/fusion.jsonl
   ```

   glmark2 is not in the default list, hence `--only`. Leave the VM alone until
   it prints `results:`. Chrome opens and closes by itself.

4. Copy the file to the Mac. Name it after the route (`parallels`, `utm`,
   `fusion`, `app` for OmacVM.app), because the report and chart use the file
   names (OmacVM.app's SSH is `-P 52222 root@127.0.0.1`):

   ```bash
   scp -i ~/.ssh/omacvm root@<vm-ip>:/home/<user>/fusion.jsonl ~/bench/
   ```

### Options

```text
bench.sh [--runs N] [--only geekbench,speedometer,motionmark,aquarium,basemark,gpu,glmark2] [OUT.jsonl]
```

Each result is one JSON line: host, OS, test, run, value, and the browser
version or Geekbench link. `browser-bench.py` prints the page size and, for
Basemark, the link to the result on Basemark's site (Powerboard), where each
run is also public.

### GPU check for OmacVM.app

A quick check that the app's GPU path still works after a change to its
runtime (QEMU, virglrenderer, their patches). With the VM running and its
desktop user logged in, on the Mac:

```bash
app/scripts/gpu-check.sh ~/Library/Application\ Support/OmacVM/VMs/<name> [RUNS]
```

It installs Google Chrome in the VM when missing, runs WebGL Aquarium and
Basemark Web 3.0 there (`bench.sh --only aquarium,basemark`), and fails when
either gives no number or when the VM's `logs/qemu.log` shows a shader or GPU
command the Mac refused. One refused shader stops that GL context in the VM
for good: that was Basemark's hang at test 5 in 2.6.0
([finding 23](../troubleshooting.md#23-app-chrome-hangs-in-basemark-web-30-the-screen-flickers)).
Each runtime build also compiles the shaders of that case with the Mac's
OpenGL (`app/runtime/Tests/virgl/test-integer-sampler-shader.c`).

### GPU panel (final round)

The README chart's GPU panel comes from
[`tests/bench/final-round`](../../tests/bench/final-round/README.md): the
runbook and the scripts for the Mac and each VM. Two of its tests are new:

- [`tests/bench/gpu-throughput`](../../tests/bench/gpu-throughput/index.html):
  pure GPU work in WebGL 2, no network. One draw per frame into a fixed
  1920x1080 offscreen target, so the window size and vsync don't count; each
  frame waits for the GPU before and after its draw (`gl.finish()`). Two ways
  to time it: GPU time from Chrome's timer queries (frames of 40 ms), or wall
  time of long frames (80 ms or more, made longer until the fixed cost of the
  waits is under 2 % of a frame). Each system runs both; one row uses one
  method for every system: the GPU timer where every system has a timer that
  agrees with its own wall time, else wall time for all. The table and the
  chart say which. Headline: a ray-march shader; also an ALU score (GFLOPS)
  and a fill score (Gpixels/s). `run.py` runs it and prints JSON.
- [`tests/bench/vkpeak`](../../tests/bench/vkpeak/vkpeak.sh): Vulkan compute
  peak with [vkpeak](https://github.com/nihui/vkpeak) (MIT, downloaded or
  built at run time, pinned). On the Mac through vkpeak's own MoltenVK 1.4.1;
  in OmacVM.app through Venus. A VM with no GPU Vulkan device (none, or only
  lavapipe) gets "not available".
- Geekbench 7 GPU (OpenCL, Vulkan; the Mac: OpenCL, Metal), vkmark and
  glmark2 run in the same round; Geekbench only on a real GPU device, never
  PoCL or llvmpipe. glmark2 and vkmark have no macOS version: the panel shows
  their scores between the VMs.

## Power draw and battery life

How much power the whole Mac draws while Omarchy runs in a VM, against the
same work on macOS, and what that means for the battery. Run on the Mac:

```bash
src/bench/power-suite.sh ~/bench/power-mac.jsonl                      # macOS itself
src/bench/power-suite.sh --vm root@<vm-ip> ~/bench/power-fusion.jsonl  # one VM doing the work
```

| Load | What runs |
|---|---|
| idle | nothing: the desktop as you leave it |
| light | Chrome scrolling a long text page, like reading (`src/bench/pages/reading.html`) |
| video | YouTube 4K in Chrome (`video-bench.py`, below); in a VM also in Omarchy's Chromium |
| cpu | every CPU core busy |
| gpu | WebGL Aquarium with 30,000 fish in Chrome |

- **The number** comes from the battery's own telemetry (`power.sh`, no sudo):
  `AccumulatedSystemLoad` over `SystemLoadAccumulatorCount` in
  `AppleSmartBattery`, the average draw of the whole Mac, display included.
  macOS updates it about every 45 seconds, so each window starts and ends on an
  update (3 minutes plus up to a minute).
- **Battery life** is the battery's capacity over that draw: 52.6 Wh for the
  MacBook Air M2 in the README's chart, 100 Wh for the MacBook Pro 16" M4 Max. On the charger the numbers are the same: the Mac
  reports what the system uses, not what the charger delivers.
- **Keep it quiet:** only the VM under test runs, its app in full screen on the
  built-in display, the same brightness for every run, no other apps, Bluetooth
  and Wi-Fi as usual. Don't touch the Mac while it measures. An agent running
  the tests must not poll during the windows either.

## YouTube 4K

```bash
src/bench/video-bench.py --port 9222 --seconds 60   # Chrome started with --remote-debugging-port=9222
```

It plays a 4K video (YouTube's embed player inside a small local page, which
YouTube needs), and reads from Chrome's media events which decoder plays it:
`VideoToolboxVideoDecoder` on the Mac and `VaapiVideoDecoder` or
`V4L2VideoDecoder` (OmacVM.app's chromium-video) in a VM mean hardware;
`Dav1dVideoDecoder`, `VpxVideoDecoder` or `FFmpegVideoDecoder` mean the CPU.
It also reports the resolution, frames per second and dropped frames. On
the MacBook Pro M4 Max: AV1 3840x2160 at 60 fps in hardware, 0 % dropped; the
MacBook Air M2 has no AV1 decoder, so YouTube sends it VP9.

## Report and chart

On the Mac, with all files in one folder:

```bash
cd ~/bench
~/.omacvm/src/bench/report.py mac.jsonl parallels.jsonl utm.jsonl fusion.jsonl app.jsonl --json results.json
~/.omacvm/src/bench/chart.py ~/.omacvm/docs/benchmarks/chart.json ~/.omacvm/docs/images/benchmarks.svg \
  "MacBook Pro M4 Max · macOS 15.7 · Google Chrome 155 · October 2026"
```

- `report.py` prints a Markdown table: the median of each test, and each route
  as a share of the first file (the Mac).
- `chart.py` draws the bar chart for the README and
  [compare.md](../compare.md): OmacVM.app first, then UTM, VMware Fusion and
  Parallels, each as a share of the Mac (the dashed line at 100 %). Three
  rows: Speedometer 3.1, WebGL Aquarium and Basemark Web 3.0. Tests without a
  Mac value (glmark2, vkmark) are left out.
- The chart's input is [`chart.json`](chart.json): the medians of one round,
  the latest on the MacBook Pro
  ([2026-10-09](#macbook-pro-m4-max-every-route-2026-10-09)), plain bars, no
  version tags. `src/tests/bench-docs.sh` checks that every test comes from
  that one round. Older rounds, with Geekbench and GPU compute, stay on this
  page. (`chart.py` still stripes and tags numbers listed under
  `"unreleased"`, for drafts.)
- The power chart in the README (`docs/images/power.svg`) comes from the
  `"power"` part of `chart.json`:
  `chart.py --panel power docs/benchmarks/chart.json docs/images/power.svg "<subtitle>"`.
  It shows one round only, the latest: the MacBook Air M2 round of
  2026-10-07 ([Results, MacBook Air M2](#results-macbook-air-m2-2026-10-07)),
  watts per load and hours on 52.6 Wh, which browser and decoder played the
  video, and Aquarium's frame rate. Older rounds stay on this page.
  `src/tests/bench-docs.sh` checks the SVG and the README's alt text.
- The GPU progress chart on this page (`docs/images/gpu-progress.svg`)
  comes from the `"gpu_progress"` part of `chart.json`:
  `chart.py --panel progress docs/benchmarks/chart.json docs/images/gpu-progress.svg "<subtitle>"`.
  Each test as a multiple of its oldest version measured, the runs' spread
  as a thin line ([GPU progress](#gpu-progress-2026-10-07)).
  `src/tests/bench-docs.sh` checks it the same way.
- GPU compute in the chart: OmacVM.app with the vulkan feature (Venus on
  MoltenVK, OpenCL through rusticl; experimental in 3.0.0). Geekbench 7 GPU OpenCL,
  one locked batch on 2026-10-04: Mac 95,380
  ([252722](https://browser.geekbench.com/v7/gpu/252722)), OmacVM.app 42,486
  ([252731](https://browser.geekbench.com/v7/gpu/252731)), 45 %. Parallels, UTM
  and Fusion offer no OpenCL or Vulkan to the VM.

**About Geekbench.** The free version uploads every result to
browser.geekbench.com and prints only a link. `bench.sh` saves the link;
`report.py` opens each link in a visible Chrome window on the Mac and reads the
scores from the page. Geekbench's site turns away plain downloads, so curl
does not work. Your results are public on Geekbench's site.

## Results

### MacBook Pro M4 Max, every route (2026-10-09)

The round behind the README's speed chart. MacBook Pro 16" M4 Max, macOS
15.7.4, at night with the screen locked and the display kept on
(`caffeinate -d`). Each route alone: before every run a check that nothing
else of ours ran (other VMs, VM apps, builds, CI runners paused), and the run
counted only if the Mac's other load stayed below 250 % CPU and the page size
was right.

- OmacVM.app 3.0.9 as released (the zip, re-signed with a test app id so it
  runs next to the user's own app), Graphics on Automatic (OpenGL).
  UTM 5.0.6, VMware Fusion 26.0.1, Parallels Desktop 27.0.2.
- Every VM 6 CPUs and 8 GB, Omarchy 4.0.3rc4, kernel 7.2.8, Mesa 26.2.3,
  Hyprland 0.56.2, Google Chrome 155.0.8059.39, glmark2 2023.01.
- Each VM in a window on the built-in display (3456x2160, 120 Hz), sized so
  the guest's output is 2880x1800 at scale 2: Chrome's page is 1440x900 at
  2x, the same as on the Mac (Chrome 155.0.8059.40, a window with a
  1440x900 page). Parallels stops at 2880x1780 (page 1440x890). UTM does not
  resize the guest to its window, so its guest output was set to 2880x1800
  in Hyprland and UTM scales it to the window.
- `bench.sh --runs 1` per test, three rounds, median of 3. Aquarium with
  30,000 fish; glmark2 is `glmark2-es2-wayland --fullscreen` in the VM (no
  macOS version).

| | Mac | OmacVM.app 3.0.9 | UTM | VMware Fusion | Parallels |
|---|---|---|---|---|---|
| Speedometer 3.1 | 61.5 (62.3, 61.5, 61.3) | 42.7 (43.1, 42.7, 42.4) · 69 % | 38.1 (37.4, 38.4, 38.1) · 62 % | 44.8 (45.4, 44.8, 44.8) · 73 % | 43.5 (43.5, 43.5, 42.6) · 71 % |
| WebGL Aquarium, 30,000 fish (fps) | 111.8 (111.5, 112.5, 111.8) | 43.2 (43.2, 43.8, 42.1) · 39 % | 25.6 (25.6, 29.8, 25.6) · 23 % | 41.8 (41.8, 41.5, 42.2) · 37 % | 27.9 (27.9, 21.0, 28.1) · 25 % |
| Basemark Web 3.0 | 3626 (3637, 3343, 3626) | 2801 (2895, 2801, 2489) · 77 % | 2667 (2812, 2637, 2667) · 74 % | 2511 (2417, 2526, 2511) · 69 % | 2680 (2732, 2680, 2557) · 74 % |
| glmark2 (score) | no macOS version | 3058 (3018, 3062, 3058) | 1077 (1077, 1086, 1076) | 2785 (2781, 2785, 2788) | 8297 (8624, 8297, 8259) |

Median first, then the three runs in order, then the share of the Mac.

Notes:

- Two routes were measured again later the same night, under the same
  rules. VMware Fusion: its first start failed on a lock file a stopped VM
  had left behind. UTM: its VM still had Chrome 154; it was measured again
  with the other VMs' Chrome 155. The Chrome 154 runs are not used.

### Results, MacBook Air M2 (2026-10-07)

Every route on one Mac on one day: the round behind the README's power
chart. MacBook Air M2, 8 GB, macOS 26.6.2, the built-in 60 Hz display with
a notch. Each VM had 4 CPUs and 4 GB, sat on the same external SSD, ran
Omarchy 4.0.3rc4-2 and Google Chrome 155, and ran alone in native full
screen on the built-in display at scale 2 (about 2940x1846 beside the
notch). Every other VM app and its background service was quit.

| Route | Version | The VM |
|---|---|---|
| OmacVM.app | 3.0.3 (a test build of the v3.0.3 tag) | made by the app from the 3.0.0 image, guest updated to 3.0.3, kernel 7.2.8, Graphics Automatic (OpenGL) |
| UTM | 5.0.6, settings as `omacvm build` sets them | full build, kept on the SSD with `omacvm build --vm-dir` ([#248](https://github.com/gillesgoetsch/omacvm/pull/248)), kernel 7.2.9, ANGLE on Metal |
| VMware Fusion | 26.0.1, defaults | full build, kernel 7.2.9 |
| Parallels Desktop | 27.0.2 Pro trial, defaults | full build, kernel 7.2.9 |
| macOS | 26.6.2 | Google Chrome 155 on the Mac, 8 cores |

How it ran:

- **A quiet Mac.** Only Finder and Tailscale (the SSH link) besides the
  route. No desktop widgets, a still wallpaper, True Tone, Night Shift and
  automatic brightness off, no screensaver, no display or system sleep
  (`caffeinate`). On the charger, at 93 to 100 %.
- **Brightness 50 %**, set and read back at the start and the end of every
  window. A window that read anything else, or saw a sleep, would have been
  thrown away and repeated. None was: all 90 power windows and 57 browser
  and glmark2 runs read 0.500 both times.
- **Power** comes from `power.sh` (the battery's telemetry, the whole Mac,
  display included): 30 seconds to settle, then a 3-minute window that
  starts and ends on a battery update. The loads took turns, 3 rounds, with
  3 minutes to cool down between rounds (the Air has no fan). 12 of the 90
  windows ended after 187 to 234 seconds instead of about 240, when the
  battery's update came sooner.
- **Hours** are 52.6 Wh, the Air M2's design capacity, over the draw. This
  Air's battery holds 89 % of that now (4057 of 4563 mAh), so this Mac gets
  about a tenth less.
- **Browser tests** ran in Google Chrome 155 (155.0.8059.39 in the VMs,
  .40 on the Mac) through `bench.sh`, the same 1470x923 page at 2x
  everywhere. Median of 3.
- **Not run:** Geekbench 7 CPU. Its Linux preview runs out of memory in a
  4 GB VM (Multi-Core, Photo Editor).

Power of the whole Mac in watts, median of 3 (range), and hours on 52.6 Wh:

| Load | OmacVM.app 3.0.3 | UTM | VMware Fusion | Parallels | macOS |
|---|---|---|---|---|---|
| Idle | 6.13 (6.05-6.17), 8.6 h | 6.30 (6.30-6.33), 8.3 h | 6.21 (6.18-6.26), 8.5 h | 6.17 (6.14-6.25), 8.5 h | 5.20 (5.02-5.34), 10.1 h |
| Reading: Chrome scrolling `reading.html` | 6.11 (6.03-6.13), 8.6 h | 7.43 (7.43-7.45), 7.1 h | 6.82 (6.76-6.83), 7.7 h | 6.68 (6.63-6.69), 7.9 h | 5.48 (5.29-5.56), 9.6 h |
| YouTube 4K, the browser that played it best (below) | 10.10 (10.09-10.20), 5.2 h | 16.46 (16.38-16.59), 3.2 h | 16.14 (16.10-16.25), 3.3 h | 16.78 (16.50-16.82), 3.1 h | 6.07 (5.98-6.28), 8.7 h |
| Every core busy (the VM's 4, the Mac's 8) | 21.01 (20.97-21.05), 2.5 h | 16.95 (16.90-17.06), 3.1 h | 18.16 (18.08-18.19), 2.9 h | 18.01 (17.90-18.10), 2.9 h | 19.69 (19.36-20.09), 2.7 h |
| WebGL Aquarium, 30,000 fish | 17.11 (17.07-17.20), 3.1 h, 19 fps | 18.15 (17.83-18.15), 2.9 h, 21 fps | 20.64 (20.62-20.95), 2.5 h, 25 fps | 17.43 (17.37-17.90), 3.0 h, 17 fps | 17.34 (17.22-17.48), 3.0 h, 60 fps |

YouTube 4K is Big Buck Bunny, VP9 3840x2160 at 60 fps, SDR, played by
`video-bench.py`. Every route played it at 60 fps. Each route ran it in
Omarchy's Chromium 153 as installed and in Google Chrome 155; the chart
takes the one that dropped fewer frames (Parallels: a tie, so the lower
draw). Bold: the chart's row. Watts, median of 3:

| Route | Browser | Decoder | Dropped frames | Watts |
|---|---|---|---|---|
| **OmacVM.app** | **Chromium, chromium-video on (the default)** | **V4L2VideoDecoder: the Mac's media engine** | **2.6 %** | **10.10** |
| OmacVM.app | Chromium, chromium-video off | VpxVideoDecoder (CPU) | 0.1 % | 16.45 |
| OmacVM.app | Google Chrome | VaapiVideoDecoder: the Mac's media engine | 20.0 % | 8.97 |
| **UTM** | **Chromium** | **VpxVideoDecoder (CPU)** | **0.8 %** | **16.46** |
| UTM | Google Chrome | VpxVideoDecoder (CPU) | 2.5 % | 19.05 |
| **VMware Fusion** | **Google Chrome** | **VpxVideoDecoder (CPU)** | **10.6 %** | **16.14** |
| VMware Fusion | Chromium | VpxVideoDecoder (CPU) | 42.0 % | 17.24 |
| **Parallels** | **Chromium** | **VpxVideoDecoder (CPU)** | **1.8 %** | **16.78** |
| Parallels | Google Chrome | VpxVideoDecoder (CPU) | 1.8 % | 16.90 |
| **macOS** | **Google Chrome** | **VideoToolboxVideoDecoder (hardware)** | **0.0 %** | **6.07** |

Browser and graphics tests, median of 3 (range):

| Test | OmacVM.app 3.0.3 | UTM | VMware Fusion | Parallels | macOS |
|---|---|---|---|---|---|
| Speedometer 3.1 | 30.4 (30.1-30.4) | 26.0 (25.3-26.3) | 28.5 (27.5-28.9) | 29.7 (29.6-29.8) | 47.1 (46.7-47.1) |
| WebGL Aquarium, 30,000 fish (fps) | 18.8 (15.4-18.8) | 22.1 (22.0-22.1) | 36.5 (28.9-38.0) | 21.1 (16.4-21.2) | 60.0 (60.0-60.0) |
| Basemark Web 3.0 | 1357 (1349-1537) | 1704 (1496-1739) | 1359 (1274-1362) | 1378 (1353-1584) | 1872 (1842-1960) |
| glmark2 | 1790 (1774-1840) | 756 (755-758) | 378 (378-379) | 2020 (2005-2080) | no macOS version |

Before quoting these:

- **Every core busy** loads the VM's 4 CPUs (400 % for the VM) and all 8
  cores on macOS. At the same 400 %, OmacVM.app draws 3 to 4 W more than the
  other VMs. We have not found why yet.
- **Aquarium** reaches the display's 60 Hz on macOS, so 60 fps is the
  display's limit, not the Mac's. In the VMs each route draws its own frame
  rate, so the WebGL watts are not an efficiency number. Fusion draws the
  most frames (36.5 fps in the browser test, 25 in the power windows) and
  the most watts.
- **OmacVM.app's Google Chrome** plays the video on the media engine too,
  at 8.97 W, but drops a fifth of the frames on this Air (59.7 fps). The
  chart uses Omarchy's Chromium, the app's default.
- **Fusion** started the VM at scale 1 in full screen. We set scale 2 with
  Omarchy's own `omarchy-hyprland-monitor-scaling 2`, like the other routes.
  Two of Fusion's browser rounds were run again: Chrome took over 30 seconds
  to start after glmark2, and `bench.sh` left that Chrome open when it gave
  up.
- **UTM idle** was 6.30 W here, like the others. The 15.2 W from the
  2026-10-03 MacBook Pro round ([#32](https://github.com/gillesgoetsch/omacvm/issues/32))
  did not show on the Air.
- Parallels' background service (idle, 0 % CPU) was still running during
  the UTM windows. It was off for the macOS and Fusion routes.
- The OmacVM.app VM runs kernel 7.2.8 (the 3.0.0 image), the others 7.2.9
  (full builds).

Raw runs, in round order. Watts:

- OmacVM.app 3.0.3: idle 6.05, 6.13, 6.17; reading 6.13, 6.03, 6.11;
  YouTube 4K in Chromium with chromium-video 10.20, 10.10, 10.09, without
  16.54, 16.38, 16.45, in Google Chrome 8.99, 8.75, 8.97; every core 21.01,
  21.05, 20.97; Aquarium 17.07, 17.11, 17.20.
- UTM: idle 6.33, 6.30, 6.30; reading 7.43, 7.43, 7.45; YouTube 4K in
  Chromium 16.59, 16.38, 16.46, in Google Chrome 19.27, 19.02, 19.05; every
  core 17.06, 16.90, 16.95; Aquarium 18.15, 17.83, 18.15.
- VMware Fusion: idle 6.26, 6.18, 6.21; reading 6.76, 6.82, 6.83; YouTube
  4K in Google Chrome 16.10, 16.25, 16.14, in Chromium 17.35, 17.24, 17.21;
  every core 18.16, 18.19, 18.08; Aquarium 20.95, 20.62, 20.64.
- Parallels: idle 6.25, 6.14, 6.17; reading 6.68, 6.63, 6.69; YouTube 4K in
  Chromium 16.50, 16.78, 16.82, in Google Chrome 16.90, 17.01, 16.88; every
  core 17.90, 18.10, 18.01; Aquarium 17.37, 17.43, 17.90.
- macOS: idle 5.34, 5.20, 5.02; reading 5.56, 5.48, 5.29; YouTube 4K 6.28,
  6.07, 5.98; every core 19.69, 19.36, 20.09; Aquarium 17.34, 17.48, 17.22.

Browser and graphics tests:

- OmacVM.app 3.0.3: Speedometer 30.4, 30.1, 30.4; Aquarium 18.8, 15.4,
  18.8; Basemark 1357, 1349, 1537; glmark2 1840, 1790, 1774.
- UTM: Speedometer 25.3, 26.0, 26.3; Aquarium 22.1, 22.1, 22.0; Basemark
  1704, 1739, 1496; glmark2 756, 755, 758.
- VMware Fusion: Speedometer 27.5, 28.5, 28.9; Aquarium 28.9, 36.5, 38.0;
  Basemark 1274, 1359, 1362; glmark2 378, 378, 379.
- Parallels: Speedometer 29.6, 29.8, 29.7; Aquarium 16.4, 21.1, 21.2;
  Basemark 1378, 1353, 1584; glmark2 2080, 2020, 2005.
- macOS: Speedometer 46.7, 47.1, 47.1; Aquarium 60.0, 60.0, 60.0; Basemark
  1872, 1960, 1842.

### MacBook Pro M4 Max, every route (2026-10-03)

The README's power chart showed this round before the MacBook Air round above replaced it.

2026-10-03, MacBook Pro 16" M4 Max, macOS 15.7.4, 16 CPUs and 48 GB per VM, in
full screen on the built-in display (3456x2160 at 120 Hz), Google Chrome 154,
OmacVM 2.3.0. Parallels Desktop 27.0.2 (Pro trial), UTM 5.0.6, VMware Fusion
26.0.1, OmacVM.app (preview, QEMU 11.1.1 from try-omarchy). Speedometer is
the median of 3 runs; Geekbench, MotionMark and glmark2 are single runs, so a
median of 3 may differ a little.

| | Mac | Parallels | UTM | VMware Fusion | OmacVM.app |
|---|---|---|---|---|---|
| Geekbench 7 single-core (single run) | 3267 | 3164 | 2944 | 3054 | 3183 |
| Geekbench 7 multi-core (single run) | 27290 | 26218 | 24414 | 27037 | 26984 |
| Speedometer 3.1 (median of 3) | 62.9 | 42.4 | 32.9 | 44.4 | 43.8 |
| MotionMark 1.3.1 (single run) | 5865 | no stable result | no stable result | 2368 | no stable result |
| glmark2 (single run) | no macOS version | 7306 | 964 | 1813 | 1017 |
| Geekbench 7 GPU | 207885 (Metal) | ✗ | ✗ | ✗ | ✗ |
| YouTube 4K decoder | AV1, hardware | VP9, CPU | VP9, CPU | VP9, CPU (1.6 % dropped) | VP9, CPU |

Power draw of the whole Mac (W), 3 minutes per load, brightness 50 %:

| | Mac | Parallels | UTM | VMware Fusion | OmacVM.app |
|---|---|---|---|---|---|
| Idle | 6.1 | 5.7 | (15.2) | 5.5 | 6.2 |
| Reading (light) | 6.6 | 7.3 | (19.3) | 5.9 | 6.8 |
| YouTube 4K (SDR) | 8.0 | 24.2 | 39.2 | 20.4 | 21.3 |
| Every core busy | 75.3 | 72.2 | 61.3 | 73.9 | 71.0 |
| WebGL Aquarium, 30,000 fish | 35.6 | 27.4 | 29.1 | 37.3 | 27.2 |

Notes:

- The VMs' idle can be a little below the Mac's: on the Mac the desktop and
  Terminal showed, in the VMs Omarchy's dark desktop, and this Mac's mini-LED
  display draws less for dark content.
- The WebGL row is not a GPU efficiency number: each route draws a different
  number of frames per second.
- An HDR video would make the Mac's own run unfair: macOS drives the display
  brighter for HDR. `video-bench.py` uses an SDR video (16.4 W with HDR on the
  Mac, 8.0 W with SDR).
- UTM's idle and reading numbers (in brackets) don't hold: a later check
  showed about 5 W at idle, also with an app open. Something was probably
  still busy in the VM during our run. They are being measured again
  ([#32](https://github.com/gillesgoetsch/omacvm/issues/32),
  [finding 15](../troubleshooting.md#15-utm-idle-power-is-being-measured-again)).
- MotionMark: [finding 16](../notes/findings.md#16-motionmark-gives-no-stable-result).

### GPU (2026-10-04)

The same Mac, macOS 15.7.4, Google Chrome 154, OmacVM 2.6.0 (release
candidate). One VM at a time in full screen on the built-in display (3456x2160
at 120 Hz), the Mac otherwise idle, display brightness at its lowest (it does
not change these numbers). An external display (3840x2400, 60 Hz, on its own
power) was connected: in full screen, Parallels and Fusion give the VM a second
monitor for it. Chrome ran on the built-in display's monitor everywhere, the
page 1728x1080 at 2x (OmacVM.app: 1728x1085). Median of 3 runs; the share of
the Mac in brackets.

| | Mac | Parallels | UTM | VMware Fusion | OmacVM.app |
|---|---|---|---|---|---|
| Basemark Web 3.0 | 3247 | 2446 (75 %) | 2182 (67 %) | 2522 (78 %) | not measured yet |
| WebGL Aquarium, 30,000 fish (fps) | 107.7 | 26.7 (25 %) | 28.1 (26 %) | 40.6 (38 %) | 23.9 (22 %) |
| Geekbench 7 GPU, Metal | 204241 | ✗ | ✗ | ✗ | ✗ |
| Geekbench 7 GPU, OpenCL | 117456 | ✗ | ✗ | ✗ | ✗ |

Each run:

| | Basemark Web 3.0 | WebGL Aquarium (fps) |
|---|---|---|
| Mac | 3248, 3118, 3247 | 107.7, 108.5, 106.8 |
| Parallels | 2586, 2446, 2423 | 21.9, 28.2, 26.7 |
| UTM | 2182, 2174, 2780 | 25.0, 28.6, 28.1 |
| VMware Fusion | 2478, 2578, 2522 | 38.9, 40.6, 40.9 |
| OmacVM.app | no result (3 tries, before the fix) | 16.8, 24.1, 23.9 |

Notes:

- **Geekbench GPU in a VM: not available.** Geekbench 7's Linux ARM preview
  has no GPU test: `--gpu-list` lists nothing and `--gpu Vulkan` or
  `--gpu OpenCL` only prints the help. No VM offers OpenCL, and none offers
  Vulkan either (Fusion: `vulkaninfo` finds no driver; UTM's Vulkan is off in
  OmacVM's setup). Tried once in each VM.
- Basemark mixes GPU tests (WebGL, canvas, SVG) with JavaScript and page tests,
  so it is not a pure GPU number. Each result is public on Basemark's
  Powerboard; `browser-bench.py` prints its link.
- WebGL Aquarium on the Mac: 108 fps on a 120 Hz display, so close to the
  display's limit. The VMs are far below it.
- OmacVM.app: Basemark never finished in 3 tries (up to 15 minutes each). It stays
  in its Geometry Stress Test, Chrome's page at full CPU. OmacVM.app's test VM
  has 8 CPUs and 16 GB, the others 16 and 48. Cause and fix:
  [finding 23](../troubleshooting.md#23-app-chrome-hangs-in-basemark-web-30-the-screen-flickers).
  With the fix it finishes: 2157 in one run in the app's window (page
  1920x1200 at 2x, the other test VMs paused), not comparable with the table.
  The full-screen run for the table is still to do.
- Chrome must open on the built-in display's monitor: on Fusion it first
  opened on the external one (page 1920x1200, 60 Hz) and gave 41 to 43 fps and
  Basemark 2072 to 2596. Those runs are not in the table.

### OmacVM.app 2.9.0 release candidate (2026-10-05)

RC2 (gpu-2.9.0 at 5586df7) against the runtime of the released 2.8.0, on the
same MacBook, in turns (2.8.0, RC2, RC2, 2.8.0), benchmark lock held for each
session. A throwaway app VM (8 CPUs, 16 GB), its window on the built-in
display, not full screen; another test VM (about one core) kept running.
Median of 6 runs (Aquarium: the first run of each session is a warm-up and
left out), range in brackets.

| | 2.8.0 | 2.9.0 RC2 |
|---|---|---|
| glmark2 short set | 1,124 (1,113-1,138) | 2,856 (2,706-2,970) |
| WebGL Aquarium, 30,000 fish (fps) | 19.9 (19.4-21.0) | 19.0 (18.8-19.1) |
| Basemark Web 3.0 | 2,482 (2,224-2,748) | 2,669 (2,339-2,871) |
| QEMU CPU during the session | 106 % | 130 % |
| testufo on a virtual 120 Hz display, new frames a second | 88.8-90.6 | 116.6-119.6 |

RC2's numbers are not in the chart: in a window, with another VM running,
they are not taken the same way as the others. The 3.0.0 run below, in full
screen with the VM alone, replaced them.

### OmacVM.app 3.0.0 (2026-10-06)

The chart's Speedometer, Aquarium and Basemark for OmacVM.app. Mac mini M4
(macOS 27, LG 5K display at 60 Hz), Google Chrome, `bench.sh`, median of 3.
Each VM alone in native full screen (guest 5120x2880, Chrome's page 2560x1440
at 2x), 6 CPUs and 8 GB. OmacVM.app with v3.0.0's runtime and GPU path
(test build 33fa0079), Graphics on Automatic (OpenGL). Parallels ran in the
same session because it is also in the MacBook rounds above.

| | Mac mini | OmacVM.app 3.0.0 | Parallels | OmacVM.app in the chart |
|---|---|---|---|---|
| Speedometer 3.1 | 56.95 | 33.9 (33.9, 34.3, 30.6) | 35.5 (36.5, 35.5, 35.5) | 40.5 (64 %) |
| WebGL Aquarium, 30,000 fish (fps) | 60.0 | 19.1 (14.0, 19.1, 19.1) | 26.9 (21.0, 26.9, 26.9) | 19.0 (18 %) |
| Basemark Web 3.0 | 2481 | 1730 (1730, 1650, 1743) | 1723 (1723, 1789, 1720) | 2456 (76 %) |

The chart's number is Parallels' MacBook result times OmacVM.app / Parallels
on the mini, for Speedometer 42.4 × 33.9 / 35.5 = 40.5. Scaling by the mini's
own Chrome does not work: its Aquarium stops at the display's 60 Hz, and the
6-CPU VMs lose more on the 10-core mini. Scaled that way, Parallels would get
48.3 fps in Aquarium against the 26.7 it got on the MacBook.

- Aquarium did not change: 19.1, the same as 2.9.0 RC2. UTM and Parallels
  stay ahead.
- Basemark: OmacVM.app's first full-screen run, level with Parallels.
- The Mac mini's Speedometer is the median of 6 runs, 3 before the VMs and 3
  after.
- Geekbench 7 multi-core and GPU OpenCL in the chart are from the MacBook
  rounds (2026-10-03 and 2026-10-04). The mini has no Geekbench, and the CPU
  path did not change in 3.0.0. OpenCL needs `omacvm enable vulkan`.

### OmacVM.app 3.0.1 (2026-10-07)

OmacVM.app 3.0.1 as released (tag v3.0.1, 4384af39), built with a test app
id so it runs next to the user's own app. Its QEMU, virglrenderer, MoltenVK,
KosmicKrisp and firmware are the release zip's (QEMU and virglrenderer differ
only in the build paths inside them). The same Mac mini, LG 5K display, VM
("Bench OmacVM", 6 CPUs, 8 GB) and scripts as the 3.0.0 run above: Google
Chrome 154, `bench.sh`, median of 3, each VM alone in native full screen
(guest 5120x2880, Chrome's page 2560x1440 at 2x), Graphics on Automatic
(OpenGL in 3.0.1), brightness 50 %, display sleep off. Parallels ran in the
same session.

| | Mac mini (before / after the VMs) | OmacVM.app 3.0.1 | Parallels | 3.0.1 scaled as in the chart | 3.0.0 in the chart |
|---|---|---|---|---|---|
| Speedometer 3.1 | 59.3 / 58.4 | 38.3 (38.3, 38.6, 38.3) | 38.6 (36.9, 38.6, 38.6) | 42.1 (67 %) | 40.5 (64 %) |
| WebGL Aquarium, 30,000 fish (fps) | 60.0 / 60.0 | 20.0 (20.0, 19.9, 20.0) | 26.6 (26.9, 26.4, 26.6) | 20.1 (19 %) | 19.0 (18 %) |
| Basemark Web 3.0 | 1968 / 2562 | 1761 (1761, 1710, 1781) | 1582 (1795, 1582, 1559) | 2723 (84 %) | 2456 (76 %) |

**The chart keeps 3.0.0's numbers.** None of the three moved because of
3.0.1:

- Speedometer: Parallels rose about as much in the same session (35.5 on
  2026-10-06, 38.6 now). OmacVM.app against Parallels went from 0.95 to
  0.99. 3.0.1 changed nothing on the CPU or in the browser.
- Aquarium: 20.0 here, but 18.85 (18.4 to 19.0) with the same app and VM an
  hour later, in the OpenGL rows of the A/B below. 3.0.0 had 19.1.
- Basemark: OmacVM.app 1761 against 1730 for 3.0.0. The scaled number jumps
  because Parallels' three runs spread from 1559 to 1795.
- The Mac's own Basemark before the VMs (1836 to 2024) ran right after
  another test on the mini had finished; after the VMs it gave 2499 to 2771.
  The chart does not use the mini's Mac numbers.

A build with #173 that is not released yet (int-302 at 5c7fc40b; virgl binds
a GL program only when it changes), the same VM and session: WebGL Aquarium
24.1 fps (24.1, 24.1, 24.2), +20 % on 3.0.1, and Basemark 1836 (1879, 1818,
1836), within the noise.

**OpenGL against Vulkan on KosmicKrisp, with 3.0.1.** The 3.0.1 app on the
same VM in full screen at 5120x2880, booted with Graphics OpenGL, Vulkan,
Vulkan, OpenGL. Medians over both boots of each mode:

| Mac mini M4, macOS 27 | OpenGL | Vulkan |
|---|---|---|
| glmark2 2023.01, full screen (6 runs) | 845 | 839 (99 %) |
| WebGL Aquarium 30k, Chrome 154 (6 runs) | 18.85 fps | 18.85 fps (100 %) |
| GPU throughput page, wall time: ray march / ALU / fill | 50.0 Gunits/s / 3,721 GFLOPS / 136.6 Gpixels/s | the same |
| QEMU at the idle desktop: CPU | 1.05 % | 1.2 % |
| QEMU memory at the end of the runs | 3.5 GB | 3.2 GB |
| Lost GPU contexts, Mac GPU restarts | 0, 0 | 0, 0 |
| vkmark, full screen | - | 311 |

With Vulkan on, the OpenGL desktop and Chrome lose nothing on KosmicKrisp.
vkcube ran; QEMU's log says the Vulkan image went to the screen by a CPU
copy. The earlier A/B with the 3.0.0 runtime is in
[Graphics: Automatic](#graphics-automatic-2026-10-05).

### Power, OmacVM.app 3.0.1 (2026-10-07)

The same 3.0.1 build as above. Each number is the whole Mac's draw from
`power.sh` (`AccumulatedSystemLoad`, display included), measured over 3
minutes that start and end on a battery update (4 minutes in practice),
after time to settle (30 seconds on the MacBook Pro, 2 minutes on the Air).
Brightness 50 %, read back at the start and the end of every window; the
display stayed on; nothing polled the Mac during a window. Median of 3, range
in brackets. The VM ran alone in native full screen on the built-in display.

MacBook Pro 16" M4 Max, macOS 15.7.4, 01:36 to 02:45. The VM: a copy of the
benchmark VM with its guest updated to 3.0.1, 16 CPUs, 48 GB, Graphics
Automatic (OpenGL), 3456x2160 at 120 Hz, no external display. macOS and VM
runs took turns, 3 rounds. Hours are 100 Wh over the draw.

| Load | macOS | OmacVM.app 3.0.1 | OmacVM.app against macOS |
|---|---|---|---|
| Idle | 6.80 W (6.67-7.15), 14.7 h | 5.85 W (5.82-5.86), 17.1 h | 86 % |
| Light: Google Chrome scrolling `reading.html` | 7.71 W (7.67-8.30), 13.0 h | 8.27 W (8.17-8.61), 12.1 h | 107 % |

- On the charger: AlDente held the battery at 89 %, not charging.
  `power.sh` reads what the system uses, not what the charger gives.
- The VM's idle is below the Mac's for the same reason as on 2026-10-03:
  Omarchy's dark desktop against the Mac's desktop, and the mini-LED display
  draws less for dark content.
- Background on the Mac: Photos analysis (`mediaanalysisd`, about 65 % CPU)
  ran until about 01:40, the start of the first VM idle run, and Contacts
  synced right after the first VM light run. Each window's load before and
  after is in the run's log.
- macOS drew more than on 2026-10-03 on the same Mac (idle 6.8 against
  6.1 W, light 7.7 against 6.6 W). Compare numbers within one round only.
- Only idle and light were run. YouTube 4K, every core busy and WebGL were
  not repeated; the 2026-10-03 table above has them (OmacVM.app preview).

MacBook Air M2, 8 GB, macOS 26.6.2, 01:13 to 02:55. The VM: made new with
the app's own setup from the 3.0.0 image and updated to 3.0.1, 4 CPUs,
4 GB, the app's default features for a Mac with a notch, Omarchy's
screensaver and lock off. In full screen
Omarchy got 2940x1846 next to the notch. Hours are 52.6 Wh (the Air M2's
design capacity) over the draw.

| | Median W | Range | Against macOS idle | Hours |
|---|---|---|---|---|
| macOS idle | 4.54 | 4.52-4.55 | - | 11.6 |
| OmacVM.app 3.0.1 idle | 5.37 | 5.32-5.44 | +18 % | 9.8 |
| OmacVM.app 3.0.1 light: Google Chrome 155 in the VM scrolling `reading.html` | 5.61 | 5.60-5.61 | +24 % | 9.4 |
| OmacVM.app 2.9.1 idle, same disk | 5.47 | 5.43-5.47 | +20 % | 9.6 |
| macOS idle again at the end (1 run) | 4.44 | - | -2 % | 11.8 |

- On the charger, at 100 % and charged. Running from the battery without
  unplugging it needs an SMC write, which we did not do. `power.sh` reads
  what the system uses either way.
- 3.0.1 against 2.9.1 at idle: 0.10 W less, as much as macOS idle moved
  over the 1.5 hours (4.54 to 4.44 W). Call them the same.
- 2.9.1 uses the whole panel in full screen (2940x1912) and starts no
  Bridge or Gestures helper. 3.0.1 ran both.
- The external SSD with the VMs stayed plugged in, and Terminal and a
  status window were on screen in every row.
- No macOS light row: this round compared each VM row with macOS idle. No
  UTM row: the Air has no UTM.

The Mac mini ran no power tests: it has no battery for `power.sh` to read,
and its disk setup differs from the MacBooks', so its numbers would not
compare.

### GPU progress (2026-10-07)

One Mac, one VM, five OmacVM.app releases: only the app changes.

<p align="center">
  <img src="../images/gpu-progress.svg" alt="Bar chart of GPU speed in each OmacVM.app release on one MacBook Air M2 8 GB, the same VM throughout, each test as a multiple of its oldest version measured, median of 3 runs. OpenGL in the VM, glmark2: 2.7.0 1.00x (764), 2.8.0 1.00x (764), 2.9.1 1.93x (1,472), 3.0.0 2.39x (1,827), 3.0.3 2.38x (1,817). Browser graphics, WebGL Aquarium with 30,000 fish: 2.7.0 1.00x (17.4 fps), 2.8.0 0.86x (15.0 fps), 2.9.1 0.87x (15.1 fps), 3.0.0 0.63x (11.0 fps), 3.0.3 1.07x (18.7 fps). Browser overall, Basemark Web 3.0, one run each: 2.7.0 1.00x (1,469), 2.8.0 0.93x (1,359), 2.9.1 0.88x (1,286), 3.0.0 0.90x (1,326), 3.0.3 1.05x (1,536). Vulkan in the VM, vkmark: 3.0.3 scores 821, the only version measured; 2.7.0 and 2.8.0 have no Vulkan setting, 2.9.1 was not tested, 3.0.0 was skipped because it showed no picture at start on M1 and M2 Macs, fixed in 3.0.1." width="100%">
</p>

- Mac: MacBook Air M2, 8 GB, macOS 26.6.2, on the charger, VM disk on the
  external SSD.
- Apps: the published 2.7.0, 2.8.0, 2.9.1, 3.0.0 and 3.0.3 zips, re-signed
  with the test app id so they run next to the user's own app. Only the
  bundle ids and the signature changed; the QEMU runtime with the GPU code
  is byte for byte the release's. Self-update off.
- VM: one APFS clone of a VM made from the 3.0.0 prebuilt image, 4 CPUs,
  4 GB, the same guest for every version: kernel 7.2.9, Mesa 26.2.4,
  glmark2 2023.01, vkmark 2025.01, Google Chrome 155.0.8059.39. Graphics
  OpenGL, which is what Automatic picks in all five versions; vkmark with
  Graphics set to Vulkan (KosmicKrisp).
- Screen: the VM alone in native full screen on the built-in display,
  checked on every boot.
- Order: three rounds, one boot per version in each: 2.7.0 to 3.0.3, then
  3.0.3 to 2.7.0 (with Basemark), then 2.7.0 to 3.0.3. vkmark after that:
  three runs in one boot.
- The Mac: Safari, Shortcuts, Terminal and the status window quit, True
  Tone off, brightness 50 %, read back before and after every test.
  Auto-brightness could not be switched off without sudo: it stayed at 50 %
  in every OpenGL test and moved to 59 % during the vkmark runs. Scores do
  not depend on brightness.

Median of the 3 runs, the runs in brackets in round order. QEMU CPU is the
QEMU process's CPU time over the test's wall time (100 % = one core).

| Version | glmark2, 3 s per scene | WebGL Aquarium, 30,000 fish (fps) | Basemark Web 3.0 (1 run) | vkmark (Vulkan) | QEMU CPU % idle / glmark2 / Aquarium |
|---|---|---|---|---|---|
| 2.7.0 | 764 (764, 735, 764) | 17.4 (17.9, 17.4, 13.1) | 1,469 | no Vulkan setting | 10 / 76 / 151 |
| 2.8.0 | 764 (764, 877, 760) | 15.0 (15.2, 11.0, 15.0) | 1,359 | no Vulkan setting | 10 / 74 / 160 |
| 2.9.1 | 1,472 (1,408, 1,501, 1,472) | 15.1 (15.1, 15.1, 15.1) | 1,286 | not tested | 10 / 97 / 163 |
| 3.0.0 | 1,827 (1,822, 1,831, 1,827) | 11.0 (11.0, 15.1, 11.0) | 1,326 | skipped, see below | 9 / 115 / 152 |
| 3.0.3 | 1,817 (1,817, 1,814, 1,829) | 18.7 (18.6, 19.1, 18.7) | 1,536 | 821 (820, 828, 821) | 9 / 115 / 178 |

- glmark2: 2.9.1 scores 1.9x 2.7.0, 3.0.0 and 3.0.3 2.4x. QEMU's CPU
  during glmark2 went up with it, from 76 to 115 %.
- Aquarium: 3.0.3 is 7 % above 2.7.0 and the runs overlap, so no real gain
  on this Mac. 3.0.0's low median is the Aquarium slowdown that #173 fixed
  in 3.0.2.
- Basemark: one run per version, so read it with care: 2.8.0 to 3.0.0
  are 7 to 12 % below 2.7.0, 3.0.3 is 5 % above.
- vkmark on 3.0.0: with Graphics set to Vulkan the VM showed no picture
  90 seconds after the start and did not answer SSH for 10 minutes, so it
  was stopped. That is the M1/M2 Vulkan start bug #161 fixed in 3.0.1.
  2.7.0 and 2.8.0 have no Vulkan setting; 2.9.1 has only a hidden one,
  not tried.
- Screen size: 2.9.1 fills the whole panel in full screen (2940x1912), the
  others leave the strip beside the notch free (2940x1840 to 1848), so
  Aquarium's page is about 3 % taller in 2.9.1.
- testufo was not run: its only script captures the Mac's screen over SSH,
  which needs a macOS permission on the Air.

The chart's data is the `"gpu_progress"` part of [`chart.json`](chart.json),
every run as measured; `chart.py --panel progress` takes the medians and
divides each by the oldest version measured.

## Fast network (OmacVM.app)

QEMU's user network (libslirp, the default) against the fast network (vmnet
through `omacvm-netd`, `omacvm enable fast-network`), same VM and same QEMU,
one after the other on the Mac mini M4 (macOS 27, 16 GB; VM 6 CPUs / 6 GB,
text mode, no other VM running), 2026-10-05. iperf3 20 s, single runs. CPU:
process CPU time over the run, 100% = one core; the fast network adds
`omacvm-netd`'s. Scripts: `measure-mini.sh` in the track notes (the same
tests as the MacBook measurement of 2026-10-04).

| Test | User network (slirp) | Fast network (vmnet) |
|---|---|---|
| VM → Mac, 1 stream | 3.0 Gbit/s, QEMU 189% | **7.2 Gbit/s**, QEMU 158% + netd 105% |
| VM → Mac, 4 streams | 3.1 Gbit/s, 190% | **6.7 Gbit/s**, 167% + 106% |
| Mac → VM, 1 stream | **12.2 Gbit/s**, 174% | 9.5 Gbit/s, 125% + 57% |
| Mac → VM, 4 streams | **19.6 Gbit/s**, 279% | 8.6 Gbit/s, 171% + 64% |
| Mac connects in, Mac → VM, 4 streams | **19.1 Gbit/s** (port forward) | 8.6 Gbit/s (the VM's own address) |
| Mac connects in, VM → Mac, 4 streams | 3.0 Gbit/s | **6.7 Gbit/s** |
| CPU per Gbit/s, VM → Mac | 0.63 cores | **0.37 cores** |
| TCP connect VM → Mac, median (min..max) | 0.13 ms (0.11..0.17) | 0.17 ms (0.13..0.24) |
| Small HTTP request VM → Mac, median | 0.34 ms | 0.47 ms |
| ping VM → Mac | 0.19 ms | 0.35 ms |
| TCP connect to 1.1.1.1, median | 3.8 ms | 3.2 ms |
| IPv6 to the internet | works (NAT) | works (vmnet's NAT66) |
| Idle CPU | QEMU 3% | QEMU 2%, netd 0% |

- The fast network more than doubles VM → Mac, slirp's weak side (one QEMU
  thread does all of TCP/IP), at 40% less CPU per Gbit/s. Mac → VM is slower
  than slirp on this Mac but still about 9 Gbit/s, about where Parallels' own
  vmnet network was on the MacBook (7.7 to 8.7 Gbit/s). Internet speed does
  not change: the link is the limit on both.
- The MacBook measurement of the user network (busier Mac, other VMs
  running) was slower and less steady: VM → Mac 1.7 Gbit/s, Mac → VM 3.3 to
  6.7, connect latency 4.5 ms median with spikes to 33 ms. The fast network
  is not measured on the MacBook yet (its service needs an administrator's
  password).
- A bigger MTU (9000 on the vmnet interface and the VM) changed nothing
  (7.5 / 9.6 Gbit/s): the Mac's side of the network stays at 1500.
- A QEMU hub between the network card and vmnet (to swap networks while the
  VM runs) cost a quarter of VM → Mac: 7.1 → 5.3 Gbit/s, Mac → VM unchanged
  (A/B on the mini, same VM headless, iperf3 10 s, single runs, no bench lock).
  The fallback therefore plugs in a second card instead. With it, in the
  app (display on, a UTM VM running beside it): 6.9 / 6.3 Gbit/s VM → Mac,
  9.5 / 8.8 Mac → VM (1 / 4 streams).

## Graphics: Automatic (2026-10-05)

What OmacVM.app's Graphics setting picks when it is Automatic
([ADR 0035](../adr/0035-graphics-setting.md)). With Vulkan on, the VM gets the
Venus device next to virgl; the question was whether a Vulkan path is faster
for the work people do: OpenGL apps through Zink (GL on Vulkan), Chrome's
WebGL through ANGLE on Vulkan, and Vulkan apps themselves. The Venus device
itself costs OpenGL nothing (MacBook, locked ABBA, gpu-next: glmark2 2,816 vs
2,898, Aquarium 20.0 vs 19.9 fps).

**macOS 15 (MacBook Pro M4 Max, Venus on MoltenVK 1.4.2).** One test VM, 8
CPUs and 16 GB, headless, the 3.0.0 runtime, under the bench lock, median of 3.
One test Mesa (26.2.4 with OmacVM's five patches) for virgl and Zink:

| | virgl (OpenGL) | Vulkan path |
|---|---|---|
| glmark2 2023.01, quick set, full screen | 3,780 (Arch's Mesa 26.2.3: 3,731) | Zink on Venus: OpenGL ES 2.0 only, every scene crashes |
| WebGL Aquarium 30k, Chrome 154 | 19.4 fps (ANGLE on GL, Wayland) | ANGLE on Vulkan: Chrome's GPU process does not start (ES 2.0 only, Chrome needs 3.0): no WebGL |
| Basemark Web 3.0, WebGL 2 pages | not measured (Basemark not run; the WebGL 2 page rows came out empty, a harness bug, see below) | no WebGL on either Vulkan path |
| vkmark, full screen, Vulkan apps | - | 387 (software present, see below) |

MoltenVK has no `VK_EXT_provoking_vertex`, transform feedback or geometry
shaders, so ANGLE and Zink stop at ES 2.0: on macOS 15 a Vulkan path cannot
carry OpenGL or WebGL at all, so the choice does not need the WebGL 2 number.
The empty WebGL 2 rows: the A/B harness ran the page's runner from `/root` as
the desktop user, who cannot read it, and dropped the error (fixed in the
harness; one run after the fix on the same kind of VM gave a full result on
OpenGL, unlocked, not used here).

**macOS 26 and newer (Mac mini M4, macOS 27, KosmicKrisp),** from the
kosmickrisp track (unlocked, median of 3 unless said; tracks/kosmickrisp.md).
These rows compare drivers and paths one by one; none of them compares a VM
with Vulkan on against the same VM with OpenGL only, and what the Venus device
costs the OpenGL desktop was measured on macOS 15 only (above: nothing):

| | OpenGL path | Vulkan path |
|---|---|---|
| vkmark 800x600 | - | KosmicKrisp 840 vs MoltenVK 650 on the same Mac (+29 %) |
| glmark2-es2 off-screen, one guest Mesa | virgl 592 | Zink on KosmicKrisp 558 (ES 2.0 only) |
| WebGL Aquarium 30k, Chrome 154 | 21.9 fps (ANGLE on GL) | 26.9 fps (ANGLE on Vulkan: X11, Chrome flags and a test Mesa with a patch; no Graphics setting gives this) |
| Basemark Web 3.0 | 1,654 | 1,511 (ANGLE on Vulkan) |

The 3.0.0 build on that mini (2026-10-05, unlocked) picked Vulkan on
KosmicKrisp under Automatic and gave the same picture: Aquarium 30k 18.9 fps
on ANGLE on GL against 26.9-27.0 on ANGLE on Vulkan (X11, flags); vkpeak
fp32 3.9 TFLOPS (MacBook M4 Max on MoltenVK: 15.8).

KosmicKrisp also has `nullDescriptor`, `robustBufferAccess2` and `logicOp`,
which MoltenVK lacks. With Vulkan on, OpenGL stays on virgl (Zink is slower
and ES 2.0 only) and Chrome keeps ANGLE on GL, so on macOS 26 and newer
Vulkan adds Vulkan apps on the better driver and changes nothing else.

**What Vulkan on costs the desktop on KosmicKrisp (2026-10-06).** The same
VM started twice, once with OpenGL only and once with Vulkan on (the Venus
device, a 4 GB host memory window and `omacvm.vkwindows=1`, as the 3.0.1
app starts it), in full screen at 5120x2880 on the Mac mini M4 (macOS 27,
the 3.0.0 runtime, mini lock held, no other VM; 6 CPUs, 8 GB):

| Mac mini M4, macOS 27 | OpenGL only | Vulkan on |
|---|---|---|
| glmark2 2023.01, full screen, 3 s scenes (median of 3) | 847 | 841 (99 %) |
| WebGL Aquarium 30k, Chrome 154, full screen (median of 3) | 18.9 fps | 18.8 fps (99 %) |
| GPU throughput page, Chrome (wall time): fill / ALU | 136.5 Gpixels/s / 3,720 GFLOPS | 136.5 / 3,725 |
| QEMU at the idle desktop: CPU / memory | 1.1 % / 3.6 GB | 1.0 % / 4.2 GB |
| Contexts lost, Mac GPU restarts | 0, 0 | 0, 0 |
| vkcube, vkmark full screen | - | runs through the GPU path; 310 |

Chrome stays on ANGLE on GL (virgl) with Vulkan on, and OpenGL apps stay on
virgl, so the desktop draws the same; Vulkan on adds Vulkan apps and about
0.6 GB of QEMU memory at idle (the mapped window). On a MacBook Air M2 (8 GB, macOS 26.6,
KosmicKrisp, a 4 GB VM in full screen, the 3.0.1 runtime with the small PCI
window: 1 GB host memory window) Vulkan on started and ran vkcube through the
GPU path, vkmark full screen 820, no context lost, no Mac GPU restart, QEMU
at idle 10.6 % CPU in both modes, the Mac at 60 % free memory at the end
either way.

**Automatic = Vulkan on macOS 26 and newer from 3.0.13** (KosmicKrisp in the
app; OpenGL on macOS 15 and before, where Venus runs on MoltenVK). 3.0.0 to
3.0.12 kept Automatic on OpenGL. One constant turns it back
(`Graphics.autoVulkan`, `GRAPHICS_AUTO_VULKAN`).

Vulkan windows: a Venus image handed to Hyprland as a dma-buf cannot be
imported by its OpenGL context on the Mac. Until 3.0.0 RC that import ended
Hyprland's context (black desktop), so app VMs presented through a CPU copy
(Mesa's software WSI, `MESA_VK_WSI_DEBUG=sw`). Now the Mac fills a GL texture
from the image (virgl-set-type-without-egl.patch) and Vulkan apps keep Mesa's
normal present path. vkmark (7 scenes x 5 s, mailbox, M4 Max, macOS 15,
MoltenVK, bench lock, median of 3, test window hidden):

| | normal WSI (now) | software WSI (before) |
|---|---|---|
| window 800x600 | 865 | 336 |
| full screen 2592x1458 | 678 | 65 |

These count the app's frames. The frames the screen shows are capped by the
display's refresh; that was not measured here (the hidden test window paces
Hyprland at ~12 Hz for both paths). With vkmark's headless output, no window:
4,700-5,200.

3.0.0 sent `omacvm.vkwindows=1` only with MoltenVK (macOS 15); with
KosmicKrisp Vulkan windows went through the CPU copy (vkmark full screen on
a Mac mini M4 at 5K, macOS 27: 203; another run, not the table's scene set).
3.0.1 sends it with KosmicKrisp too. Mac mini M4, macOS 27, KosmicKrisp,
Mesa's normal WSI, 2026-10-06: vkcube windowed and full screen at 5K; then
10 minutes of vkmark (shading and texture, 20 s each) in turns full screen
at 5120x2880 (8 runs: 252-272) and in a 1280x800 window (7 runs:
1279-1777), with vkcube in a window the whole time. No context lost, the
desktop answered and showed at the end, QEMU's memory stayed at 2.7-2.9 GB.

## GPU compute with Venus (2026-10-04)

OmacVM.app with Venus only (the other routes have no Vulkan or OpenCL in the
VM, see above). The VM runs OmacVM's guest Mesa (ADR 0022). Two Macs:

- **MacBook Pro M4 Max**, macOS 15.7.4, Venus on MoltenVK 1.4.2. Test VM with
  8 CPUs and 16 GB, in a window. Locked batches under the bench lock (other
  test VMs paused; one VM of another track could not be paused and ran
  beside it): WebGPU from batch L2, Geekbench and saxpy from L2/L3 a few
  minutes later, ffmpeg from the earlier batch L1 (guest Mesa before the
  global-loads and OPAQUE_FD patches; two such VMs ran beside it).
- **Mac mini M4** (10 GPU cores), macOS 27.0, Venus on KosmicKrisp. Test VM
  with 6 CPUs and 8 GB. No bench lock (another agent's builds ran on the mini),
  so these are indications.

WebGPU matmul is `browser-bench.py webgpu` (f32, 2048x2048, GFLOPS, checked
against the CPU). In the VM Chromium runs from the "Chromium (WebGPU)" launcher
(Arch's Chromium 153; Google Chrome 154 gave the same adapter with the same
flags, `omacvm-chrome-webgpu` passes them to it); the default Chromium gets
no hardware adapter in a VM.
Median of 3; the Mac's own number in brackets where the same batch has one.

| | M4 Max, MoltenVK | M4 mini, KosmicKrisp |
|---|---|---|
| WebGPU matmul, Chromium in the VM | 5071 (Mac Chrome 6038: 84 %) | 1148 (mini Chrome 1614: 71 %) |
| WebGPU matmul, Firefox 157 in the VM | 665 (Mac Firefox 319: 208 %) | 167 |
| WebGPU computeBoids, Firefox / Chromium (fps) | 59.9 / 60 (36.4 in the locked batch) | 59.9 / 60.0 |
| Geekbench 7 GPU OpenCL (single run) | 42486 (Mac OpenCL 95380: 45 %) | 18973 (mini OpenCL 35240: 54 %, earlier that day) |
| OpenCL saxpy, 16M floats (GB/s) | 387-444 | 101 |
| ffmpeg 4K `nlmeans`, OpenCL vs the VM's CPUs (fps) | 1.07 vs 0.33 (8 CPUs) | 1.13 vs 0.37 (6 CPUs) |

Each run, M4 Max batch:

| | WebGPU matmul 2048 (GFLOPS) |
|---|---|
| Mac, Chrome 154 | 6434, 6038, 4600 |
| VM, Chromium 153 (launcher) | 5144, 5071, 5018 |
| Mac, Firefox 157 | 285, 333, 319 |
| VM, Firefox 157 | 667, 650, 665 |

Notes:

- Firefox in the VM beats Firefox on the Mac: on the Mac Firefox's WebGPU
  (wgpu) writes Metal shaders itself, in the VM it writes SPIR-V and the
  Vulkan driver translates it, and that translation is faster for this kernel.
  Chrome (Dawn) is fast on both.
- The Mac's GPU speed moved a lot between batches (Chrome 2048: 3885 in an
  earlier locked batch, 6188 in an unlocked one): compare within a row.
- Geekbench 7 runs every OpenCL workload and all pass validation. The VM loses
  most where a workload launches many small kernels: each launch crosses the
  Venus ring (Background Blur 18301 vs 61273, Face Tracking 24606 vs 91731).
- Results: [VM](https://browser.geekbench.com/v7/gpu/252731),
  [Mac](https://browser.geekbench.com/v7/gpu/252722),
  [mini VM](https://browser.geekbench.com/v7/gpu/252849).
- clpeak sizes its work by the number of compute units, and Zink reports one
  (Vulkan has no such query): fp32 1.5 TFLOPS as reported, 8.9 with the count
  forced to 40 (test only), Mac OpenCL 15.6-16.1.
- ffmpeg's `nlmeans_opencl` runs many small kernels, and the mini and the
  M4 Max are about equal: most likely the VM's latency per launch decides it,
  not the GPU (not measured per launch).
- Stability: 63 rounds over 36 minutes on the M4 Max and 24 rounds over 15
  minutes on the mini (OpenCL, Firefox and Chromium WebGPU, ffmpeg OpenCL),
  no failure.
