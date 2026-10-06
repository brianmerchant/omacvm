#!/bin/bash
# OmacVM.app's full screen is always macOS's own, in a Space of its own, on
# every display (the notch's borderless kind shared the user's Space, and the
# escape combo then opened Mission Control). Checks, without a VM or a window:
#   - the app no longer asks QEMU for the notch's full screen (OMACVM_NOTCH)
#     nor tells the guest it covers the strip (omacvm.notch), and has no switch;
#   - the runtime build applies both patches after the boot splash and checks
#     the patched ui/cocoa.m (test-fullscreen-space.sh, its self-test here);
#   - `omacvm check` no longer reads the old switch.
#   src/tests/app-fullscreen-space.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() { grep -rqE "$1" "${@:2}" && echo yes || echo no; }

S="$R/app/app/Sources/OmacVM"
expect "the app sets no OMACVM_NOTCH" no "$(has 'OMACVM_NOTCH' "$S")"
expect "the app sends no omacvm.notch" no "$(has 'omacvm\.notch' "$S")"
expect "no notch switch in the app" no "$(has 'useNotch|Use the notch for the menu bar' "$S")"
expect "omacvm check does not read the old switch" no "$(has 'useNotch' "$R/src/cmd/check.sh")"

B="$R/app/runtime/build-qemu-gpu-runtime.sh"
line() { grep -n -m1 -F "$1" "$B" | cut -d: -f1; }
splash=$(line 'patches/omacvm-cocoa-boot-splash.patch"')
own=$(line 'patches/omacvm-cocoa-fullscreen-own-space.patch"')
key=$(line 'patches/omacvm-cocoa-head-key-same-space.patch"')
test=$(line 'Tests/display/test-fullscreen-space.sh" "$source_dir/ui/cocoa.m"')
expect "the build applies both patches after the boot splash, then tests" yes \
  "$([[ -n $splash && -n $own && -n $key && -n $test ]] && (( splash < own && own < key && key < test )) && echo yes || echo no)"
for p in omacvm-cocoa-fullscreen-own-space.patch omacvm-cocoa-head-key-same-space.patch; do
  expect "$p pinned" yes \
    "$(cd "$R/app/runtime/patches" && grep -q " $p\$" SHA256SUMS && shasum -a 256 -c --status <(grep " $p\$" SHA256SUMS) && echo yes || echo no)"
done

out=$("$R/app/runtime/Tests/display/test-fullscreen-space.sh" --self-test 2>&1); rc=$?
echo "$out" | sed 's/^/     /'
expect "test-fullscreen-space.sh catches the old code" 0 "$rc"
exit $fail
