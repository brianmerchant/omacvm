# Third-party notices

Original OmacVM: [Gilles Goetsch's project](https://github.com/gillesgoetsch/OmacVM).
Experimental FullPanel integration: Brian Merchant's contributions in the
[FullPanel fork](https://github.com/brianmerchant/omacvm/tree/fullpanel).
The existing MIT licence and Gilles Goetsch's copyright are preserved;
this attribution does not replace the notices of reused components.

OmacVM.app's own code is MIT (`LICENSE`). It ships or uses:

- **QEMU** 11.1.1 (commit c3d48b7d), GPL-2.0 and other licences per file.
  Built from source by `runtime/build-qemu-gpu-runtime.sh` with the patches in
  `runtime/patches/`. The exact pin in that script is
  [`c3d48b7d1e89604920e5b81b91140c2ad39a1943`](https://gitlab.com/qemu-project/qemu/-/tree/c3d48b7d1e89604920e5b81b91140c2ad39a1943)
  in [upstream QEMU](https://gitlab.com/qemu-project/qemu).
  Original OmacVM build scripts and patches are in
  [Gilles Goetsch's repository](https://github.com/gillesgoetsch/OmacVM), at
  the source revision for its binary. FullPanel's additional modifications
  are in this fork's [app/runtime](https://github.com/brianmerchant/omacvm/tree/fullpanel/app/runtime),
  especially `patches/apply-camera-housing-fullscreen.py`, which transforms
  QEMU's `ui/cocoa.m`. An upstream OmacVM release tag does not include these
  fork modifications. The Cocoa driver's
  [MIT notice, copyright (c) 2008 Mike Kronenberg](https://gitlab.com/qemu-project/qemu/-/blob/c3d48b7d1e89604920e5b81b91140c2ad39a1943/ui/cocoa.m)
  remains applicable to that file; the modified driver is part of the wider
  QEMU executable, whose [GPL-2.0 and per-file licensing](https://www.qemu.org/docs/master/about/license.html)
  remain applicable.
- **UTM** (Turing Software, LLC), Apache-2.0: camera-housing fullscreen
  [PR #7885](https://github.com/utmapp/UTM/pull/7885) and
  [PR #7910](https://github.com/utmapp/UTM/pull/7910) are architectural prior
  art. The FullPanel transformer documents an independent Objective-C
  implementation; UTM's Swift implementation was not copied. This credit
  does not assert that UTM's code is bundled or relicense the QEMU driver.
- **try-omarchy** (github.com/omacom/try-omarchy), MIT: the runtime build
  scripts and patches, `QMPConnection.swift`, `VMHostSleepController.swift`,
  `NativeBridgeSocket.swift`, the clipboard and battery bridges
  (`NativeClipboardBridge.swift`, `NativeBatteryBridge.swift`,
  `HostBattery.swift`), the camera (`camera.swift`, a link to
  `src/bridge/mac/camera.swift`, from `NativeCameraBridge.swift`) and the
  display sync script. `runtime/LICENSE.try-omarchy`.
  In the VM, the battery's kernel module (GPL-2.0-only, as try-omarchy's
  original file) and agent, in OmacVM's `src/battery/` (see the
  repository's `THIRD_PARTY_NOTICES.md`).
  Its release is also downloaded at build time as the temporary live system.
- **edk2** UEFI firmware (edk2-stable202408, the release QEMU 11.1.1 ships),
  built by `runtime/build-edk2.sh` with QEMU's build flags:
  BSD-2-Clause-Patent, with OpenSSL (Apache-2.0) and others, see
  `edk2-licenses.txt`. Built with LLVM (Apache-2.0 with LLVM exception) and
  acpica's iasl, which are not shipped.
- **Omarchy** (github.com/basecamp/omarchy), MIT, (c) David Heinemeier
  Hansson: the boot logo in the firmware is Omarchy's `logo.svg`
  (`runtime/patches/edk2-logo-omarchy.patch`), `LICENSE.omarchy`.
- **QEMU's libraries** in the app: GLib, libintl, libusb (LGPL-2.1+, kept as
  replaceable .dylib files); virglrenderer, libepoxy, pixman (MIT); ANGLE,
  libslirp, PCRE2 (BSD); SDL (zlib); zstd, lz4 (BSD); xz (0BSD).
  virglrenderer is built with OmacVM's VideoToolbox video backend
  (`runtime/patches/virgl-videotoolbox-decode.patch`, MIT like
  virglrenderer); it uses Apple's VideoToolbox, part of macOS.
- **Vulkan for the VM (Venus)**: MoltenVK 1.4.2 (Apache-2.0, The Brenwill
  Workshop / Khronos; with SPIRV-Cross and SPIRV-Tools, Apache-2.0, and
  cereal, BSD-3-Clause, built in) and the Khronos Vulkan loader 1.4.357
  (Apache-2.0, with cJSON, MIT), from Homebrew's arm64_sequoia bottles.
  `LICENSE.vulkan.txt` in the licences folder has the Apache-2.0 text and
  the cereal and cJSON notices. When the app carries KosmicKrisp, Mesa's
  Vulkan driver on Metal, Venus uses it on macOS 26 and newer. It is built
  from a pinned Mesa commit and is mostly MIT. Other parts: BSD-2-Clause
  (xxHash), BSD-3-Clause (Berkeley SoftFloat), BSL-1.0 (the C11 threads code),
  BLAKE3 (CC0-1.0 / Apache-2.0, used under Apache-2.0), and the Khronos
  headers under Apache-2.0 and SGI-B-2.0. `LICENSE.mesa-kosmickrisp.txt` in
  the licences folder lists the Mesa files it is built from, with their
  licence texts and the copyright lines of their headers. virglrenderer's
  macOS and Venus-on-Metal patches come from
  github.com/startergo/homebrew-virglrenderer (MIT).
- **OmacVM** ([original source](https://github.com/gillesgoetsch/OmacVM)),
  MIT: the VM side, the base and Omarchy installers, the icon. The FullPanel
  fork's app and guest changes are in
  [brianmerchant/omacvm, branch fullpanel](https://github.com/brianmerchant/omacvm/tree/fullpanel).
- **Python** 3.13.16 (CPython), PSF-2.0, in `Contents/Resources/python`: the
  interpreter for OmacVM's Mac-side scripts on Macs without Xcode's Command
  Line Tools. As built by python-build-standalone
  (github.com/astral-sh/python-build-standalone, release 20261003; its build
  scripts are BSD-3-Clause), fetched and cut by `scripts/fetch-python.sh`.
  Linked into the interpreter: OpenSSL 3.5 (Apache-2.0), libffi (MIT),
  mpdecimal (BSD-2-Clause), expat (MIT), xz (0BSD), bzip2 (bzip2-1.0.6),
  SQLite (public domain) and HACL* (MIT). `LICENSE.python.txt` in the
  licences folder is CPython's licence with the notices of the code it
  includes.
- In the VM, only the control centre's Textual is bundled (in OmacVM's
  `src/control/vendor`, Contents/Resources/omacvm: Textual, Rich, Pygments
  and their pure-Python dependencies, MIT, BSD-2-Clause and PSF-2.0, listed in
  the repository's `THIRD_PARTY_NOTICES.md`, each wheel with its licence).
  Arch Linux ARM and Omarchy (omarchy-mac) come
  from their own servers during the setup, each package under its own licence.
  On Venus VMs `src/app/guest/venus/install.sh` downloads Mesa 26.2.4 (MIT,
  archive.mesa3d.org) and builds it in the VM with OmacVM's patches (MIT, in
  `src/app/guest/venus/patches`).

- **JetBrains Mono** 2.305 (github.com/JetBrains/JetBrainsMono), SIL Open
  Font License 1.1, (c) 2020 The JetBrains Mono Project Authors: the Touch
  ID panel's font, in Contents/Resources/fonts unchanged with its licence
  (`OFL.txt`).

## Source and future binary distribution

A future modified QEMU binary needs complete corresponding source supplied
through a method allowed by [GPL version 2, section 3](https://raw.githubusercontent.com/qemu/qemu/master/COPYING).
For a downloadable binary, arrange matching source access with the binary:
the full pinned QEMU source, all applicable fork patches and source
transformers, and the scripts controlling compilation and installation.
Preserve QEMU's `COPYING`, `LICENSE` and per-file notices, including the Cocoa
driver's notice. A mutable branch link or a link to upstream source alone
does not identify the complete source for a particular modified binary.

Record the exact fork commit for each binary and retain the pinned dependency
sources, notices and build inputs for that build. The runtime scripts record
archive URLs, checksums, dependency pins and patch order. Build entry points
and prerequisites are documented in [README.md](README.md#build) and
[runtime/README.md](runtime/README.md). Reproduction requires the fork checkout
matching the binary, rather than the official upstream checkout shown in the
upstream build example.

The app build copies this notice and several licence files into
`Contents/Resources/licenses`; the runtime's libraries are staged separately.
No FullPanel binary release or binary-distribution compliance is established
by this documentation audit. Before distributing one, inspect the complete
bundle for required QEMU and library licence texts, applicable source access,
and LGPL library replacement/relinking requirements. Replaceable `.dylib`
files alone are not a completed LGPL compliance review. Release-specific
source availability, notices and reproducibility remain unverified.
