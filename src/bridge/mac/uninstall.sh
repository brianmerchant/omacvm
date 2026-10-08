#!/bin/bash
# Remove OmacVM Bridge from this Mac. --purge also deletes the token and config.
source "$(dirname "$0")/../../lib/labels.sh"
LABEL=$(omacvm_label bridge)
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
# Gone before its permission is reset below (#192: a Bridge from before 3.0.4
# that lost Accessibility while it ran could hold the Mac's media keys and clicks).
EXE="$HOME/Applications/OmacVMBridge.app/Contents/MacOS/omacvm-bridge"
for _ in $(seq 50); do pgrep -f "^$EXE" >/dev/null || break; sleep 0.1; done
pkill -KILL -f "^$EXE" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/OmacVMBridge.app"
tccutil reset Accessibility org.omacvm.bridge >/dev/null 2>&1 || true
[[ ${1:-} == --purge ]] && rm -rf "$HOME/Library/Application Support/omacvm-bridge" "$HOME/Library/Logs/omacvm-bridge.log"
echo "removed (media keys are back to macOS). Location Services: remove OmacVM Bridge in"
echo "System Settings > Privacy & Security > Location Services if it is still listed."
