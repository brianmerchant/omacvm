#!/bin/bash
# OmacVM.app when the drive with a VM's folder drops off: DriveWatch
# (app/app/Sources/OmacVM/DriveWatch.swift) on a small disk image that is
# detached by force under it, a file on it held open as QEMU holds the VM's
# disk. No VM, no app.
#   src/tests/app-drive-drop.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
MNT=$T/mnt
cleanup() {
  hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/work" "$MNT"
swiftc -O -o "$T/drive-drop-test" "$R/app/app/Sources/OmacVM/Storage.swift" \
  "$R/app/app/Sources/OmacVM/DriveWatch.swift" "$R/src/tests/app-drive-drop/main.swift"
hdiutil create -quiet -size 64m -fs APFS -volname OmacVMDrop "$T/drive.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$T/drive.dmg"
"$T/drive-drop-test" "$T/work" "$MNT" "$T/drive.dmg" OmacVMDrop
