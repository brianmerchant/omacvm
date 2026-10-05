# 0034: Sound on a busy Mac: QEMU's main loop at user-interactive QoS, no HDA catch-up

Status: accepted, built (`audio-crackle`). Hidden fallback `audioClassic`.

## Context

A user on a Mac mini (10 cores, VM with 8 vCPUs, Scarlett 2i2) heard the
sound crackle while listening to Spotify in the VM and moving around in it.
OmacVM.app's sound goes Intel HDA → QEMU's mixer → SDL → CoreAudio. Both
timers that move the sound (the HDA's DMA timer and the 1 ms audio timer)
run in QEMU's main loop, the thread that also runs virgl. SDL's own audio
thread already runs at a fixed high priority (SCHED_RR 47); the main loop
ran at the default QoS, on equal terms with the vCPU threads.

Measured on an M4 Max with the Mac's cores oversubscribed (8 busy vCPUs,
glmark2, 8 busy Mac threads), a tone through PipeWire's PulseAudio part,
10 minutes: the main loop ran 10-49 ms late about 3,500 times and 100+ ms
late 9 times; the tone broke 337 times. Two causes:

1. The Mac's scheduler: the main loop waits behind vCPU threads.
2. virgl's own work: new shaders stop the main loop for 50-80 ms. QEMU's
   93 ms ring keeps the Mac playing through it, but afterwards the HDA
   codec took the whole missed time of guest audio at once (wall-clock
   pacing plus sync corrections of up to five times real time). The guest
   saw its DMA position jump and PipeWire under-ran. Every stall had to be
   buffered twice: in QEMU and in the guest.

## Options

1. The main loop at user-interactive QoS (as AppKit's main thread).
2. Move the HDA and audio timers to their own thread: upstream's HDA code
   expects the BQL; a big change for one device.
3. Another backend (QEMU's CoreAudio driver): the same main loop feeds it,
   and it would drop the SDL patches (device follows the Mac, recording off
   the BQL).
4. More buffering in the guest (ALSA headroom 8192): rides out the stalls
   (337 → 15 breaks) but adds 128 ms to a round trip that is already about
   280 ms.
5. Fewer vCPUs than cores ("Best" = all cores): helps only when the Mac
   itself is busy and costs everyone CPU; the user's VM had 8 of 10.
6. The HDA codec stops catching up after a stall: the guest's audio is
   taken at most 1/32 faster than real time, the rest forgiven; QEMU's ring
   alone covers the stall.

## Decision

Options 1 and 6: `qemu-darwin-main-loop-qos.patch` and
`qemu-hda-no-catch-up.patch` (codec property `pace`, on).
`defaults write org.omacvm.app audioClassic -bool true` starts QEMU with
`OMACVM_MAIN_LOOP_QOS=default` and `pace=off`, as 2.9.0. QEMU logs both;
`omacvm check` shows them ("sound timing"). Option 4 stays a documented
fix for 2.9.0 (troubleshooting finding 24).

## Consequences

- Same load, 10 minutes: tone breaks 337 (2.9.0) → 120 and 216 (QoS) → 19
  and 37 (QoS and pacing); the guest's sink no longer under-runs. Round trip
  unchanged (about 282 ms).
- After a stall QEMU's ring refills at 1/32 over real time (a 60 ms stall
  takes about 2 s); a second long stall inside that window can still empty
  it, which the Mac hears as a short gap.
- The main loop may take a P-core from a vCPU while it renders; it is one
  thread, and the guest's GPU work waits for it anyway.
- Remove the switch once a release has run without anyone needing it.
