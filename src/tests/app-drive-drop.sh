#!/bin/bash
# OmacVM.app when the drive with a VM's folder drops off: DriveWatch
# (app/app/Sources/OmacVM/DriveWatch.swift) on a small disk image that is
# detached by force under it, a file on it held open as QEMU holds the VM's
# disk; on APFS and on exFAT (SD cards; newer macOS mounts it in user space, FSKit).
# A drive renamed under a running VM is no drop. No VM, no app.
#   src/tests/app-drive-drop.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
MNT=$T/mnt
REN=
cleanup() {
  hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1 || true
  if [[ -n $REN ]]; then
    hdiutil detach -quiet -force "$REN" >/dev/null 2>&1 || true
    hdiutil detach -quiet -force "${REN}R" >/dev/null 2>&1 || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/work" "$MNT"
swiftc -O -o "$T/drive-drop-test" "$R/app/app/Sources/OmacVM/Storage.swift" \
  "$R/app/app/Sources/OmacVM/DriveWatch.swift" "$R/src/tests/app-drive-drop/main.swift"

# exFAT first, without the rename check; then APFS with it.
hdiutil create -quiet -size 64m -fs ExFAT -volname OMACVMDROP "$T/exfat.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$T/exfat.dmg"
echo "== exFAT"
"$T/drive-drop-test" "$T/work/exfat" "$MNT" "$T/exfat.dmg" OMACVMDROP
hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1 || true

hdiutil create -quiet -size 64m -fs APFS -volname OmacVMDrop "$T/drive.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$T/drive.dmg"
# The rename needs a mount point under /Volumes (its last tab field).
hdiutil create -quiet -size 64m -fs APFS -volname "OmacVMRen$$" "$T/ren.dmg"
REN=$(hdiutil attach -nobrowse "$T/ren.dmg" | awk -F'\t' 'END { print $NF }')
[[ $REN == /Volumes/* ]] || { echo "FAIL rename image not under /Volumes: '$REN'"; exit 1; }
echo "== APFS"
"$T/drive-drop-test" "$T/work/apfs" "$MNT" "$T/drive.dmg" OmacVMDrop "$REN"
