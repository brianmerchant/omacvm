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
case "start":    // start HOME FOLDER TESTBUILD(0|1) PROD_CUSTOM|-
    let pc = a[4] != "-" ? a[4] : nil
    let prod = TestVMs.productionRoots(custom: pc, others: [], homes: [URL(fileURLWithPath: a[1])])
    out(TestVMs.startProblem(folder: URL(fileURLWithPath: a[2]), testBuild: a[3] == "1", production: prod) == nil
        ? "starts" : "refused")
case "handover": // handover TESTBUILD(0|1) MINE OTHER|-
    out(TestVMs.handOverProblem(testBuild: a[1] == "1", mine: URL(fileURLWithPath: a[2]),
                                other: a[3] == "-" ? nil : URL(fileURLWithPath: a[3])) == nil ? "hands over" : "refused")
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

# Any test build (the test identity, a self-update test build, a lane's copy)
# never starts, updates or resizes a VM of the installed app, however it got there.
expect "start: test build, the person's VM" refused "$("$P" start "$H" "$H/OmacVM/Omarchy" 1 -)"
expect "start: test build, a VM in the installed app's own setting" refused "$("$P" start "$H" "/Volumes/Ext/VMs/Work" 1 /Volumes/Ext/VMs)"
expect "start: test build, a VM on a gone drive of the installed app" refused "$("$P" start "$H" "/Volumes/Gone/VMs/Work" 1 /Volumes/Gone/VMs)"
expect "start: test build, a test VM" starts "$("$P" start "$H" "$H/omacvm-bench-vms/M-disk" 1 -)"
expect "start: the installed app, its own VM" starts "$("$P" start "$H" "$H/OmacVM/Omarchy" 0 -)"
# Two copies open: a test build hands a start only to its own copy (an older one may fall back).
expect "hand over: test build, same copy" "hands over" "$("$P" handover 1 "$T/a/OmacVM Test.app" "$T/a/OmacVM Test.app/")"
expect "hand over: test build, another copy" refused "$("$P" handover 1 "$T/a/OmacVM Test.app" "$T/b/OmacVM Test.app")"
expect "hand over: test build, copy unknown" refused "$("$P" handover 1 "$T/a/OmacVM Test.app" -)"
expect "hand over: the installed app, another copy" "hands over" "$("$P" handover 0 "$T/a/OmacVM.app" "$T/b/OmacVM.app")"

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
# omacvm start, test identity: only a test app that knows its own VMs folder
# (OmacVMTestVMs), never by bundle id (that may be the installed OmacVM).
mkdir -p "$T/bin"; printf '#!/bin/bash\necho "open $*" >> "%s/opened"\n' "$T" > "$T/bin/open"; chmod +x "$T/bin/open"
# The apps open on this Mac (ps -axo comm=): only the ones a case lists in $T/ps, never this Mac's
# own (a test app another test runs here would make app_boot_app refuse).
printf '#!/bin/bash\ncat "%s/ps" 2>/dev/null\n' "$T" > "$T/bin/ps"; chmod +x "$T/bin/ps"
fake_app() {   # DIR MARKER(0|1)
  mkdir -p "$1/Contents/Resources/scripts" "$1/Contents/Resources/runtime"; : > "$1/Contents/Resources/scripts/create-vm.sh"
  defaults write "$1/Contents/Info" CFBundleIdentifier org.omacvm.app.test
  [[ $2 == 1 ]] && defaults write "$1/Contents/Info" OmacVMTestVMs -bool true
  return 0
}
cli_start() {   # APP|- : status and what was opened
  rm -f "$T/opened"
  local rt=; [[ $1 != - ]] && rt=$1/Contents/Resources/runtime
  HOME=$H PATH="$T/bin:$PATH" OMACVM_TEST_IDENTITY=1 OMACVM_APP_RUNTIME=$rt bash -c \
    'source "$1/src/lib/app.sh"; app_ip() { echo 127.0.0.1:1; }; app_start T-vm >/dev/null 2>&1; echo "rc $?"' _ "$R"
  cat "$T/opened" 2>/dev/null || echo "nothing opened"
}
fake_app "$T/old/OmacVM Test.app" 0; fake_app "$T/new/OmacVM Test.app" 1
expect "omacvm start, test identity, a test app from before 3.0.6: refused" "rc 1|nothing opened|" "$(cli_start "$T/old/OmacVM Test.app" | tr '\n' '|')"
expect "omacvm start, test identity, a test app with OmacVMTestVMs: opened" "rc 0|open -n $T/new/OmacVM Test.app --args --start --vm T-vm|" \
  "$(cli_start "$T/new/OmacVM Test.app" | tr '\n' '|')"
fake_app "$T/other/OmacVM Test.app" 1
echo "$T/other/OmacVM Test.app/Contents/MacOS/OmacVM" > "$T/ps"
expect "omacvm start, test identity, another copy of the test app open: refused" "rc 1|nothing opened|" \
  "$(cli_start "$T/new/OmacVM Test.app" | tr '\n' '|')"
rm -f "$T/ps"
others=0
for a in /Applications/*.app; do [[ $(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null) == org.omacvm.app.test ]] && others=1; done
if (( others )); then echo "skip omacvm start, no test app: /Applications has one on this Mac"
else expect "omacvm start, test identity, no test app: never open -b (the installed OmacVM)" "rc 1|nothing opened|" "$(cli_start - | tr '\n' '|')"; fi

# The installed app's own rules are unchanged.
defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
expect "omacvm, installed app, no setting: ~/OmacVM" "$H/OmacVM" "$(HOME=$H bash -c 'source "$1/src/lib/app.sh"; app_vms_root' _ "$R")"

exit $fail
