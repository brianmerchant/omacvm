#!/bin/bash
# A VM named with --vm that is not there is an error, never another VM; the
# test identity never uses the installed app's VMs folders; destructive test
# hooks act only on a VM in the test build's own VMs folder. The app's rules
# (app/app/Sources/OmacVM/VMPick.swift, compiled on their own) and the
# omacvm command's (src/lib/app.sh) for the test identity's VMs folder.
# 2026-10-07 a test app got `--vm "OmacVM M-disk"` with its VMs folder
# setting gone, fell back to ~/OmacVM/Omarchy (the person's VM), started it
# and made its disk smaller. Throwaway HOME and settings; no VM, no app.
#   src/tests/app-vm-pick.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
export OMACVM_APP_ID=org.omacvm.test.vm-pick.$$
export OMACVM_PROD_APP_ID=org.omacvm.test.vm-pick-prod.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; defaults delete "$OMACVM_PROD_APP_ID" >/dev/null 2>&1
  rm -rf "$T" "$HOME/Library/Preferences/$OMACVM_APP_ID.plist" "$HOME/Library/Preferences/$OMACVM_PROD_APP_ID.plist"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

cat > "$T/main.swift" <<'EOF'
import Foundation
let a = Array(CommandLine.arguments.dropFirst())
func out(_ s: String) { print(s) }
switch a[0] {
case "requested":
    out(VMPick.requested(Array(a.dropFirst())).map { "[\($0)]" } ?? "nil")
case "choose":   // choose REQUESTED|- NAME:FOLDER...
    let vms = a.dropFirst(2).map { s -> (name: String, folder: String) in
        let p = s.split(separator: ":", maxSplits: 1).map(String.init); return (p[0], p[1]) }
    switch VMPick.choose(requested: a[1] == "-" ? nil : a[1], vms: Array(vms)) {
    case .vm(let i): out("vm \(vms[i].name)")
    case .new: out("new")
    case .unknown(let n): out("unknown [\(n)]")
    }
case "free":     // free BASE ROOT TAKEN...
    out(VMPick.freeName(a[1], root: URL(fileURLWithPath: a[2]), taken: Array(a.dropFirst(3))))
case "root":     // root HOME CUSTOM|- PROD_CUSTOM|-
    let pc = a.count > 3 && a[3] != "-" ? a[3] : nil
    let prod = TestVMs.productionRoots(custom: pc, others: [], homes: [URL(fileURLWithPath: a[1])])
    out(TestVMs.root(custom: a[2] == "-" ? nil : a[2], home: URL(fileURLWithPath: a[1]), production: prod).path)
case "hook":     // hook HOME FOLDER|- OWNROOT|-
    let prod = TestVMs.productionRoots(custom: nil, others: [], homes: [URL(fileURLWithPath: a[1])])
    out(TestVMs.hookProblem(folder: a[2] == "-" ? nil : URL(fileURLWithPath: a[2]),
                            ownRoot: a[3] == "-" ? nil : a[3], production: prod) == nil ? "acts" : "refused")
default: exit(2)
}
EOF
swiftc -module-cache-path "$T/mc" -o "$T/pick" "$R/app/app/Sources/OmacVM/VMsFolder.swift" \
  "$R/app/app/Sources/OmacVM/VMPick.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL VMPick.swift does not compile on its own"; exit 1; }
P=$T/pick

# --vm on the command line.
expect "no --vm" nil "$("$P" requested --start)"
expect "--vm NAME" "[OmacVM M-disk]" "$("$P" requested --start --vm "OmacVM M-disk")"
expect "--vm without a name" "[]" "$("$P" requested --start --vm)"

# The incident: a name that is not there, the person's VM is.
expect "unknown name: never the person's VM" "unknown [OmacVM M-disk]" "$("$P" choose "OmacVM M-disk" Omarchy:Omarchy)"
expect "unknown name, no VMs: still unknown (no new VM started)" "unknown [Nope]" "$("$P" choose Nope)"
expect "empty name: unknown" "unknown []" "$("$P" choose "" Omarchy:Omarchy)"
expect "by name" "vm Test B" "$("$P" choose "Test B" "Test A:a" "Test B:b")"
expect "by folder name" "vm Test B" "$("$P" choose b "Test A:a" "Test B:b")"
expect "no --vm: the first VM" "vm Test A" "$("$P" choose - "Test A:a" "Test B:b")"
expect "no --vm, no VM: a new one" new "$("$P" choose -)"

# A new VM's default name never names a folder that is there.
H=$T/home; mkdir -p "$H/OmacVM"
expect "free: Omarchy" Omarchy "$("$P" free Omarchy "$H/OmacVM")"
mkdir "$H/OmacVM/Omarchy"
expect "folder Omarchy there: Omarchy 2" "Omarchy 2" "$("$P" free Omarchy "$H/OmacVM")"
mkdir "$H/OmacVM/Omarchy 2"
expect "Omarchy, Omarchy 2 there: Omarchy 3" "Omarchy 3" "$("$P" free Omarchy "$H/OmacVM")"
expect "a VM elsewhere with the name (any case): next" "Work 2" "$("$P" free Work "$H/OmacVM" work)"

# The test identity's VMs folder: never ~/OmacVM or another folder of the installed app.
TV="$H/OmacVM Test VMs"
expect "test, no setting: ~/OmacVM Test VMs, not ~/OmacVM" "$TV" "$("$P" root "$H" -)"
expect "test, setting = ~/OmacVM: refused" "$TV" "$("$P" root "$H" "$H/OmacVM")"
expect "test, setting = ~/OmacVM/ (slash): refused" "$TV" "$("$P" root "$H" "$H/OmacVM/")"
expect "test, setting = ~/omacvm (case): refused" "$TV" "$("$P" root "$H" "$H/omacvm")"
expect "test, setting inside ~/OmacVM: refused" "$TV" "$("$P" root "$H" "$H/OmacVM/Omarchy")"
ln -s "$H/OmacVM" "$T/link"
expect "test, setting = a link to ~/OmacVM: refused" "$TV" "$("$P" root "$H" "$T/link")"
expect "test, setting = the installed app's own setting: refused" "$TV" "$("$P" root "$H" "/Volumes/Ext/VMs" "/Volumes/Ext/VMs")"
expect "test, setting = the old hidden place: refused" "$TV" "$("$P" root "$H" "$H/Library/Application Support/OmacVM/VMs")"
mkdir -p "$H/omacvm-bench-vms"
expect "test, its own folder: used" "$H/omacvm-bench-vms" "$("$P" root "$H" "$H/omacvm-bench-vms")"

# Destructive hooks (disk size, forcing a VM off): only a VM in the test build's own folder.
mkdir -p "$H/omacvm-bench-vms/M-disk"; echo "NAME='M-disk'" > "$H/omacvm-bench-vms/M-disk/vm.env"
echo "NAME='Omarchy'" > "$H/OmacVM/Omarchy/vm.env"
expect "hook: the person's VM, no setting (the incident)" refused "$("$P" hook "$H" "$H/OmacVM/Omarchy" -)"
expect "hook: the person's VM, setting = ~/OmacVM" refused "$("$P" hook "$H" "$H/OmacVM/Omarchy" "$H/OmacVM")"
expect "hook: no VM (a name not found)" refused "$("$P" hook "$H" - "$H/omacvm-bench-vms")"
expect "hook: a test VM, no setting" refused "$("$P" hook "$H" "$H/omacvm-bench-vms/M-disk" -)"
expect "hook: a test VM in another folder than the setting" refused "$("$P" hook "$H" "$H/omacvm-bench-vms/M-disk" "$T/other")"
mkdir -p "$H/omacvm-bench-vms/empty"
expect "hook: a folder without vm.env" refused "$("$P" hook "$H" "$H/omacvm-bench-vms/empty" "$H/omacvm-bench-vms")"
expect "hook: a test VM in its own folder" acts "$("$P" hook "$H" "$H/omacvm-bench-vms/M-disk" "$H/omacvm-bench-vms")"
expect "hook: same, the setting with a slash" acts "$("$P" hook "$H" "$H/omacvm-bench-vms/M-disk" "$H/omacvm-bench-vms/")"

# The omacvm command agrees for the test identity (src/lib/app.sh).
cli_root() { HOME=$H OMACVM_TEST_IDENTITY=1 bash -c 'source "$1/src/lib/app.sh"; app_vms_root' _ "$R"; }
cli_roots() { HOME=$H OMACVM_TEST_IDENTITY=1 bash -c 'source "$1/src/lib/app.sh"; app_vms_roots' _ "$R" | tr '\n' '|'; }
defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
expect "omacvm, test, no setting: ~/OmacVM Test VMs" "$TV" "$(cli_root)"
for s in "$H/OmacVM" "$H/OmacVM/" "$H/omacvm" "$H/OmacVM/Omarchy" "$T/link"; do
  defaults write "$OMACVM_APP_ID" vmsRoot "$s"
  expect "omacvm, test, setting $s: refused" "$TV" "$(cli_root)"
  expect "app agrees for $s" "$TV" "$("$P" root "$H" "$s")"
done
defaults write "$OMACVM_PROD_APP_ID" vmsRoot "$T/Prod Drive/VMs"
defaults write "$OMACVM_APP_ID" vmsRoot "$T/Prod Drive/VMs/"
expect "omacvm, test, setting = the installed app's setting: refused" "$TV" "$(cli_root)"
defaults write "$OMACVM_APP_ID" vmsRoot "$H/omacvm-bench-vms"
expect "omacvm, test, its own folder: used" "$H/omacvm-bench-vms" "$(cli_root)"
defaults write "$OMACVM_APP_ID" otherVMsRoots -array "$H/OmacVM" "$T/older tests"
expect "omacvm, test: no folder of the installed app, no old place" "$H/omacvm-bench-vms|$T/older tests|" "$(cli_roots)"
# The installed app's own rules are unchanged.
defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
expect "omacvm, installed app, no setting: ~/OmacVM" "$H/OmacVM" "$(HOME=$H bash -c 'source "$1/src/lib/app.sh"; app_vms_root' _ "$R")"

exit $fail
