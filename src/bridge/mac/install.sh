#!/bin/bash
# Install OmacVMBridge.app to ~/Applications and start it at login (LaunchAgent).
#   ./install.sh [--prebuilt APP]
# --prebuilt: that copy (OmacVM.app's, signed with OmacVM's Developer ID)
# instead of building one here.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/OmacVMBridge.app
if [[ ${1:-} == --prebuilt ]]; then APP=${2:?--prebuilt APP}; else ./build.sh; fi
LABEL=org.omacvm.bridge
PL=~/Library/LaunchAgents/$LABEL.plist
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$HOME/Applications/OmacVMBridge.app"
ditto "$APP" "$HOME/Applications/OmacVMBridge.app"
# The app it came from was already let in; launchd does not ask again.
xattr -dr com.apple.quarantine "$HOME/Applications/OmacVMBridge.app" 2>/dev/null || true
# KeepAlive only after a crash: "Quit" in the menu bar stays quit until next login.
cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/OmacVMBridge.app/Contents/MacOS/omacvm-bridge</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/omacvm-bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/omacvm-bridge.log</string>
</dict></plist>
PL
# The old one may still be exiting after bootout ("Bootstrap failed: 5"):
# wait until launchd lets it go, and try once more if it still refuses.
for _ in $(seq 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
if ! launchctl bootstrap "gui/$(id -u)" "$PL"; then
  sleep 3
  launchctl bootstrap "gui/$(id -u)" "$PL" || { echo "the Bridge did not start (launchctl bootstrap failed twice)" >&2; exit 1; }
fi
echo "installed; log: ~/Library/Logs/omacvm-bridge.log"
echo "token: ~/Library/Application Support/omacvm-bridge/token (omacvm apply copies it into the VM)"
