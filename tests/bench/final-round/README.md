# Final round: GPU and idle power, Mac vs the four VMs

One session on one quiet Mac: macOS itself (the baseline, 100 %), then
OmacVM.app, UTM, VMware Fusion and Parallels, one at a time. About 25 minutes
of GPU tests and 11 minutes of idle power per system.

## What runs

| Test | What it measures | Mac | VMs | Time per system |
|---|---|---|---|---|
| GPU throughput page ([`../gpu-throughput`](../gpu-throughput)) | pure GPU work in WebGL 2: a ray-march shader (headline), an ALU chain, blended fill. Offscreen at 1920x1080, so window size and vsync don't count | ✓ | ✓ | 1.5 min (3 sessions) |
| vkpeak ([`../vkpeak`](../vkpeak)) | Vulkan compute peak, fp32 / fp16 / int32 | ✓ (MoltenVK) | OmacVM.app with Venus; the others have no Vulkan: "not available" | 3 min (3 runs) |
| WebGL Aquarium, 30,000 fish | 3D in the browser, fps | ✓ | ✓ | 2 min (3 runs) |
| Basemark Web 3.0 | browser graphics, with some JavaScript | ✓ | ✓ | 8 to 15 min (3 runs) |
| glmark2 (one version everywhere, 2023.01) | OpenGL ES in the VM | ✗ no macOS version | ✓ | 5 min (3 runs) |
| Idle power (`SystemPowerIn`) | the whole Mac, desktop idle | ✓ | ✓ | 11 min |

Each test runs 3 times; the chart uses the median.

## The Mac, before you start

All of it, or the numbers don't compare (the rules of the 2026-10-03/04
rounds, [docs/benchmarks](../../../docs/benchmarks/README.md#the-setup)):

- Charger connected, battery **not charging** (full, or held by macOS).
  `ioreg -rw0 -c AppleSmartBattery | grep -E '"(IsCharging|ExternalConnected)"'`
  must say `IsCharging = No`, `ExternalConnected = Yes`. The scripts refuse otherwise.
- External monitor unplugged, built-in display only, brightness 50 % (set by
  you; the scripts only read it and record it). Automatic brightness off.
- Nothing else running: no other VM app (`pgrep -l prl_` empty while testing
  UTM or Fusion), no agents, no test VMs, no bench lock held. The scripts check
  and refuse; `FINAL_ROUND_ALLOW_BUSY=1` runs anyway and marks every line
  "preliminary".
- The same Google Chrome version on the Mac and in every VM. The lines record it.
- Each VM: 16 CPUs, 48 GB, in full screen on the built-in display, its
  screensaver and lock off (`omacvm disable idle-lock --vm NAME`), the desktop
  idle (no windows open) for the idle-power part.
- Order: macOS first, then OmacVM.app, UTM, VMware Fusion, Parallels. Quit
  each VM app (and Parallels' service) before the next.
- For idle power: start the script and don't touch the Mac (and don't poll it)
  until it prints the result.

## Run it

From a clone of OmacVM on the Mac (`~/.omacvm` or your checkout):

```bash
F=tests/bench/final-round; R=~/bench/final-$(date +%Y%m%d); mkdir -p $R

# 1. macOS
$F/mac.sh $R/mac.jsonl
$F/idle-power.sh mac $R/mac.jsonl          # Terminal minimised, desktop showing

# 2. each VM, alone, in full screen; SSH as root with ~/.ssh/omacvm
$F/vm.sh app root@127.0.0.1:52222 $R/app.jsonl
$F/idle-power.sh app $R/app.jsonl
$F/vm.sh utm root@192.168.64.9 $R/utm.jsonl
$F/idle-power.sh utm $R/utm.jsonl
$F/vm.sh fusion root@192.168.70.128 $R/fusion.jsonl
$F/idle-power.sh fusion $R/fusion.jsonl
$F/vm.sh parallels root@10.211.55.14 $R/parallels.jsonl
$F/idle-power.sh parallels $R/parallels.jsonl

# 3. table and chart
$F/summarize.py $R/*.jsonl --json $R/chart.json
src/bench/chart.py --panel gpu $R/chart.json docs/images/benchmarks.svg \
  "MacBook Pro M4 Max · macOS 15.7 · Google Chrome 154 · October 2026"
```

(The IP addresses are the 2026-10-03 round's VMs; check yours.)

For OmacVM.app, `vm.sh` records the version of `~/Applications/OmacVM.app`
(else `/Applications`); test another build with `OMACVM_APP=/path/to/OmacVM.app`
in front.

`vm.sh` copies `src/bench` and `tests/bench` into the VM
(`/opt/omacvm-final-round`), installs glmark2, vulkan-tools and vkpeak's
build tools with pacman (vkpeak builds once into the desktop user's
`~/.cache/omacvm-bench`), and needs Google Chrome already installed in the VM.

**OmacVM.app and Vulkan.** vkpeak needs Venus in the VM: the VM's Vulkan
setting on, and Mesa 26.2.4 or newer in the guest (Arch Linux ARM's 26.2.3
fails, see `src/app/guest/venus/install.sh`). Without it the line says "not
available" with the reason; that is what the chart shows.

## What each line holds

`{"target", "test", "preliminary", "result", "mac_state", "quiet", "at"}`:

- `result`: the test's own JSON. VM lines add `vm` (kernel, CPUs, memory,
  monitor mode, GL renderer, Vulkan device, Chrome, Mesa, glmark2 versions) and
  `hypervisor` (name and version).
- `mac_state`: Mac model, macOS version, display mode, brightness (read only),
  charging, charger, battery %.
- `quiet`: other VM processes, Claude processes, the bench lock, load.

A line with `"preliminary": true` or `quiet.busy: true` does not go into
the README.

## Times

| Step | About |
|---|---|
| mac.sh | 15 to 20 min (Basemark is most of it) |
| vm.sh, first time in a VM | + 3 min (pacman, vkpeak build) |
| vm.sh | 20 to 25 min (+ glmark2) |
| idle-power.sh | 11 min (1 min settle, 10 min window) |
