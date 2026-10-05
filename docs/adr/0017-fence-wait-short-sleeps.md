# 0017: Wait for GPU fences in short sleeps, not a spin

Status: accepted. Built on `gpu-native` (`virgl-darwin-fence-wait.patch`),
not merged. Builds on [0011](0011-async-fences.md). Corrected 2026-10-04
after review: the first version gave the thread a 50 us budget while it
spun for 100 us, and never looked at a long GPU job. Corrected again the
same evening: the 100 us were counted per fence, so fences finishing back
to back could chain spins without a sleep; they now count from the
thread's last sleep.

## Context

With fences reported by `vrend-sync` ([0011](0011-async-fences.md)) the
thread calls `glClientWaitSync`. Apple's version spins on the CPU
(`gleTestSync` in a loop) until the GPU is done, so the thread kept a core
busy whenever the guest rendered: QEMU at 195% during glmark2 and 194%
during WebGL Aquarium (bench lock held), against about 160% with the 1 ms
poll. On a laptop that is battery and heat for nothing.

## Options

1. Keep the spin. Lowest latency, one core gone while anything renders.
2. Test the fence, then `nanosleep` between tests. macOS stretches short
   sleeps (timer coalescing): Aquarium fell to 7-15 fps. Rejected.
3. Test the fence, spin only for the first 100 us (most fences are done by
   then), then wait between tests with `mach_wait_until` on a thread with
   `THREAD_TIME_CONSTRAINT_POLICY`, so the scheduler wakes it when asked.
4. Signal from Metal (`MTLSharedEvent`): not reachable while vrend runs on
   Apple's OpenGL.

## Decision

Option 3, only on macOS:

- spin at most 100 us since the thread last slept (not per fence: fences
  that finish back to back cannot chain spins), then 50 us naps; once a
  fence has taken 1 ms, each nap doubles up to 1 ms. Short fences still
  report within about 50 us; a long or stuck GPU job wakes the thread about
  1000 times a second, not 20,000.
- the time-constraint policy asks for 200 us of computation per wake
  (constraint 1 ms, preemptible). That covers the 100 us spin, so the
  thread never runs longer than it said it would; macOS may demote a
  real-time thread that overruns, and its sleeps would then be stretched
  again (the 7-15 fps of option 2). If the policy cannot be set, the thread
  logs it and keeps working as a normal thread.

Nothing changes when the GPU is idle: the thread then blocks on its fence
list as before.

## Consequences

- QEMU's CPU, bench lock held: glmark2 195% -> 165%, Aquarium 194% -> 176%.
- Frame rates the same within noise: glmark2 short set 3351/3417 (spin) vs
  3361/3310; Aquarium 19.2-20.1 vs 19.6-20.4 fps. The longer naps after 1 ms
  change neither (glmark2 3746/3663 vs 3748/3696, Aquarium 22.6/23.6/22.2 vs
  22.9/22.6/22.8 fps).
- A guest job of 65-100 ms GPU draws, bench lock, one run each: QEMU woke
  19,900 times a second with 50 us naps throughout and 2,100 with the longer
  naps (idle: 240), counting all of QEMU's threads. QEMU's CPU energy in
  20 s: 2.8 J -> 1.5 J. The GPU work per draw was the same.
- A fence that ends during a long nap is reported up to 1 ms late: about 1%
  on a 100 ms GPU job, nothing on short frames.
- One time-constraint thread in QEMU. Between two sleeps it spins at most
  100 us in all, however many fences finish meanwhile, so the spin fits its
  200 us budget. Reporting fences that are already done is not limited: a
  long burst of them can run past the budget, and macOS then demotes the
  thread for a while (nothing breaks). Between wakes it sleeps.
- Going back is a rebuild without the patch; the app's `gpuSafeMode`
  ([0018](0018-gpu-safe-mode.md)) does not use the sync thread at all.
