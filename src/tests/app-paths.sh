#!/bin/bash
# Where OmacVM.app's VMs and the app itself are found: the omacvm command
# (src/lib/app.sh) and the app (VMsFolder.swift) must agree. Runs in a
# throwaway HOME with a throwaway settings domain; touches no real VM or app.
#   src/tests/app-paths.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
export OMACVM_APP_ID=org.omacvm.test.app-paths.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$OMACVM_APP_ID.plist"' EXIT
source "$R/src/lib/app.sh"
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The app's rules, compiled on their own.
cat > "$T/main.swift" <<'EOF'
import Foundation
let a = CommandLine.arguments
let home = URL(fileURLWithPath: a[2])
if a[1] == "prepare" {
    try VMsFolder.prepare(URL(fileURLWithPath: a[3]), home: home)
} else {
    print(VMsFolder.resolve(custom: a[1].isEmpty ? nil : a[1], home: home).path)
}
EOF
swiftc -module-cache-path "$T/mc" -o "$T/vmsf" "$R/app/app/Sources/OmacVM/VMsFolder.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL VMsFolder.swift does not compile on its own"; exit 1; }

case_n=0
check() {   # WHAT WANT [SETTING]: the command and the app both give WANT
  local cli app
  if [[ -n ${3:-} ]]; then defaults write "$OMACVM_APP_ID" vmsRoot "$3"; else defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; fi
  cli=$(HOME=$H app_vms_root)
  app=$("$T/vmsf" "${3:-}" "$H")
  expect "$1 (omacvm)" "$2" "$cli"
  expect "$1 (app)" "$2" "$app"
}
fresh() { case_n=$((case_n + 1)); H=$T/home$case_n; mkdir -p "$H"; OLD=$H/$APP_VMS_OLD; }
vm() { mkdir -p "$1"; echo "NAME='$(basename "$1")'" > "$1/vm.env"; : > "$1/disk.img"; }

fresh; check "nothing yet: ~/OmacVM" "$H/OmacVM"
fresh; vm "$OLD/Omarchy"; check "VMs in the old place only: the old place" "$OLD"
fresh; vm "$OLD/Omarchy"; mkdir "$H/OmacVM"; check "~/OmacVM there: ~/OmacVM, old VMs or not" "$H/OmacVM"
fresh; mkdir -p "$OLD/leftover"; check "old place without a VM: ~/OmacVM" "$H/OmacVM"
fresh; vm "$OLD/Omarchy"; mkdir "$H/OmacVM"; check "the setting wins" "/Volumes/Some Drive/VMs" "/Volumes/Some Drive/VMs"
fresh; mkdir -p "$H/OmacVM/.git"; check "~/OmacVM is a git clone: the old place" "$OLD"
fresh; : > "$H/OmacVM"; check "~/OmacVM is a file: the old place" "$OLD"
fresh; mkdir "$H/omacvm"
if [[ -d $H/OmacVM ]]; then check "~/omacvm on a case-insensitive drive: the old place" "$OLD"
else check "~/omacvm on a case-sensitive drive: ~/OmacVM" "$H/OmacVM"; fi

# First use: ~/OmacVM with .metadata_never_index; another folder is left alone.
fresh; "$T/vmsf" prepare "$H" "$H/OmacVM"
expect "first use makes ~/OmacVM, Spotlight off" yes "$([[ -d $H/OmacVM && -f $H/OmacVM/.metadata_never_index ]] && echo yes || echo no)"
"$T/vmsf" prepare "$H" "$H/Elsewhere"
expect "a picked folder is not made or marked" no "$([[ -e $H/Elsewhere ]] && echo yes || echo no)"

# The command finds VMs there.
fresh; vm "$H/OmacVM/Omarchy"; defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
expect "omacvm lists a VM in ~/OmacVM" "Omarchy	app	stopped" "$(HOME=$H app_list)"
expect "omacvm finds its folder" "$H/OmacVM/Omarchy" "$(HOME=$H app_dir Omarchy)"
fresh; vm "$OLD/Omarchy"
expect "omacvm still finds a VM in the old place" "$OLD/Omarchy" "$(HOME=$H app_dir Omarchy)"

# The app: ~/Applications first, then /Applications; new installs in ~/Applications.
fakeapp() {   # DIR/NAME.app with the app's bundle id
  mkdir -p "$1/Contents/Resources/scripts"; : > "$1/Contents/Resources/scripts/create-vm.sh"
  defaults write "$1/Contents/Info" CFBundleIdentifier org.omacvm.app
}
fresh
sys=""
for a in /Applications/*.app; do
  [[ -f $a/Contents/Resources/scripts/create-vm.sh && $(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null) == org.omacvm.app ]] && { sys=$a; break; }
done
if [[ -n $sys ]]; then expect "only /Applications has the app: found there" "$sys" "$(HOME=$H app_bundle)"
else expect "no app anywhere: none found" "" "$(HOME=$H app_bundle)"; fi
fakeapp "$H/Applications/My OmacVM.app"
expect "~/Applications has it: found there first" "$H/Applications/My OmacVM.app" "$(HOME=$H app_bundle)"
expect "new installs go to ~/Applications" "$H/Applications" "$(HOME=$H app_install_dir)"

exit $fail
