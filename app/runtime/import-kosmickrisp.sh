#!/bin/bash
# KosmicKrisp built on another Mac, for a runtime built on a Mac that cannot
# build it (no Xcode 26 or Homebrew LLVM, e.g. a release Mac on macOS 15):
#   app/runtime/import-kosmickrisp.sh DIR           copy it into .build/kosmickrisp
#   app/runtime/import-kosmickrisp.sh DIR --stamp   print its stamp
# DIR is the other Mac's app/runtime/.build/kosmickrisp from the same commit
# (build-kosmickrisp.sh there). Taken only when its stamp names the Mesa
# commit and the build-kosmickrisp.sh of this checkout, and the dylib is an
# arm64 library that links only the system's libraries.
# build-app.sh and build-qemu-gpu-runtime.sh use it when
# OMACVM_KOSMICKRISP_FROM=DIR is set.
set -euo pipefail
die() { echo "kosmickrisp-import: $*" >&2; exit 1; }
native_dir=$(cd "$(dirname "$0")" && pwd -P)
from=${1:?usage: import-kosmickrisp.sh DIR [--stamp]}
[[ -d $from ]] || die "no folder $from"
files=(libvulkan_kosmickrisp.dylib kosmickrisp_mesa_icd.json LICENSE.mesa-kosmickrisp.txt stamp)
for f in "${files[@]}"; do [[ -s $from/$f ]] || die "$from has no $f"; done

commit=$(sed -n 's/^mesa_commit=\([0-9a-f]\{40\}\)$/\1/p' "$native_dir/build-kosmickrisp.sh")
script=$(shasum -a 256 "$native_dir/build-kosmickrisp.sh" | cut -d' ' -f1)
read -r s_commit s_script _ < "$from/stamp"
[[ $s_commit == "$commit" ]] || die "built from Mesa $s_commit, this checkout pins $commit"
[[ $s_script == "$script" ]] || die "built by another build-kosmickrisp.sh: build it again from this commit"
lib=$from/libvulkan_kosmickrisp.dylib
[[ $(file -b "$lib") == "Mach-O 64-bit dynamically linked shared library arm64" ]] || die "$lib is not an arm64 dylib"
others=$(otool -L "$lib" | tail -n +2 | awk '{ print $1 }' | grep -v -E '^(@rpath/libvulkan_kosmickrisp\.dylib|/usr/lib/|/System/Library/)' || true)
[[ -z $others ]] || die "$lib links more than the system: $others"
grep -q '"library_path": "../../../lib/libvulkan_kosmickrisp.dylib"' "$from/kosmickrisp_mesa_icd.json" || die "unexpected ICD file"

if [[ ${2:-} == --stamp ]]; then cat "$from/stamp"; exit 0; fi
out=$native_dir/.build/kosmickrisp
mkdir -p "$out"
for f in "${files[@]}"; do install -m "$([[ $f == *.dylib ]] && echo 0755 || echo 0644)" "$from/$f" "$out/$f"; done
echo "[kosmickrisp-import] from $from ($(cut -d' ' -f3- "$out/stamp"))"
