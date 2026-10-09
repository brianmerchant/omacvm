#!/bin/bash
# The Mac's input methods switched in OmacVM.app's row while the VM is stopped
# (#316): the row writes the VM's record and its mac-ime-pending file; the
# next start has the org.omacvm.ime port (or none) and runs `omacvm apply`
# for the VM's part, which switches mac-ime alone. The app's start path from
# its own sources (MacIME.swift, MacLinks.swift), the VM's part by the parts
# apply installs. No VM, no app.
#   src/tests/mac-ime-start.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
fail=0
check() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
command -v swiftc >/dev/null || { echo "skip: no swiftc"; exit 0; }
cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
let f = URL(fileURLWithPath: a[2])
func read(_ n: String) -> String? { try? String(contentsOf: f.appendingPathComponent(n), encoding: .utf8) }
switch a[1] {
case "row":   // the row's switch while the VM is stopped (MacIMERow.write)
    let r = MacIME.row(record: read("features"), pending: read(MacIME.pendingFile), running: false, busy: false, cli: true)
    guard r.enabled else { print("row disabled"); exit(1) }
    let n = MacIME.switchStopped(record: read("features"), pending: read(MacIME.pendingFile), on: a[3] == "on")
    try! n.record.write(to: f.appendingPathComponent("features"), atomically: true, encoding: .utf8)
    let p = f.appendingPathComponent(MacIME.pendingFile)
    if let t = n.pending { try! t.write(to: p, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: p) }
    print(MacIME.row(record: read("features"), pending: read(MacIME.pendingFile), running: false, busy: false, cli: true).note ?? "-")
case "start":   // Runner.start: prepareStart, then the links; MacIMEStart runs apply
    let pending = MacIME.prepareStart(folder: f)
    let port = MacLinks.load(folder: f).macIME
    print("port=\(port ? "on" : "off") apply=\(pending.map { MacIME.applyArguments(vm: "Test VM", on: $0).joined(separator: " ") } ?? "none")")
default: exit(2)
}
SWIFT
swiftc -O -o "$T/ime" "$R/app/app/Sources/OmacVM/MacLinks.swift" "$R/app/app/Sources/OmacVMFeatures/MacIME.swift" "$T/main.swift" 2>"$T/swiftc.log" ||
  { echo "FAIL the start path does not compile:"; cat "$T/swiftc.log"; exit 1; }
V=$T/vm; mkdir -p "$V"
rec() { cat "$V/features"; }

# On while stopped: record + pending; the next start has the port and sets up the VM's part.
printf 'bridge=on gestures=on mac-ime=off\n' > "$V/features"
check "stopped, switched on: the row's note" "From the next start." "$("$T/ime" row "$V" on)"
check "stopped, switched on: the record" "bridge=on gestures=on mac-ime=on" "$(rec)"
check "start: the port, and apply for mac-ime=on" \
  "port=on apply=apply --vm Test VM --vm-type app --feature mac-ime=on --yes --transaction" "$("$T/ime" start "$V")"
# An apply that failed and rolled back the record: the next start still has the port and tries again.
printf 'bridge=on gestures=on mac-ime=off\n' > "$V/features"
check "start after a failed apply: the record follows the choice" \
  "port=on apply=apply --vm Test VM --vm-type app --feature mac-ime=on --yes --transaction" "$("$T/ime" start "$V")"
check "start after a failed apply: the record says on again" "bridge=on gestures=on mac-ime=on" "$(rec)"
# Done (MacIMEStart removes the pending file): later starts just have the port.
rm "$V/mac-ime-pending"
check "start after it was set up: the port, no apply" "port=on apply=none" "$("$T/ime" start "$V")"

# Off while stopped: no port at the next start, apply takes the VM's part away.
check "stopped, switched off: the row's note" "From the next start." "$("$T/ime" row "$V" off)"
check "start: no port, apply for mac-ime=off" \
  "port=off apply=apply --vm Test VM --vm-type app --feature mac-ime=off --yes --transaction" "$("$T/ime" start "$V")"
# Off and on again before a start: the VM keeps what it had, nothing pending.
check "stopped, back on before a start: no note" "-" "$("$T/ime" row "$V" on)"
check "start: the port, nothing to set up" "port=on apply=none" "$("$T/ime" start "$V")"

# The VM's part: apply's switch of mac-ime installs only mac-ime's part
# (src/guest/install.sh runs ime/guest/install.sh on|off for it), not all of OmacVM.
source "$R/src/lib/features.sh"
features_load
d=$("$R/src/release/manifest.py" digests --src "$R/src")
check "apply's switch: only mac-ime's part" "mac-ime" "$(feature_switch_parts "$d" "$d" " mac-ime" "${FN[*]}")"
grep -q 'if want mac-ime; then' "$R/src/guest/install.sh" && grep -q '"$R/ime/guest/install.sh" "$U" on' "$R/src/guest/install.sh" &&
  echo "ok   guest/install.sh: mac-ime=on installs the VM's part" || { echo "FAIL guest/install.sh: no mac-ime part"; fail=1; }

# Runner: the record follows the choice before the links are read; the VM's part after QEMU started.
r=$R/app/app/Sources/OmacVM/Runner.swift
check "Runner: prepareStart before MacLinks.load" "ok" \
  "$(awk '/MacIME.prepareStart\(folder: c.folder\)/ { p = NR } /links = MacLinks.load\(folder: c.folder\)/ && p && NR > p { print "ok"; exit }' "$r")"
check "Runner: MacIMEStart.run after QEMU started" "ok" \
  "$(awk '/try p.run\(\)/ { p = NR } /MacIMEStart.run\(config: c, on: on/ && p && NR > p { print "ok"; exit }' "$r")"
exit $fail
