#!/bin/bash
# Build OmacVMGestures.app (background-only, ad-hoc signed) into ./build.
# OMACVM_HELPER_TEST=1: the test identity (org.omacvm.test.gestures, port 47930,
# its own settings domain and Bridge folder; app/scripts/build-app.sh --test-identity).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/OmacVMGestures.app
ID=org.omacvm.gestures; NAME="OmacVM Gestures"; DEFS=()
if [[ ${OMACVM_HELPER_TEST:-0} == 1 ]]; then
  ID=org.omacvm.test.gestures; NAME="OmacVM Test Gestures"
  DEFS=(-DPORT=47930 "-DGESTURES_DOMAIN=CFSTR(\"$ID\")" '-DBRIDGE_DIR="omacvm-test-bridge"')
fi
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
../../icon/make-icns.sh "$APP/Contents/Resources/OmacVM.icns"
clang -O2 -Wall ${DEFS[@]+"${DEFS[@]}"} -o "$APP/Contents/MacOS/omacvm-gestures" omacvm-gestures.c scroll_ns.m \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon -framework CoreFoundation -framework AppKit -framework IOKit
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>omacvm-gestures</string>
  <key>CFBundleIconFile</key><string>OmacVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
../../lib/sign.sh "$APP" "$ID"
echo "built $APP"
