# 0034: The GPU memory budget stops a runaway VM, never a desktop

Status: accepted. Built on `fractional-scale`
(`app/runtime/patches/virgl-resource-memory-budget.patch`).

## Context

A VM's textures and buffers live in the Mac's memory. 2.9.0 added a budget
for them (standards section 4: no guest-controlled allocation without a
limit) at a quarter of the Mac's memory. A resource past the budget is
refused; the guest's driver is not told, so the app that wanted it loses its
GPU context. When that app is Hyprland, the VM goes black until it restarts.

On a 16 GB Mac mini with a 5K display, picking scale 1.6 did exactly that:
4 GB was reached. Measured (QEMU's log, Omarchy with Chromium): 1.6 GB at
5K, 2.0 GB at 6K, 3.1 GB at 8K, and while a scale changes every
screen-sized buffer is made again, so the highest use is 2.6, 3.4 and 6.2 GB.
More apps, more memory. The user wants every display to work, 6K and 8K
too, "no artificial limits".

## Options

1. Keep a quarter. 5K with apps, 6K and 8K break on 16 GB Macs.
2. No budget. A VM that makes textures in a loop fills the Mac's memory.
3. A budget only a runaway VM reaches: three quarters of the Mac's memory.
4. Size it from the displays (largest display × N buffers). Needs a guess
   at N per app; a browser alone can pass any such guess.

## Decision

Option 3. The default is three quarters of the Mac's memory (12 GB on
16 GB, 6 GB on 8 GB, 48 GB on 64 GB); `OMACVM_GPU_MEMORY_MB` still sets
another, 0 turns it off. Screens and cursors keep their 256 MB reserve
past it. QEMU's log notes each new peak in 512 MB steps, and `omacvm check`
shows the peak and says when the budget was reached.

## Consequences

- A real desktop no longer reaches the budget, at 8K and any scale.
- A runaway VM can now take three quarters of the Mac's memory before it is
  stopped, on top of the VM's own memory: macOS compresses and swaps before
  that. Still bounded; the Mac does not run out.
- A refused resource still costs the app its GPU context. Telling the guest
  (reset status for a robust compositor) is separate work.
- The peaks in the log show what VMs really need; if they ever come near,
  this record is replaced.
