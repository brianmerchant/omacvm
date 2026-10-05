# 0018: A hidden GPU safe mode with the old fence and frame path

Status: accepted. Built on `gpu-native` (OmacVM.app `Settings.gpuSafeMode`).

## Context

The new GPU path (fences from a sync thread, frames on each flush, shown as
IOSurfaces) is on by default. Each part has its own `OMACVM_*` switch, but
users do not set environment variables, and a bug that only one Mac shows
(another GPU, another macOS) must not leave that user with a broken VM until
the next release.

## Options

1. No switch: users downgrade the app. Loses every other fix.
2. One visible setting per part. Three settings nobody can judge.
3. One hidden switch that turns all three parts off together, so the VM's
   fences and frames take the 2.6.0 path again, and support can ask for it
   in one line.

## Decision

Option 3: `defaults write org.omacvm.app gpuSafeMode -bool true` makes the
launcher start QEMU with `OMACVM_VIRGL_POLL_FENCES=1`,
`OMACVM_GL_PRESENT_ON_TICK=1` and `OMACVM_GL_PRESENT=layer`. It is read when
a VM starts. It is not the whole 2.6.0 GPU stack: what came later and has
no switch here stays on (2.7.0's video decoding, the virglrenderer fixes).

## Consequences

- One line to send a user whose picture or fences misbehave; the next VM
  start uses the old path.
- QEMU's log says which path a VM took ("virgl fences reported by the sync
  thread" / "polled every 1 ms", "GL frames shown as IOSurfaces" / "with a
  CAOpenGLLayer"), so a report shows whether safe mode was on.
- The old path stays in the code as long as the switch exists. Remove both
  once a release has run without anyone needing it.
