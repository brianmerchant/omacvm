#!/bin/bash
# A published OmacVM-X.Y.Z.zip as the test identity, for the update path of
# cc-switches.sh: "OmacVM Test.app" (org.omacvm.app.test, helpers
# org.omacvm.test.bridge and org.omacvm.test.gestures), signed again with the
# Developer ID in OMACVM_SIGN_ID. Only the bundle ids and the signatures
# change; QEMU's runtime and everything else stay as released.
#   src/tests/e2e/relabel.sh ZIP OUT_DIR      -> OUT_DIR/OmacVM Test.app
set -euo pipefail
ZIP=${1:?usage: relabel.sh ZIP OUT_DIR}; O=${2:?usage: relabel.sh ZIP OUT_DIR}
SIGN=${OMACVM_SIGN_ID:?OMACVM_SIGN_ID: a Developer ID Application identity}
PB=/usr/libexec/PlistBuddy
rm -rf "$O"; mkdir -p "$O/x"
ditto -x -k "$ZIP" "$O/x"
src=$(ls -d "$O"/x/*.app | head -1)
[[ $($PB -c "Print :CFBundleIdentifier" "$src/Contents/Info.plist") == org.omacvm.app ]] || { echo "relabel.sh: $ZIP has no org.omacvm.app" >&2; exit 1; }
A="$O/OmacVM Test.app"
mv "$src" "$A"; rm -rf "$O/x"
for h in "$A"/Contents/Helpers/*.app; do
  [[ -d $h ]] || continue
  case $($PB -c "Print :CFBundleIdentifier" "$h/Contents/Info.plist") in
    org.omacvm.bridge) new=org.omacvm.test.bridge; name="OmacVM Test Bridge" ;;
    org.omacvm.gestures) new=org.omacvm.test.gestures; name="OmacVM Test Gestures" ;;
    # Omanotch (3.0.5 on) keeps its id and signature in test builds too (build-app.sh).
    ch.gillesgoetsch.omanotch) continue ;;
    *) echo "relabel.sh: unknown helper $h" >&2; exit 1 ;;
  esac
  $PB -c "Set :CFBundleIdentifier $new" "$h/Contents/Info.plist"
  codesign --force --options runtime --timestamp=none --preserve-metadata=entitlements -s "$SIGN" -i "$new" "$h"
  # The test identity's helpers carry their own names (src/mac/install.sh starts them by these paths).
  [[ $(basename "$h" .app) == "$name" ]] || mv "$h" "$(dirname "$h")/$name.app"
done
$PB -c "Set :CFBundleIdentifier org.omacvm.app.test" "$A/Contents/Info.plist"
$PB -c "Set :CFBundleName OmacVM Test" "$A/Contents/Info.plist" 2>/dev/null || true
codesign --force --options runtime --timestamp=none --preserve-metadata=entitlements -s "$SIGN" -i org.omacvm.app.test "$A"
codesign --verify --deep --strict "$A"
echo "$($PB -c 'Print :CFBundleShortVersionString' "$A/Contents/Info.plist") $(codesign -dv "$A" 2>&1 | grep -E '^Identifier|^TeamIdentifier' | tr '\n' ' ')"
