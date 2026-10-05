#!/bin/bash
# OmacVM.app's VMs folders without a VM: moves on one drive and to another (a
# small disk image), sparse disks, cancel, refusals (changes during a move,
# linked folders), half copies left behind, busy folders, downloads,
# Time Machine, the app into ~/Applications. Fixture folders only.
#   src/tests/app-storage.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
MNT=""
cleanup() {
  [[ -z $MNT ]] || hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1 || true
  [[ -z ${HFS:-} ]] || hdiutil detach -quiet -force "$HFS" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/work" "$T/volumes/Real" "$T/volumes/Hfs"
swiftc -O -o "$T/storage-test" "$R/app/app/Sources/OmacVM/Storage.swift" "$R/src/tests/app-storage/main.swift"
# "Another drive": 64 MB, APFS, mounted inside the fixture folder.
hdiutil create -quiet -size 64m -fs APFS -volname OmacVMTest "$T/drive.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$T/volumes/Real" "$T/drive.dmg"
MNT=$T/volumes/Real
# Mac OS Extended: no sparse files.
hdiutil create -quiet -size 64m -fs JHFS+ -volname OmacVMTestHFS "$T/hfs.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$T/volumes/Hfs" "$T/hfs.dmg"
HFS=$T/volumes/Hfs
"$T/storage-test" "$T/work" "$MNT" "$T/volumes" "$HFS"
