#!/bin/bash
# OmacVM.app's run marker: the file `running` in a VM's folder names the Mac
# and the QEMU that run the VM; a clean stop removes it. A start that finds
# it warns first: the VM was not shut down cleanly, or was copied while it
# ran (2026-10-09: a VM copied from a MacBook Pro while it ran had a damaged
# btrfs on a MacBook Air). app/app/Sources/OmacVM/RunMarker.swift, compiled
# on its own; fixture folders only.
#   src/tests/app-run-marker.sh
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
case "write":   // write FOLDER MAC NAME PID
    let m = RunMarker.Mark(mac: a[2], name: a[3], pid: Int32(a[4])!)
    try! RunMarker.text(m).write(toFile: a[1] + "/" + RunMarker.fileName, atomically: true, encoding: .utf8)
    print(RunMarker.read(URL(fileURLWithPath: a[1])) == m ? "same" : "differs")
case "warn":    // warn FOLDER THISMAC
    print(RunMarker.warning(folder: URL(fileURLWithPath: a[1]), thisMac: a[2]) ?? "none")
default: exit(2)
}
SWIFT
swiftc -module-cache-path "$T/mc" -o "$T/mark" "$R/app/app/Sources/OmacVM/RunMarker.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL RunMarker.swift does not compile on its own"; exit 1; }
V=$T/VM; mkdir -p "$V"
plain="This VM was not shut down cleanly or was copied while running; its disk may be damaged."
expect "no marker: no warning" "none" "$("$T/mark" warn "$V" MBP-UUID)"
expect "the marker reads back as written" "same" "$("$T/mark" write "$V" MBP-UUID "Gilles's MacBook Pro" 4242)"
expect "copied while it ran on another Mac: warns and names that Mac" \
  "$plain It last ran on Gilles's MacBook Pro." "$("$T/mark" warn "$V" AIR-UUID)"
expect "left by this Mac (QEMU or the app ended without a clean stop): warns" "$plain" "$("$T/mark" warn "$V" MBP-UUID)"
printf 'garbage\n' > "$V/running"
expect "a marker the app cannot read: warns" "$plain" "$("$T/mark" warn "$V" AIR-UUID)"
exit $fail
