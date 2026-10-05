# 0013: MoltenVK now, KosmicKrisp on macOS 26

Status: accepted. MoltenVK built on `gpu-venus`; KosmicKrisp planned.

## Context

Venus needs a Vulkan driver on the Mac. Two exist:

- **MoltenVK** (Khronos, Apache-2.0): Vulkan 1.4 on Metal, runs on macOS 15.
  Missing for us: `nullDescriptor` (robustness2), geometry shaders, logicOp,
  float64.
- **KosmicKrisp** (Mesa, MIT): a native Vulkan driver on Metal 4
  (`MTL4CommandQueue`), so it needs macOS 26. Closer to conformant; has what
  Zink needs.

The test Mac runs macOS 15.7; users run both. UTM 5 ships both and picks by
macOS version.

## Options

1. MoltenVK only. Works everywhere today; Zink, rusticl and ANGLE-on-Vulkan
   stay impossible.
2. KosmicKrisp only. Nothing on macOS 15.
3. Both, picked by macOS version at load time, with an override.

## Decision

Option 3. `virgl-darwin-vulkan-beside.patch` loads `libvulkan.1.dylib` from
the runtime and points the loader at `share/vulkan/icd.d`: KosmicKrisp on
macOS 26+, MoltenVK before. `VK_DRIVER_FILES`, `VK_ICD_FILENAMES` or
`OMACVM_VULKAN_DRIVER` override. Only MoltenVK is bundled today (pinned
Homebrew bottle 1.4.2, loader 1.4.357); KosmicKrisp is added once it is
built and tested on a macOS 26 Mac.

## Consequences

- Vulkan in the VM works now on macOS 15 (vkmark ~800 with polled fences;
  about 5,200 with the sync thread's fences, ADR 0011).
- Zink (GL 4.6 on Vulkan), OpenCL through rusticl, and Chrome's ANGLE on
  Vulkan wait for KosmicKrisp: with MoltenVK, Zink gives GL 2.1 and crashes,
  ANGLE cannot make an ES 3.0 context.
- Two drivers to test; results must say which ICD ran.
- KosmicKrisp needs LLVM, libclc and the SPIR-V translator to build; adds
  build time and MIT notices.
