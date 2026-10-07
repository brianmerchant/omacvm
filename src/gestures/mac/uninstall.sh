#!/bin/bash
LABEL=org.omacvm.gestures
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
# Gone before anything resets its permissions (src/mac/uninstall.sh): a helper
# from before 3.0.4 that lost Accessibility while it ran held the Mac's keys
# and clicks (#192). bootout may return while it still exits.
EXE="$HOME/Applications/OmacVMGestures.app/Contents/MacOS/omacvm-gestures"
for _ in $(seq 50); do pgrep -f "^$EXE" >/dev/null || break; sleep 0.1; done
pkill -KILL -f "^$EXE" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/OmacVMGestures.app"
echo "removed (macOS gestures are back to normal)"
