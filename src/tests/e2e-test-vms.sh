#!/bin/bash
# The e2e harnesses' guards (src/tests/e2e/test-vms.sh): the test app's
# settings saved and put back from a folder with a space in its path, a missing
# save never deletes a setting, and a run starts only a test VM in the test
# app's own VMs folder. 2026-10-07 a harness's clean step deleted the test
# app's VMs folder setting that way (its save went nowhere: a path with a
# space, no quotes); the next run reached the person's VM.
# Throwaway HOME and settings domains; no VM, no app.
#   src/tests/e2e-test-vms.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
DOM=org.omacvm.test.e2e-vms.$$
export OMACVM_PROD_APP_ID=org.omacvm.test.e2e-vms-prod.$$
trap 'defaults delete "$DOM" >/dev/null 2>&1; defaults delete "$OMACVM_PROD_APP_ID" >/dev/null 2>&1
  rm -rf "$T" "$HOME/Library/Preferences/$DOM.plist" "$HOME/Library/Preferences/$OMACVM_PROD_APP_ID.plist"' EXIT
source "$R/src/tests/e2e/test-vms.sh"
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
get() { defaults read "$DOM" "$1" 2>/dev/null || echo "<unset>"; }
D="$T/Macintosh SSD/home/work dir"   # like the Mac mini's home

# A value (with a space) and a list, saved and put back.
defaults write "$DOM" vmsRoot "$T/bench vms"
defaults write "$DOM" skipInstallPaths -array "/a/OmacVM Test.app"
e2e_settings_save "$DOM" "$D" vmsRoot skipInstallPaths
expect "save: two files in a folder with spaces" 2 "$(ls "$D" | wc -l | tr -d ' ')"
defaults write "$DOM" vmsRoot /Volumes/OmacVM-DD/VMs
defaults write "$DOM" skipInstallPaths -array-add "/b/OmacVM Test.app"
e2e_settings_restore "$DOM" "$D" vmsRoot skipInstallPaths; rc=$?
expect "restore: exit 0" 0 "$rc"
expect "restore: vmsRoot back" "$T/bench vms" "$(get vmsRoot)"
expect "restore: list back" "/a/OmacVM Test.app" "$(defaults read "$DOM" skipInstallPaths | sed -n 's/^ *"\(.*\)",*$/\1/p' | tr '\n' '|' | sed 's/|$//')"

# A second save (a run cut short, set up again) keeps the first one.
e2e_settings_save "$DOM" "$D" vmsRoot
defaults write "$DOM" vmsRoot /Volumes/OmacVM-DD/VMs
e2e_settings_save "$DOM" "$D" vmsRoot
e2e_settings_restore "$DOM" "$D" vmsRoot
expect "a second save keeps the first" "$T/bench vms" "$(get vmsRoot)"

# Unset before: unset after.
defaults delete "$DOM" vmsRoot
e2e_settings_save "$DOM" "$D" vmsRoot
defaults write "$DOM" vmsRoot /Volumes/OmacVM-DD/VMs
e2e_settings_restore "$DOM" "$D" vmsRoot
expect "unset before: unset again" "<unset>" "$(get vmsRoot)"

# Nothing saved (the incident): the setting stays, exit 1.
defaults write "$DOM" vmsRoot "$T/bench vms"
e2e_settings_restore "$DOM" "$T/never saved" vmsRoot 2>/dev/null; rc=$?
expect "nothing saved: exit 1" 1 "$rc"
expect "nothing saved: the setting is not deleted" "$T/bench vms" "$(get vmsRoot)"

# The VMs folder a run may use: the test app's own, never the installed app's.
H=$T/home; mkdir -p "$H/OmacVM/Omarchy" "$T/bench vms/M-disk"
echo "NAME='Omarchy'" > "$H/OmacVM/Omarchy/vm.env"
echo "NAME='M-disk'" > "$T/bench vms/M-disk/vm.env"
root() { HOME=$H e2e_vms_root "$DOM" 2>/dev/null || echo refused; }
guard() { HOME=$H e2e_vm_guard "$DOM" "$1" 2>/dev/null || echo refused; }
defaults delete "$DOM" vmsRoot
expect "no setting: refused (never ~/OmacVM)" refused "$(root)"
defaults write "$DOM" vmsRoot "$H/OmacVM"
expect "setting = ~/OmacVM: refused" refused "$(root)"
defaults write "$DOM" vmsRoot "$H/omacvm/"
expect "setting = ~/omacvm/: refused" refused "$(root)"
defaults write "$OMACVM_PROD_APP_ID" vmsRoot "$T/Ext/VMs"
defaults write "$DOM" vmsRoot "$T/Ext/VMs"
expect "setting = the installed app's folder: refused" refused "$(root)"
defaults write "$DOM" vmsRoot "$T/bench vms"
expect "the test folder: used" "$T/bench vms" "$(root)"
expect "guard: the test VM" "$T/bench vms/M-disk" "$(guard M-disk)"
expect "guard: a name not there (the incident)" refused "$(guard "OmacVM M-disk")"
mkdir -p "$T/bench vms/Other"; echo "NAME='Someone'" > "$T/bench vms/Other/vm.env"
expect "guard: a folder whose vm.env names another VM" refused "$(guard Other)"
defaults delete "$DOM" vmsRoot
expect "guard: no setting" refused "$(guard Omarchy)"

# The harnesses use it: no unquoted save, no ROOT that falls back to ~/OmacVM.
expect "drive-drop.sh restores through e2e_settings_restore" 1 "$(grep -c 'e2e_settings_restore "$DOM" "$SAVED" vmsRoot' "$R/src/tests/e2e/drive-drop.sh")"
expect "cc-switches.sh: no ~/OmacVM fallback for the test app" 0 "$(grep -c 'read "$APPID" vmsRoot 2>/dev/null || echo' "$R/src/tests/e2e/cc-switches.sh")"
bash -n "$R/src/tests/e2e/drive-drop.sh" && bash -n "$R/src/tests/e2e/cc-switches.sh" || { echo "FAIL harness syntax"; fail=1; }

exit $fail
