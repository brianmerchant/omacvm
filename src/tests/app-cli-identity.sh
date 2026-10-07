#!/bin/bash
# The test app's own omacvm (and its VM scripts) run by hand is the test
# identity, as when the app runs them: "OmacVM Test" (org.omacvm.app.test)
# and a lane's copy of it (org.omacvm.app.test.<lane>) get
# OMACVM_TEST_IDENTITY=1, so their Mac side starts the test helpers and never
# installs the normal ones. OmacVM itself, an explicit OMACVM_TEST_IDENTITY
# and a checkout stay as they are. Fake app bundles with the real omacvm entry
# script and src/lib/identity.sh; stand-in commands print what they got. No
# helper is installed, no VM runs.
#   src/tests/app-cli-identity.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
# fake NAME BUNDLE_ID: an app with the real omacvm entry script, the real
# src/lib/identity.sh and stand-in commands (check runs in place, apply from
# a copy, as the real app's omacvm does).
fake() {
  local c=$T/$1.app/Contents o=$T/$1.app/Contents/Resources/omacvm
  mkdir -p "$o/src/cmd" "$o/src/lib" "$c/Helpers"
  cat > "$c/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleExecutable</key><string>OmacVM</string>
</dict></plist>
EOF
  cp "$R/omacvm" "$o/omacvm"
  cp "$R/src/lib/identity.sh" "$o/src/lib/"
  echo 0000000 > "$o/COMMIT"
  for cmd in check apply; do
    printf '#!/bin/bash\necho "test=${OMACVM_TEST_IDENTITY:-} copy=${OMACVM_APP_COPY:-}"\n' > "$o/src/cmd/$cmd.sh"
    chmod 755 "$o/src/cmd/$cmd.sh"
  done
  echo "$o/omacvm"
}
run() { env -u OMACVM_TEST_IDENTITY -u OMACVM_APP_COPY "$@" 2>&1; }

T_CLI=$(fake "OmacVM Test" org.omacvm.app.test)
L_CLI=$(fake "OmacVM Test fixid" org.omacvm.app.test.fixid)
P_CLI=$(fake OmacVM org.omacvm.app)
X_CLI=$(fake Tester org.omacvm.app.tester)

expect "OmacVM Test's omacvm check: the test identity" "test=1 copy=" "$(run "$T_CLI" check)"
expect "OmacVM Test's omacvm apply (from a copy): the test identity" "test=1 copy=1" "$(run "$T_CLI" apply)"
expect "a lane's copy (org.omacvm.app.test.<lane>): the test identity" "test=1 copy=1" "$(run "$L_CLI" apply)"
expect "OmacVM's own omacvm: not the test identity" "test= copy=" "$(run "$P_CLI" check)"
expect "OmacVM's own omacvm apply: not the test identity" "test= copy=1" "$(run "$P_CLI" apply)"
expect "org.omacvm.app.tester: not the test identity (only the dot form)" "test= copy=" "$(run "$X_CLI" check)"
expect "OMACVM_TEST_IDENTITY set by the caller wins" "test=0 copy=" "$(run OMACVM_TEST_IDENTITY=0 "$T_CLI" check)"
ln -s "$T_CLI" "$T/omacvm-link"
expect "through a symlink on the PATH: still the test app's" "test=1 copy=" "$(run "$T/omacvm-link" check)"
# No Info.plist (a broken copy): nothing changes.
rm "$T/OmacVM Test.app/Contents/Info.plist"
expect "no Info.plist: not the test identity" "test= copy=" "$(run "$T_CLI" check)"

# app/scripts/vm-common.sh (apply-vm.sh run by hand from the app's
# Contents/Resources/scripts): the same rule from the same helper.
vmc() {   # BUNDLE_ID: OMACVM_TEST_IDENTITY after sourcing the helper as vm-common.sh does
  local c=$T/vmc.app/Contents
  rm -rf "$T/vmc.app"; mkdir -p "$c/Resources/scripts"
  plutil -create xml1 "$c/Info.plist" && plutil -insert CFBundleIdentifier -string "$1" "$c/Info.plist"
  env -u OMACVM_TEST_IDENTITY bash -c 'set -euo pipefail; _root=$1; source "$2/src/lib/identity.sh"
    app_test_identity "$_root/.."; echo "test=${OMACVM_TEST_IDENTITY:-}"' _ "$c/Resources" "$R"
}
expect "vm-common: OmacVM Test" "test=1" "$(vmc org.omacvm.app.test)"
expect "vm-common: a lane's copy" "test=1" "$(vmc org.omacvm.app.test.fixid)"
expect "vm-common: OmacVM" "test=" "$(vmc org.omacvm.app)"
grep -q '^app_test_identity "\$_root/\.\."$' "$R/app/scripts/vm-common.sh" &&
  echo "ok   vm-common.sh uses the helper" || { echo "FAIL vm-common.sh does not call app_test_identity"; fail=1; }
exit $fail
