#!/bin/bash
# OmacVM.app's "Open Existing VM…": the picked folder is the VM's (vm.env in
# it) or the folder it is in; anything else opens nothing and says why. A VM
# whose disk another QEMU has (another app, another Mac) is not started:
# QEMU's lock error and a QEMU of this Mac on the same disk are found.
# app/app/Sources/OmacVM/VMOpen.swift, compiled on its own; fixture folders only.
#   src/tests/app-open-vm.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = Array(CommandLine.arguments.dropFirst())
switch a[0] {
case "pick":     // pick FOLDER
    switch VMOpen.pick(URL(fileURLWithPath: a[1])) {
    case .vm(let folder, let root): print("vm \(folder.path) root \(root.path)")
    case .none(let why): print("none \(why)")
    }
case "locked":   // locked LOGFILE
    print(VMOpen.diskLocked(log: (try? String(contentsOfFile: a[1], encoding: .utf8)) ?? "") ? "locked" : "not locked")
case "runs":     // runs FOLDER PSFILE
    let lines = ((try? String(contentsOfFile: a[2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    print(VMOpen.qemuRuns(URL(fileURLWithPath: a[1]), lines: lines) ? "runs" : "free")
default: exit(2)
}
SWIFT
swiftc -module-cache-path "$T/mc" -o "$T/open" "$R/app/app/Sources/OmacVM/VMOpen.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL VMOpen.swift does not compile on its own"; exit 1; }

D=$T   # as the app keeps paths (standardized: /var, not /private/var)
mkdir -p "$D/Drive/VMs/Omarchy" "$D/Drive/VMs/B VM" "$D/Drive/VMs/notes" "$D/Empty" "$D/Other/stuff"
echo "NAME='Omarchy'" > "$D/Drive/VMs/Omarchy/vm.env"
echo "NAME='B VM'" > "$D/Drive/VMs/B VM/vm.env"
expect "the VM's folder: that VM, its parent the VMs folder" \
  "vm $D/Drive/VMs/Omarchy root $D/Drive/VMs" "$("$T/open" pick "$D/Drive/VMs/Omarchy")"
expect "the VM's folder with a trailing slash" \
  "vm $D/Drive/VMs/Omarchy root $D/Drive/VMs" "$("$T/open" pick "$D/Drive/VMs/Omarchy/")"
expect "the folder the VMs are in: the first VM by name" \
  "vm $D/Drive/VMs/B VM root $D/Drive/VMs" "$("$T/open" pick "$D/Drive/VMs")"
out=$("$T/open" pick "$D/Empty")
expect "an empty folder: nothing, and why" "none No VM in $D/Empty." "${out%% A VM*}"
expect "the reason names vm.env" "yes" "$([[ $out == *"vm.env"* ]] && echo yes || echo no)"
out=$("$T/open" pick "$D/Other")
expect "folders without vm.env: nothing" "none" "${out%% *}"
out=$("$T/open" pick "$D/Drive")
expect "two levels up: nothing (only the VM's folder or its parent)" "none" "${out%% *}"
expect "a folder that is not there: nothing" "none" "$("$T/open" pick "$D/Gone" | cut -d' ' -f1)"

# QEMU's own words when another QEMU holds the disk (file-posix's lock).
cat > "$T/locked.log" <<'LOG'
OmacVM: network: user
qemu-system-aarch64: -device nvme,drive=disk,serial=omacvm: Failed to get "write" lock
Is another process using the image [/Volumes/SD4TB/OmacVM/Omarchy/disk.img]?
LOG
printf 'OmacVM: network: user\nqemu-system-aarch64: terminating on signal 15\n' > "$T/plain.log"
expect "QEMU's lock error is found" "locked" "$("$T/open" locked "$T/locked.log")"
expect "another exit is not a lock" "not locked" "$("$T/open" locked "$T/plain.log")"

V="$D/Drive/VMs/A,b VM"
mkdir -p "$V"
cat > "$T/ps" <<PS
/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM -name Omarchy -drive if=none,id=disk,file=$D/Drive/VMs/A,,b VM/disk.img,format=raw,cache=writeback
/usr/bin/tail -f $D/Drive/VMs/Omarchy/logs/qemu.log
PS
expect "a QEMU on this Mac runs the VM (commas doubled)" "runs" "$("$T/open" runs "$V" "$T/ps")"
expect "a log viewer is not a running VM" "free" "$("$T/open" runs "$D/Drive/VMs/Omarchy" "$T/ps")"
expect "another VM's QEMU is not this VM's" "free" "$("$T/open" runs "$D/Drive/VMs/B VM" "$T/ps")"
exit $fail
