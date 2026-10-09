# FullPanel port to OmacVM 3.0.12

Status: **SOURCE-INTEGRATED**, not hardware-verified on this base.

- Target base: `83157df21a041043114a39ad63a12a3faf3c055a` (3.0.12).
- Verified source: `2e7b47c46f247e507c16d2cbe3b288291f6b4517`.
- Source tag: `fullpanel-2328-hardware-verified-2026-10-08`.

The runtime transformer and its two regression tests are copied byte-for-byte
from the verified source. The transformer credits UTM's camera-housing
fullscreen work by Turing Software, LLC as its architectural prior art.
The source's known brief flash on Mission Control return remains. Its
restoration logic, window levels, Space management and diagnostic policies
are unchanged; the app enables none of the experimental policy flags.

## Compatibility audit

The target was clean at the requested base before editing. Both worktrees
were at their specified revisions, and the annotated source tag peeled to
the verified source commit. The source worktree was read only throughout.

The current `Model.swift`, `Runner.swift` and `Views.swift` accept the
existing setting, start hook and picker as additions. Native remains the
default, including for an unknown saved mode. Runner snapshots the mode
once per start, sets `OMACVM_CAMERA_HOUSING=1` only for FullPanel and removes
an inherited camera-housing flag for Native. The Omanotch override changes
only the start's in-memory `MacLinks`, leaving the saved feature record and
the other links, including Mac input methods and Touch ID, intact.

The pinned QEMU revision is unchanged. New Cocoa patches since the verified
source are notch-park logic and hooks, IME logic and hooks, and no App Nap;
the boot-splash patch also has newer timing and display-link ownership fixes.
None changes FullPanel's required anchors. FullPanel runs after all these
patches, preserving the entire upstream patch sequence and its checks.
The newer virgl runtime patches are retained too.

Both clean-size patches and the guest display code are unchanged. FullPanel
continues to use clean-size: a 3600×2338 backing area produces the verified
3600×2328 guest mode with scale presets 1, 1.33333, 1.6, 2, 3 and 4.
No height-trim bypass is added.
`build-app.sh` already hashes `patches/*` and `Tests/display/*`, covering the
transformer and both regression tests without changing the hashing code.
The older source's ad hoc test-signing exception is not ported.

## Static validation

Passed:

- Swift parsing of the three changed app files; Bash 3.2 and Python syntax.
- The verified frame-guard suite, including 24 clean-size cases, 72 mocked
  window scenarios and 23 return/compositor scenarios, without a VM or GUI.
- All seven exact transformer anchors traced to current upstream patch
  contexts; source checks and byte-for-byte idempotence on an anchor fixture;
  missing and duplicate anchors rejected without changing the input.
- Isolated checks using the actual app setting and start snippets: Native
  default/fallback, environment selection, other links retained, saved
  features unchanged. Direct 3600×2328 scale-preset check.
- Upstream clean-size, pointer guard/start, hardware cursor, notch park,
  fullscreen-space/start/shutdown/quit/rim, tap-permission, IME, IME-start
  and App Nap regressions. Keyboard shortcut rules: 1,654 checks.
- Hash sensitivity to the transformer and each FullPanel regression test,
  using temporary copies and `build-app.sh --runtime-inputs` only.
- Complete changed-file review and `git diff --check`.

The shortcut wrapper skipped the unavailable window-server list and hit
Bash 3.2's empty-array error; its pure rules checker was run directly and
passed. The IME-start check initially could not write Swift's compiler cache
inside the sandbox; it passed when rerun with that access allowed.

Neither worktree retains the complete patched `ui/cocoa.m`. Anchor and
idempotence checks therefore used upstream patch contexts and a fixture,
not the full final Cocoa translation unit. A complete patch replay and
QEMU compilation remain unverified. No full Swift app build, QEMU build,
full CI, VM check or hardware/UI test was run, and no application was launched.
ShellCheck was not run because it is not installed.

## Manual build

A full QEMU runtime rebuild is necessary. The new inputs invalidate the
existing runtime hash. With the output bundle stopped, run:

```sh
cd ~/Projects/OmacVM-Worktrees/fullpanel-latest-integration
app/scripts/build-app.sh --name "OmacVM FullPanel 3.0.12"
```

This builds `app/dist/OmacVM FullPanel 3.0.12.app` locally, without installing
or launching it. Hardware verification on a separate test VM is still required.
